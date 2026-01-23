# main.py
import os
import json
from datetime import datetime
from typing import List, Optional

from fastapi import FastAPI, HTTPException, Depends, Header, BackgroundTasks, Query, APIRouter, Request
from fastapi.middleware.cors import CORSMiddleware

from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker, Session
from sqlalchemy.exc import IntegrityError
from sqlalchemy.sql import func

from urllib.parse import urlparse
from pydantic import BaseModel

from models import Base, Post, Vote, Reaction, Power  # make sure models.py defines these

# =========================
# Environment & DB
# =========================
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./posts.db")
DEBUG = os.getenv("DEBUG", "false").lower() in ("1", "true", "yes")
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-4o-mini")
POWER_THRESHOLD = int(os.getenv("POWER_THRESHOLD", "5"))

# For Postgres, add sslmode=require only for PUBLIC hosts (not *.railway.internal)
if DATABASE_URL.startswith(("postgres://", "postgresql://")):
	parsed = urlparse(DATABASE_URL)
	host = (parsed.hostname or "").lower()
	if not host.endswith(".railway.internal") and "sslmode=" not in DATABASE_URL:
		sep = "&" if "?" in DATABASE_URL else "?"
		DATABASE_URL = f"{DATABASE_URL}{sep}sslmode=require"

engine = create_engine(
	DATABASE_URL,
	pool_pre_ping=True,
	connect_args={"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {},
)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)

# Create tables (adds tables if missing; column adds handled by admin migrations below)
Base.metadata.create_all(bind=engine)

# =========================
# App + CORS + Security
# =========================
app = FastAPI(title="Content Service", version="4.0.1")

app.add_middleware(
	CORSMiddleware,
	allow_origins=["*"],
	allow_credentials=True,
	allow_methods=["GET", "POST", "OPTIONS"],
	allow_headers=["Content-Type", "X-API-Key", "X-User-Id"],
)

API_KEY = os.getenv("API_KEY")

def require_api_key(x_api_key: Optional[str] = Header(default=None)):
	if API_KEY and x_api_key != API_KEY:
		raise HTTPException(status_code=401, detail="Unauthorized")

def get_db():
	db = SessionLocal()
	try:
		yield db
	finally:
		db.close()

# =========================
# Schemas
# =========================
class PostIn(BaseModel):
	topic: str
	text: str

class PostOut(PostIn):
	id: int
	timestamp: datetime
	class Config:
		orm_mode = True

class PostDetailOut(PostOut):
	expanded_text: Optional[str] = None
	expanded_at: Optional[datetime] = None
	# voting
	score: int = 0
	upvotes: int = 0
	downvotes: int = 0
	my_vote: Optional[int] = None  # -1/0/1
	# reactions
	learned_count: int = 0
	surprised_count: int = 0
	my_learned: Optional[bool] = None
	my_surprised: Optional[bool] = None
	# power
	power_count: int = 0
	my_powered: Optional[bool] = None

class GenerateIn(BaseModel):
	topic: str
	count: int = 5

class SubjectBatchIn(BaseModel):
	count: int = 5

class MultiTopicItem(BaseModel):
	topic: str
	count: int = 5

class MultiGenerateIn(BaseModel):
	items: List[MultiTopicItem]

class ExpandIn(BaseModel):
	force: bool = False
	style: Optional[str] = None

class VoteIn(BaseModel):
	value: int  # -1, 0, or 1

class ReactIn(BaseModel):
	learned: Optional[bool] = None
	surprised: Optional[bool] = None

class PowerIn(BaseModel):
	enabled: bool  # true to give power, false to remove your power

# >>> NEW: response model for the power endpoint (extends PostDetailOut) <<<
class PowerResponse(PostDetailOut):
	power_threshold: int
	power_triggered: bool
	new_post_id: Optional[int] = None

# =========================
# OpenAI client + helpers
# =========================
import logging
from openai import OpenAI

logger = logging.getLogger("uvicorn.error")

OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
oa_client = OpenAI(api_key=OPENAI_API_KEY) if OPENAI_API_KEY else None

def _extract_json_array(text: str) -> Optional[str]:
	if not text:
		return None
	start = text.find("[")
	if start == -1:
		return None
	depth = 0
	for i in range(start, len(text)):
		ch = text[i]
		if ch == "[":
			depth += 1
		elif ch == "]":
			depth -= 1
			if depth == 0:
				return text[start:i+1]
	return None

def generate_facts_with_openai(topic: str, count: int = 5) -> List[str]:
	if not oa_client:
		raise RuntimeError("OPENAI_API_KEY not set on server")

	system = (
		"You are a helpful assistant. Output JSON that matches the schema exactly. "
		"Keep each fact <= 200 characters, factual, and non-overlapping."
	)
	user = (
		f"Generate {count} concise, interesting facts about '{topic}'. "
		"Return ONLY a JSON array of strings. No prose or extra keys."
	)

	def _parse_list(txt: str) -> Optional[List[str]]:
		try:
			arr = json.loads(txt)
			if isinstance(arr, list):
				return [str(s).strip() for s in arr if str(s).strip()]
		except Exception:
			pass
		sub = _extract_json_array(txt)
		if sub:
			try:
				arr = json.loads(sub)
				if isinstance(arr, list):
					return [str(s).strip() for s in arr if str(s).strip()]
			except Exception:
				pass
		return None

	raw_text = ""
	try:
		resp = oa_client.responses.create(
			model=OPENAI_MODEL,
			input=[{"role":"system","content":system},{"role":"user","content":user}],
		)
		raw_text = getattr(resp, "output_text", "") or ""
	except Exception:
		logger.exception("Responses API call failed topic=%r", topic)

	facts = _parse_list(raw_text)
	if not facts:
		try:
			resp2 = oa_client.chat.completions.create(
				model=OPENAI_MODEL,
				messages=[{"role":"system","content":system},{"role":"user","content":user}],
				temperature=0.7,
			)
			alt = resp2.choices[0].message.content
			facts = _parse_list(alt or "")
		except Exception:
			logger.exception("Chat Completions fallback failed topic=%r", topic)
			raise

	if not facts:
		raise RuntimeError("Model did not return valid JSON array")

	seen = set()
	out: List[str] = []
	for s in facts:
		ss = s.strip()
		if not ss or ss in seen:
			continue
		if len(ss) > 200:
			ss = ss[:197] + "…"
		seen.add(ss)
		out.append(ss)
		if len(out) >= count:
			break
	return out

def generate_expansion_with_openai(topic: str, brief: str, style: Optional[str] = None) -> str:
	if not oa_client:
		raise RuntimeError("OPENAI_API_KEY not set on server")

	system = (
		"You write concise, factual, readable expansions. "
		"Do not repeat the original line verbatim; build on it. "
		"Keep ~160–220 words, plain text (no JSON/markdown)."
	)
	user = (
		f"Subject: {topic}\n"
		f"Brief fact: {brief}\n"
		f"Expand this into a short, engaging mini-article suitable for an info card detail. "
		"Stay factual and self-contained. "
		f"{'Style hint: ' + style if style else ''}"
	)

	text_out = ""
	try:
		resp = oa_client.responses.create(
			model=OPENAI_MODEL,
			input=[{"role":"system","content":system},{"role":"user","content":user}],
		)
		text_out = (getattr(resp, "output_text", "") or "").strip()
	except Exception:
		logger.exception("Responses API (expand) failed")

	if not text_out:
		try:
			resp2 = oa_client.chat.completions.create(
				model=OPENAI_MODEL,
				messages=[{"role":"system","content":system},{"role":"user","content":user}],
				temperature=0.7,
			)
			text_out = (resp2.choices[0].message.content or "").strip()
		except Exception:
			logger.exception("Chat Completions (expand) failed")
			raise

	if len(text_out) > 2000:
		text_out = text_out[:2000] + "…"
	return text_out

def generate_followup_with_openai(topic: str, base_text: str) -> str:
	"""
	Create one new, distinct, interesting line related to the original post.
	Keep it short (<= 200 chars), output plain text only.
	"""
	if not oa_client:
		raise RuntimeError("OPENAI_API_KEY not set on server")
	system = "You generate single-line interesting facts. Output only one short line (<= 200 chars)."
	user = (
		f"Original topic: {topic}\n"
		f"Original text: {base_text}\n"
		"Create one new, distinct, interesting line closely related to this topic."
	)
	try:
		resp = oa_client.responses.create(
			model=OPENAI_MODEL,
			input=[{"role":"system","content":system},{"role":"user","content":user}],
		)
		line = (getattr(resp, "output_text", "") or "").strip()
		if len(line) > 200:
			line = line[:197] + "…"
		return line
	except Exception:
		logger.exception("followup generation failed")
		raise

def save_unique_facts(db: Session, topic: str, facts: List[str]) -> List[Post]:
	created: List[Post] = []
	for f in facts:
		try:
			obj = Post(topic=topic, text=f)
			db.add(obj)
			db.flush()
			created.append(obj)
		except IntegrityError:
			db.rollback()
			continue
	db.commit()
	for obj in created:
		db.refresh(obj)
	return created

def background_generate_and_save(topic: str, count: int):
	db = SessionLocal()
	try:
		facts = generate_facts_with_openai(topic, count)
		save_unique_facts(db, topic, facts)
	finally:
		db.close()

# =========================
# Routers
# =========================
diagnostics = APIRouter(tags=["Diagnostics"])
posts_api = APIRouter(tags=["Posts"])
generation = APIRouter(tags=["Generation"])

# =========================
# Startup log
# =========================
@app.on_event("startup")
def _startup_log():
	key = os.getenv("OPENAI_API_KEY")
	logger.info("Startup: DB=%s | MODEL=%s | OPENAI_KEY=%s | POWER_THRESHOLD=%s",
		DATABASE_URL, OPENAI_MODEL, "present" if key else "MISSING", POWER_THRESHOLD)

# =========================
# Diagnostics
# =========================
@diagnostics.get("/healthz")
def healthz():
	try:
		scheme = DATABASE_URL.split("://", 1)[0]
	except Exception:
		scheme = "unknown"
	return {
		"ok": True,
		"db": scheme,
		"model": OPENAI_MODEL,
		"debug": DEBUG,
		"power_threshold": POWER_THRESHOLD,
		"version": app.version
	}

@diagnostics.get("/openai/check")
def openai_check():
	try:
		if not oa_client:
			raise RuntimeError("OPENAI_API_KEY not set on server")
		test = oa_client.responses.create(model=OPENAI_MODEL, input=[{"role":"user","content":"say 'pong' only"}])
		return {"ok": True, "model": OPENAI_MODEL, "sample": test.output_text[:50]}
	except Exception as e:
		logger.exception("OpenAI check failed")
		if DEBUG:
			raise HTTPException(status_code=500, detail=f"OpenAI check failed: {e}")
		raise HTTPException(status_code=500, detail="OpenAI check failed")

# =========================
# Admin migrations
# =========================
@posts_api.post("/admin/migrate/expansion", dependencies=[Depends(require_api_key)])
def migrate_expansion_columns(db: Session = Depends(get_db)):
	try:
		db.execute(text("ALTER TABLE posts ADD COLUMN IF NOT EXISTS expanded_text TEXT;"))
		db.execute(text("ALTER TABLE posts ADD COLUMN IF NOT EXISTS expanded_at   TIMESTAMP;"))
		db.commit()
		return {"ok": True, "message": "Columns ensured (expanded_text, expanded_at)."}
	except Exception as e:
		db.rollback()
		raise HTTPException(status_code=500, detail=f"Migration failed: {e}")

@posts_api.post("/admin/migrate/votes", dependencies=[Depends(require_api_key)])
def migrate_votes(db: Session = Depends(get_db)):
	try:
		db.execute(text("ALTER TABLE posts ADD COLUMN IF NOT EXISTS score INTEGER NOT NULL DEFAULT 0;"))
		db.execute(text("ALTER TABLE posts ADD COLUMN IF NOT EXISTS upvotes INTEGER NOT NULL DEFAULT 0;"))
		db.execute(text("ALTER TABLE posts ADD COLUMN IF NOT EXISTS downvotes INTEGER NOT NULL DEFAULT 0;"))
		db.execute(text("""
			CREATE TABLE IF NOT EXISTS votes (
				id SERIAL PRIMARY KEY,
				post_id INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
				user_id TEXT NOT NULL,
				value INTEGER NOT NULL DEFAULT 0,
				timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
				CONSTRAINT uq_vote_post_user UNIQUE (post_id, user_id)
			);
		"""))
		db.commit()
		return {"ok": True, "message": "Votes schema ensured."}
	except Exception as e:
		db.rollback()
		raise HTTPException(status_code=500, detail=f"Migration failed: {e}")

@posts_api.post("/admin/migrate/reactions", dependencies=[Depends(require_api_key)])
def migrate_reactions(db: Session = Depends(get_db)):
	try:
		db.execute(text("ALTER TABLE posts ADD COLUMN IF NOT EXISTS learned_count   INTEGER NOT NULL DEFAULT 0;"))
		db.execute(text("ALTER TABLE posts ADD COLUMN IF NOT EXISTS surprised_count INTEGER NOT NULL DEFAULT 0;"))
		db.execute(text("""
			CREATE TABLE IF NOT EXISTS reactions (
				id SERIAL PRIMARY KEY,
				post_id INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
				user_id TEXT NOT NULL,
				learned BOOLEAN NOT NULL DEFAULT FALSE,
				surprised BOOLEAN NOT NULL DEFAULT FALSE,
				timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
				CONSTRAINT uq_reaction_post_user UNIQUE (post_id, user_id)
			);
		"""))
		db.commit()
		return {"ok": True, "message": "Reactions schema ensured."}
	except Exception as e:
		db.rollback()
		raise HTTPException(status_code=500, detail=f"Migration failed: {e}")

@posts_api.post("/admin/migrate/power", dependencies=[Depends(require_api_key)])
def migrate_power(db: Session = Depends(get_db)):
	try:
		db.execute(text("ALTER TABLE posts ADD COLUMN IF NOT EXISTS power_count INTEGER NOT NULL DEFAULT 0;"))
		db.execute(text("ALTER TABLE posts ADD COLUMN IF NOT EXISTS parent_id   INTEGER NULL REFERENCES posts(id) ON DELETE SET NULL;"))
		db.execute(text("""
			CREATE TABLE IF NOT EXISTS powers (
				id SERIAL PRIMARY KEY,
				post_id INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
				user_id TEXT NOT NULL,
				enabled BOOLEAN NOT NULL DEFAULT FALSE,
				timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
				CONSTRAINT uq_power_post_user UNIQUE (post_id, user_id)
			);
		"""))
		db.commit()
		return {"ok": True, "message": "Power schema ensured."}
	except Exception as e:
		db.rollback()
		raise HTTPException(status_code=500, detail=f"Migration failed: {e}")

# =========================
# Helpers
# =========================
def _get_user_id(request: Request) -> Optional[str]:
	return request.headers.get("X-User-Id")

def _post_with_state(p: Post, my_vote: Optional[int], my_flags: Optional[dict], my_powered: Optional[bool]) -> dict:
	flags = my_flags or {}
	return {
		"id": p.id,
		"topic": p.topic,
		"text": p.text,
		"timestamp": p.timestamp,
		"expanded_text": getattr(p, "expanded_text", None),
		"expanded_at": getattr(p, "expanded_at", None),
		"score": getattr(p, "score", 0),
		"upvotes": getattr(p, "upvotes", 0),
		"downvotes": getattr(p, "downvotes", 0),
		"my_vote": my_vote,
		"learned_count": getattr(p, "learned_count", 0),
		"surprised_count": getattr(p, "surprised_count", 0),
		"my_learned": flags.get("learned"),
		"my_surprised": flags.get("surprised"),
		"power_count": getattr(p, "power_count", 0),
		"my_powered": my_powered,
	}

def _enrich_with_user_state(rows: List[Post], user_id: Optional[str], db: Session) -> List[dict]:
	if not user_id:
		return rows
	ids = [r.id for r in rows] or [0]
	votes = db.query(Vote).filter(Vote.user_id==user_id, Vote.post_id.in_(ids)).all()
	reacs = db.query(Reaction).filter(Reaction.user_id==user_id, Reaction.post_id.in_(ids)).all()
	pows  = db.query(Power).filter(Power.user_id==user_id, Power.post_id.in_(ids)).all()
	by_vote = {v.post_id:int(v.value) for v in votes}
	by_reac = {r.post_id: {"learned":bool(r.learned), "surprised":bool(r.surprised)} for r in reacs}
	by_pow  = {p.post_id: bool(p.enabled) for p in pows}
	out: List[dict] = []
	for r in rows:
		out.append(_post_with_state(r, by_vote.get(r.id), by_reac.get(r.id), by_pow.get(r.id)))
	return out

# =========================
# Posts CRUD / list / detail
# =========================
@posts_api.post("/posts", response_model=PostOut, dependencies=[Depends(require_api_key)])
def create_post(post: PostIn, db: Session = Depends(get_db)):
	try:
		obj = Post(topic=post.topic, text=post.text)
		db.add(obj); db.commit(); db.refresh(obj)
		return obj
	except IntegrityError:
		db.rollback()
		raise HTTPException(status_code=409, detail="Duplicate post text")
	except Exception:
		db.rollback()
		raise HTTPException(status_code=500, detail="Internal Server Error")

@posts_api.post("/posts/bulk", response_model=List[PostOut], dependencies=[Depends(require_api_key)])
def create_posts_bulk(posts: List[PostIn], db: Session = Depends(get_db)):
	created = []
	for p in posts:
		try:
			obj = Post(topic=p.topic, text=p.text)
			db.add(obj); db.flush()
			created.append(obj)
		except IntegrityError:
			db.rollback()
			continue
	db.commit()
	for obj in created:
		db.refresh(obj)
	return created

@posts_api.get("/posts", response_model=List[PostDetailOut], dependencies=[Depends(require_api_key)])
def get_posts(
	request: Request,
	topic: Optional[str] = None,
	limit: int = 20,
	offset: int = 0,
	random: bool = False,
	exclude_ids: Optional[str] = Query(None, description="Comma-separated post IDs to exclude"),
	db: Session = Depends(get_db),
):
	user_id = _get_user_id(request)
	excluded: List[int] = []
	if exclude_ids:
		try:
			excluded = [int(x) for x in exclude_ids.split(",") if x.strip().isdigit()]
		except Exception:
			excluded = []
	q = db.query(Post)
	if topic:
		q = q.filter(Post.topic == topic)
	if excluded:
		q = q.filter(~Post.id.in_(excluded))
	if random and not topic:
		q = q.order_by(func.random())
	else:
		q = q.order_by(Post.timestamp.desc())
	rows = q.limit(limit).offset(0 if random else offset).all()
	return _enrich_with_user_state(rows, user_id, db)

@posts_api.get("/posts/mixed", response_model=List[PostDetailOut], dependencies=[Depends(require_api_key)])
def get_mixed(
	request: Request,
	count: int = 10,
	random: bool = False,
	exclude_ids: Optional[str] = Query(None, description="Comma-separated post IDs to exclude"),
	db: Session = Depends(get_db),
):
	user_id = _get_user_id(request)
	excluded: List[int] = []
	if exclude_ids:
		try:
			excluded = [int(x) for x in exclude_ids.split(",") if x.strip().isdigit()]
		except Exception:
			excluded = []
	q = db.query(Post)
	if excluded:
		q = q.filter(~Post.id.in_(excluded))
	if random:
		q = q.order_by(func.random())
	else:
		q = q.order_by(Post.timestamp.desc())
	rows = q.limit(count).all()
	return _enrich_with_user_state(rows, user_id, db)

@posts_api.get("/posts/{post_id}", response_model=PostDetailOut, dependencies=[Depends(require_api_key)])
def get_post_detail(post_id: int, request: Request, db: Session = Depends(get_db)):
	user_id = _get_user_id(request)
	obj = db.query(Post).get(post_id)
	if not obj:
		raise HTTPException(status_code=404, detail="Not found")
	if not user_id:
		return obj
	v = db.query(Vote).filter(Vote.post_id == post_id, Vote.user_id == user_id).one_or_none()
	r = db.query(Reaction).filter(Reaction.post_id == post_id, Reaction.user_id == user_id).one_or_none()
	p = db.query(Power).filter(Power.post_id == post_id, Power.user_id == user_id).one_or_none()
	return _post_with_state(
		obj,
		int(v.value) if v else None,
		{"learned": bool(r.learned), "surprised": bool(r.surprised)} if r else None,
		bool(p.enabled) if p else None
	)

# =========================
# Expand
# =========================
@posts_api.post("/posts/{post_id}/expand", response_model=PostDetailOut, dependencies=[Depends(require_api_key)])
def expand_post(post_id: int, payload: ExpandIn, request: Request, db: Session = Depends(get_db)):
	user_id = _get_user_id(request)
	obj = db.query(Post).get(post_id)
	if not obj:
		raise HTTPException(status_code=404, detail="Not found")
	try:
		if payload.force or not obj.expanded_text:
			longer = generate_expansion_with_openai(obj.topic, obj.text, payload.style)
			obj.expanded_text = longer
			obj.expanded_at = datetime.utcnow()
			db.add(obj); db.commit(); db.refresh(obj)
		if not user_id:
			return obj
		v = db.query(Vote).filter(Vote.post_id == post_id, Vote.user_id == user_id).one_or_none()
		r = db.query(Reaction).filter(Reaction.post_id == post_id, Reaction.user_id == user_id).one_or_none()
		p = db.query(Power).filter(Power.post_id == post_id, Power.user_id == user_id).one_or_none()
		return _post_with_state(
			obj,
			int(v.value) if v else None,
			{"learned": bool(r.learned), "surprised": bool(r.surprised)} if r else None,
			bool(p.enabled) if p else None
		)
	except Exception as e:
		logger.exception("Expand failed id=%s", post_id)
		if DEBUG:
			raise HTTPException(status_code=500, detail=f"Expand failed: {e}")
		raise HTTPException(status_code=500, detail="Expand failed")

# =========================
# Vote
# =========================
@posts_api.post("/posts/{post_id}/vote", response_model=PostDetailOut, dependencies=[Depends(require_api_key)])
def vote_post(post_id: int, body: VoteIn, request: Request, db: Session = Depends(get_db)):
	user_id = _get_user_id(request)
	if not user_id:
		raise HTTPException(status_code=400, detail="X-User-Id header required")
	if body.value not in (-1, 0, 1):
		raise HTTPException(status_code=400, detail="value must be -1, 0, or 1")

	post = db.query(Post).get(post_id)
	if not post:
		raise HTTPException(status_code=404, detail="Not found")

	vote = db.query(Vote).filter(Vote.post_id == post_id, Vote.user_id == user_id).one_or_none()
	old = 0 if not vote else int(vote.value)
	new = int(body.value)
	if old != new:
		if old == 1:
			post.upvotes = max(0, post.upvotes - 1); post.score -= 1
		elif old == -1:
			post.downvotes = max(0, post.downvotes - 1); post.score += 1
		if new == 1:
			post.upvotes += 1; post.score += 1
		elif new == -1:
			post.downvotes += 1; post.score -= 1

		if new == 0:
			if vote:
				db.delete(vote)
		else:
			if not vote:
				vote = Vote(post_id=post_id, user_id=user_id, value=new)
				db.add(vote)
			else:
				vote.value = new
				vote.timestamp = datetime.utcnow()

	db.add(post)
	db.commit(); db.refresh(post)

	r = db.query(Reaction).filter(Reaction.post_id == post_id, Reaction.user_id == user_id).one_or_none()
	p = db.query(Power).filter(Power.post_id == post_id, Power.user_id == user_id).one_or_none()
	return _post_with_state(post, new if old != new else old, {"learned": bool(r.learned), "surprised": bool(r.surprised)} if r else None, bool(p.enabled) if p else None)

# =========================
# React (learned / surprised)
# =========================
@posts_api.post("/posts/{post_id}/react", response_model=PostDetailOut, dependencies=[Depends(require_api_key)])
def react_post(post_id: int, body: ReactIn, request: Request, db: Session = Depends(get_db)):
	user_id = _get_user_id(request)
	if not user_id:
		raise HTTPException(status_code=400, detail="X-User-Id header required")

	post = db.query(Post).get(post_id)
	if not post:
		raise HTTPException(status_code=404, detail="Not found")

	react = db.query(Reaction).filter(Reaction.post_id == post_id, Reaction.user_id == user_id).one_or_none()
	if not react:
		react = Reaction(post_id=post_id, user_id=user_id, learned=False, surprised=False)
		db.add(react); db.flush()

	def _apply(flag_name: str, new_val: Optional[bool], counter_attr: str):
		if new_val is None:
			return
		old = bool(getattr(react, flag_name))
		if old == bool(new_val):
			return
		setattr(react, flag_name, bool(new_val))
		if new_val:
			setattr(post, counter_attr, getattr(post, counter_attr) + 1)
		else:
			setattr(post, counter_attr, max(0, getattr(post, counter_attr) - 1))

	_apply("learned", body.learned, "learned_count")
	_apply("surprised", body.surprised, "surprised_count")

	react.timestamp = datetime.utcnow()
	db.add(post); db.add(react); db.commit(); db.refresh(post)

	v = db.query(Vote).filter(Vote.post_id == post_id, Vote.user_id == user_id).one_or_none()
	p = db.query(Power).filter(Power.post_id == post_id, Power.user_id == user_id).one_or_none()
	return _post_with_state(post, int(v.value) if v else None, {"learned": bool(react.learned), "surprised": bool(react.surprised)}, bool(p.enabled) if p else None)

# =========================
# Power (gauge)
# =========================
@posts_api.post("/posts/{post_id}/power", response_model=PowerResponse, dependencies=[Depends(require_api_key)])
def power_post(post_id: int, body: PowerIn, request: Request, db: Session = Depends(get_db)):
	user_id = _get_user_id(request)
	if not user_id:
		raise HTTPException(status_code=400, detail="X-User-Id header required")

	post = db.query(Post).get(post_id)
	if not post:
		raise HTTPException(status_code=404, detail="Not found")

	p = db.query(Power).filter(Power.post_id==post_id, Power.user_id==user_id).one_or_none()
	old = bool(p.enabled) if p else False
	new = bool(body.enabled)

	# no change → return current state
	if old == new:
		v = db.query(Vote).filter(Vote.post_id==post_id, Vote.user_id==user_id).one_or_none()
		r = db.query(Reaction).filter(Reaction.post_id==post_id, Reaction.user_id==user_id).one_or_none()
		resp = _post_with_state(post, int(v.value) if v else None, {"learned": bool(r.learned), "surprised": bool(r.surprised)} if r else None, new)
		resp["power_threshold"] = POWER_THRESHOLD
		resp["power_triggered"] = False
		resp["new_post_id"] = None
		logger.info("power_resp post_id=%s user=%s count=%s threshold=%s triggered=%s new_post_id=%s",
			post_id, user_id, getattr(post, "power_count", None), POWER_THRESHOLD, False, None)
		return resp

	# adjust post power_count
	if new and not old:
		post.power_count += 1
	elif old and not new:
		post.power_count = max(0, post.power_count - 1)

	# write row
	if not p:
		p = Power(post_id=post_id, user_id=user_id, enabled=new)
		db.add(p)
	else:
		p.enabled = new
		p.timestamp = datetime.utcnow()

	triggered = False
	new_post_id = None

	# threshold logic
	if post.power_count >= POWER_THRESHOLD:
		try:
			related = generate_followup_with_openai(post.topic, post.text)
			child = Post(topic=post.topic, text=related, parent_id=post.id)
			db.add(child); db.flush()
			new_post_id = child.id
			# reset original
			post.power_count = 0
			# clear power toggles so users can power again later
			db.query(Power).filter(Power.post_id==post_id).delete()
			triggered = True
		except Exception:
			logger.exception("Power trigger follow-up failed (post_id=%s)", post_id)

	db.add(post)
	db.commit(); db.refresh(post)

	# include user state
	v = db.query(Vote).filter(Vote.post_id==post_id, Vote.user_id==user_id).one_or_none()
	r = db.query(Reaction).filter(Reaction.post_id==post_id, Reaction.user_id==user_id).one_or_none()
	resp = _post_with_state(post, int(v.value) if v else None, {"learned": bool(r.learned), "surprised": bool(r.surprised)} if r else None, new)
	resp["power_threshold"] = POWER_THRESHOLD
	resp["power_triggered"] = triggered
	resp["new_post_id"] = new_post_id

	logger.info("power_resp post_id=%s user=%s count=%s threshold=%s triggered=%s new_post_id=%s",
		post_id, user_id, getattr(post, "power_count", None), POWER_THRESHOLD, triggered, new_post_id)

	return resp

# =========================
# Generation
# =========================
@generation.post("/generate", response_model=List[PostOut], dependencies=[Depends(require_api_key)])
def generate_posts(payload: GenerateIn, db: Session = Depends(get_db)):
	if payload.count <= 0 or payload.count > 50:
		raise HTTPException(status_code=400, detail="count must be 1..50")
	try:
		facts = generate_facts_with_openai(payload.topic, payload.count)
		return save_unique_facts(db, payload.topic, facts)
	except Exception as e:
		if DEBUG:
			raise HTTPException(status_code=500, detail=f"Generation failed: {e}")
		raise HTTPException(status_code=500, detail="Generation failed")

@generation.post("/subjects/{topic}/generate/batch", response_model=List[PostOut], dependencies=[Depends(require_api_key)])
def generate_batch_for_subject(topic: str, body: SubjectBatchIn, db: Session = Depends(get_db)):
	if body.count <= 0 or body.count > 100:
		raise HTTPException(status_code=400, detail="count must be 1..100")
	try:
		facts = generate_facts_with_openai(topic, body.count)
		return save_unique_facts(db, topic, facts)
	except Exception as e:
		if DEBUG:
			raise HTTPException(status_code=500, detail=f"Generation failed: {e}")
		raise HTTPException(status_code=500, detail="Generation failed")

@generation.post("/generate/batch", response_model=List[PostOut], dependencies=[Depends(require_api_key)])
def generate_multi_subject(body: MultiGenerateIn, db: Session = Depends(get_db)):
	if not body.items:
		raise HTTPException(status_code=400, detail="items required")
	created_all: List[Post] = []
	for item in body.items:
		if item.count <= 0 or item.count > 50:
			continue
		try:
			facts = generate_facts_with_openai(item.topic, item.count)
			created_all.extend(save_unique_facts(db, item.topic, facts))
		except Exception:
			continue
	return created_all

# =========================
# Mount routers
# =========================
app.include_router(diagnostics)
app.include_router(posts_api)
app.include_router(generation)

