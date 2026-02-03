from __future__ import annotations

import json
import os
import random
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse

APP_DIR = Path(__file__).resolve().parent
SEED_PATH = APP_DIR / "posts_seed.json"
STATE_PATH = APP_DIR / "state.json"

SCHEMA_VERSION = 0

DEFAULT_TOPICS = [
    "space",
    "cooking",
    "biology",
    "octopuses",
    "neuroscience",
    "art",
    "history",
    "computers",
    "energy",
]

POWER_THRESHOLD_DEFAULT = 5


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def clamp_int(x: Any, lo: int, hi: int, default: int) -> int:
    try:
        v = int(x)
    except Exception:
        return default
    return max(lo, min(hi, v))


def read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def write_json(path: Path, data: Any) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    tmp.replace(path)


def get_user_id(x_user_id: Optional[str]) -> str:
    # Your frontend always sends X-User-Id; but dummy backend is forgiving.
    uid = (x_user_id or "").strip()
    return uid if uid else "anon"


# -------------------------
# In-memory model + storage
# -------------------------

@dataclass
class Post:
    id: int
    topic: str
    text: str
    timestamp: str

    # aggregate counts (global)
    upvotes: int = 0
    downvotes: int = 0
    learned_count: int = 0
    surprised_count: int = 0
    power_count: int = 0

    # optional expansion
    expanded_text: Optional[str] = None
    expanded_at: Optional[str] = None

    # future-proof metadata
    tags: Optional[List[str]] = None
    author: Optional[Dict[str, Any]] = None
    parent_id: Optional[int] = None
    lineage: Optional[Dict[str, Any]] = None
    source: Optional[Dict[str, Any]] = None

    def score(self) -> int:
        return int(self.upvotes) - int(self.downvotes)

    def to_public(self, user_state: Dict[str, Any]) -> Dict[str, Any]:
        """Return a JSON dict with viewer-specific fields merged in."""
        pid = self.id
        my_vote = int(user_state.get("votes", {}).get(str(pid), 0))

        reactions = user_state.get("reactions", {}).get(str(pid), {})
        my_learned = bool(reactions.get("learned", False))
        my_surprised = bool(reactions.get("surprised", False))

        my_powered = bool(user_state.get("power", {}).get(str(pid), False))

        d: Dict[str, Any] = {
            "schema_version": SCHEMA_VERSION,
            "id": self.id,
            "topic": self.topic,
            "text": self.text,
            "timestamp": self.timestamp,

            "score": self.score(),
            "upvotes": self.upvotes,
            "downvotes": self.downvotes,

            "learned_count": self.learned_count,
            "surprised_count": self.surprised_count,
            "power_count": self.power_count,

            "my_vote": my_vote,
            "my_learned": my_learned,
            "my_surprised": my_surprised,
            "my_powered": my_powered,

            "expanded_text": self.expanded_text,
            "expanded_at": self.expanded_at,
        }

        # Optional future-proof metadata (safe if None)
        if self.tags is not None:
            d["tags"] = self.tags
        if self.author is not None:
            d["author"] = self.author
        if self.parent_id is not None:
            d["parent_id"] = self.parent_id
        if self.lineage is not None:
            d["lineage"] = self.lineage
        if self.source is not None:
            d["source"] = self.source

        return d


class Store:
    """
    Stores posts (global) + per-user state.
    Persists user state (and optionally posts) to STATE_PATH as JSON.
    """

    def __init__(self) -> None:
        self.posts: Dict[int, Post] = {}
        self.next_id: int = 1

        # user_id -> state
        # state: { votes: {post_id_str:int}, reactions:{post_id_str:{learned:bool,surprised:bool}}, power:{post_id_str:bool} }
        self.user_state: Dict[str, Dict[str, Any]] = {}

        # power threshold can be per-post later; keep global for now
        self.power_threshold: int = POWER_THRESHOLD_DEFAULT

    def load(self) -> None:
        # Load seed posts
        seed = read_json(SEED_PATH, default=None)
        if isinstance(seed, list) and seed:
            self._load_posts_from_seed(seed)
        else:
            self._generate_seed_posts()

        # Load persisted state (per-user) and (optionally) post overrides
        state = read_json(STATE_PATH, default={})
        if isinstance(state, dict):
            us = state.get("user_state", {})
            if isinstance(us, dict):
                self.user_state = us
            # Optional: allow persisting posts too (but not required)
            # We only apply counters if present.
            posts_over = state.get("posts_overrides", {})
            if isinstance(posts_over, dict):
                self._apply_post_overrides(posts_over)

        self.next_id = max(self.posts.keys(), default=0) + 1

    def save(self) -> None:
        # Persist user state and lightweight per-post counters so votes survive too.
        posts_overrides: Dict[str, Any] = {}
        for pid, p in self.posts.items():
            posts_overrides[str(pid)] = {
                "upvotes": p.upvotes,
                "downvotes": p.downvotes,
                "learned_count": p.learned_count,
                "surprised_count": p.surprised_count,
                "power_count": p.power_count,
                "expanded_text": p.expanded_text,
                "expanded_at": p.expanded_at,
                "parent_id": p.parent_id,
                "lineage": p.lineage,
            }

        data = {
            "user_state": self.user_state,
            "posts_overrides": posts_overrides,
            "meta": {"saved_at": now_iso()},
        }
        write_json(STATE_PATH, data)

    def _load_posts_from_seed(self, seed_posts: List[Dict[str, Any]]) -> None:
        for raw in seed_posts:
            try:
                pid = int(raw.get("id"))
            except Exception:
                continue
            topic = str(raw.get("topic", "") or "")
            text = str(raw.get("text", "") or "")
            ts = str(raw.get("timestamp", "") or now_iso())
            if not topic or not text or pid <= 0:
                continue

            p = Post(
                id=pid,
                topic=topic,
                text=text,
                timestamp=ts,
                upvotes=int(raw.get("upvotes", 0) or 0),
                downvotes=int(raw.get("downvotes", 0) or 0),
                learned_count=int(raw.get("learned_count", 0) or 0),
                surprised_count=int(raw.get("surprised_count", 0) or 0),
                power_count=int(raw.get("power_count", 0) or 0),
                expanded_text=raw.get("expanded_text", None),
                expanded_at=raw.get("expanded_at", None),
                tags=raw.get("tags", None),
                author=raw.get("author", None),
                parent_id=raw.get("parent_id", None),
                lineage=raw.get("lineage", None),
                source=raw.get("source", {"kind": "dummy", "model": None}),
            )
            self.posts[p.id] = p

    def _apply_post_overrides(self, overrides: Dict[str, Any]) -> None:
        for pid_str, o in overrides.items():
            try:
                pid = int(pid_str)
            except Exception:
                continue
            if pid not in self.posts:
                continue
            p = self.posts[pid]
            if isinstance(o, dict):
                for k in ["upvotes", "downvotes", "learned_count", "surprised_count", "power_count"]:
                    if k in o:
                        try:
                            setattr(p, k, int(o[k]))
                        except Exception:
                            pass
                if "expanded_text" in o:
                    p.expanded_text = o.get("expanded_text")
                if "expanded_at" in o:
                    p.expanded_at = o.get("expanded_at")
                if "parent_id" in o:
                    p.parent_id = o.get("parent_id")
                if "lineage" in o:
                    p.lineage = o.get("lineage")

    def _generate_seed_posts(self, n_per_topic: int = 20) -> None:
        # Small deterministic-ish set; enough to test paging and filters.
        rng = random.Random(1337)
        pid = 1
        for topic in DEFAULT_TOPICS:
            for i in range(n_per_topic):
                text = self._dummy_post_text(topic, i)
                ts = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
                up = rng.randint(0, 20)
                down = rng.randint(0, 8)
                learned = rng.randint(0, 6)
                surprised = rng.randint(0, 4)
                power = rng.randint(0, 3)
                p = Post(
                    id=pid,
                    topic=topic,
                    text=text,
                    timestamp=ts,
                    upvotes=up,
                    downvotes=down,
                    learned_count=learned,
                    surprised_count=surprised,
                    power_count=power,
                    source={"kind": "dummy", "model": None},
                    author={"id": f"agent_{topic}", "display_name": f"@/{topic}"},
                )
                self.posts[pid] = p
                pid += 1

        self.next_id = pid
        # Write out a seed file so contributors can edit content easily.
        seed_dump = [self.posts[k].to_public(user_state={"votes": {}, "reactions": {}, "power": {}}) for k in sorted(self.posts)]
        write_json(SEED_PATH, seed_dump)

    @staticmethod
    def _dummy_post_text(topic: str, idx: int) -> str:
        # Keep short-ish for feed cards; expansion endpoint provides longer text.
        prompts = {
            "cooking": [
                "Broth hack: roast onions/ginger first, then simmer bones low and slow.",
                "If soup is breakfast: prep aromatics and freeze in small cubes.",
                "Umami layering: kombu + dried shiitake + daikon gives depth fast.",
            ],
            "computers": [
                "Design tip: separate data contracts from presentation—your future self will thank you.",
                "When debugging, log the shape of your JSON before you trust it.",
                "Paging bug pattern: increment offset by returned length, not page size.",
            ],
            "energy": [
                "Wind + solar hybrid systems often benefit from a battery buffer more than peak generation.",
                "Heat loss dominates small greenhouses—insulation and air sealing are huge.",
                "Thermal mass can smooth day/night swings with surprisingly little complexity.",
            ],
        }
        base = prompts.get(topic, [
            f"Quick thought on {topic}: build a tiny experiment, then scale the pattern.",
            f"{topic} note: invariants show up when you compare across domains.",
            f"{topic} idea: treat metadata as optional so your UI can evolve freely.",
        ])
        return base[idx % len(base)]

    def ensure_user(self, user_id: str) -> Dict[str, Any]:
        if user_id not in self.user_state:
            self.user_state[user_id] = {"votes": {}, "reactions": {}, "power": {}}
        # Ensure keys exist
        st = self.user_state[user_id]
        st.setdefault("votes", {})
        st.setdefault("reactions", {})
        st.setdefault("power", {})
        return st

    def list_posts(self, topic: Optional[str], limit: int, offset: int) -> List[Post]:
        posts = list(self.posts.values())
        # Most recent first (timestamp string is ISO; lexicographically sortable if consistent)
        posts.sort(key=lambda p: p.timestamp, reverse=True)

        if topic:
            posts = [p for p in posts if p.topic == topic]

        return posts[offset: offset + limit]

    def mixed_posts(self, count: int) -> List[Post]:
        posts = list(self.posts.values())
        posts.sort(key=lambda p: p.timestamp, reverse=True)
        # Take a mix by topic rather than purely newest to keep it interesting.
        by_topic: Dict[str, List[Post]] = {}
        for p in posts:
            by_topic.setdefault(p.topic, []).append(p)

        out: List[Post] = []
        topics = list(by_topic.keys())
        random.shuffle(topics)
        # Round-robin pull
        while len(out) < count and topics:
            progressed = False
            for t in list(topics):
                if len(out) >= count:
                    break
                lst = by_topic.get(t, [])
                if lst:
                    out.append(lst.pop(0))
                    progressed = True
                else:
                    topics.remove(t)
            if not progressed:
                break
        return out[:count]

    def get_post(self, post_id: int) -> Post:
        p = self.posts.get(post_id)
        if not p:
            raise KeyError(post_id)
        return p

    def set_vote(self, user_id: str, post_id: int, value: int) -> Tuple[int, int]:
        """
        value in {-1,0,1}
        Returns: (new_score, my_vote)
        """
        if post_id not in self.posts:
            raise KeyError(post_id)
        p = self.posts[post_id]
        st = self.ensure_user(user_id)
        votes = st["votes"]
        old = int(votes.get(str(post_id), 0))
        new = int(value)

        # Remove old effect
        if old == 1:
            p.upvotes = max(0, p.upvotes - 1)
        elif old == -1:
            p.downvotes = max(0, p.downvotes - 1)

        # Apply new effect
        if new == 1:
            p.upvotes += 1
        elif new == -1:
            p.downvotes += 1

        votes[str(post_id)] = new
        self.save()
        return (p.score(), new)

    def toggle_react(self, user_id: str, post_id: int, learned: Optional[bool], surprised: Optional[bool]) -> Dict[str, Any]:
        if post_id not in self.posts:
            raise KeyError(post_id)
        p = self.posts[post_id]
        st = self.ensure_user(user_id)
        reacts = st["reactions"].setdefault(str(post_id), {"learned": False, "surprised": False})

        if learned is not None:
            old = bool(reacts.get("learned", False))
            new = bool(learned)
            if old != new:
                reacts["learned"] = new
                p.learned_count += (1 if new else -1)
                p.learned_count = max(0, p.learned_count)

        if surprised is not None:
            old = bool(reacts.get("surprised", False))
            new = bool(surprised)
            if old != new:
                reacts["surprised"] = new
                p.surprised_count += (1 if new else -1)
                p.surprised_count = max(0, p.surprised_count)

        self.save()

        return {
            "id": post_id,
            "power_count": p.power_count,
            "learned_count": p.learned_count,
            "surprised_count": p.surprised_count,
            "my_powered": bool(st["power"].get(str(post_id), False)),
            "my_learned": bool(reacts.get("learned", False)),
            "my_surprised": bool(reacts.get("surprised", False)),
        }

    def expand_post(self, post_id: int) -> Post:
        if post_id not in self.posts:
            raise KeyError(post_id)
        p = self.posts[post_id]
        if p.expanded_text:
            return p

        # Simple deterministic expansion; no OpenAI dependency.
        # You can replace this later with a “templated” or markov-ish expander if desired.
        p.expanded_text = (
            f"{p.text}\n\n"
            f"— Expanded context —\n"
            f"This is dummy expanded text for post #{p.id} in topic '{p.topic}'.\n"
            f"It exists to exercise your modal UI, scrolling, and reaction/vote syncing.\n\n"
            f"Potential directions:\n"
            f"- Add tags for multi-axis organization beyond topic.\n"
            f"- Track parent/child lineage for 'power spawn' and visible legacy.\n"
            f"- Store per-user state keyed by X-User-Id.\n"
        )
        p.expanded_at = now_iso()
        self.save()
        return p

    def set_power(self, user_id: str, post_id: int, enabled: bool) -> Dict[str, Any]:
        if post_id not in self.posts:
            raise KeyError(post_id)
        p = self.posts[post_id]
        st = self.ensure_user(user_id)
        power_map = st["power"]
        old = bool(power_map.get(str(post_id), False))
        new = bool(enabled)

        if old != new:
            power_map[str(post_id)] = new
            p.power_count += (1 if new else -1)
            p.power_count = max(0, p.power_count)

        triggered = False
        new_post_id = -1

        # Spawn a child post when threshold reached (global count), just to exercise your UI path.
        if p.power_count >= self.power_threshold and p.power_count > 0:
            # only spawn once per reaching threshold for this post; we track it via lineage marker
            if not (p.lineage or {}).get("spawned_at_threshold", False):
                triggered = True
                new_post_id = self._spawn_child_post(parent=p)
                # Mark parent so we don't keep spawning infinitely.
                p.lineage = p.lineage or {}
                p.lineage["spawned_at_threshold"] = True

        self.save()

        return {
            "id": post_id,
            "power_count": p.power_count,
            "my_powered": bool(st["power"].get(str(post_id), False)),
            "power_threshold": self.power_threshold,
            "power_triggered": triggered,
            "new_post_id": new_post_id,
        }

    def _spawn_child_post(self, parent: Post) -> int:
        pid = self.next_id
        self.next_id += 1

        child = Post(
            id=pid,
            topic=parent.topic,
            text=f"(Spawned) A powered follow-up to post #{parent.id}: build on the strongest thread and iterate.",
            timestamp=now_iso(),
            upvotes=0,
            downvotes=0,
            learned_count=0,
            surprised_count=0,
            power_count=0,
            parent_id=parent.id,
            lineage={"root_id": parent.lineage.get("root_id", parent.id) if parent.lineage else parent.id, "depth": 1},
            source={"kind": "dummy", "model": None},
            author={"id": "system_spawn", "display_name": "@/spawn"},
        )
        self.posts[child.id] = child
        return child.id


store = Store()
store.load()

app = FastAPI(title="Fathom Dummy Backend", version="0.1.0")


# ------------
# Error format
# ------------

@app.exception_handler(Exception)
async def unhandled_exception_handler(_request: Request, exc: Exception):
    # Avoid hiding errors during dev; still return JSON so the client can log cleanly.
    return JSONResponse(status_code=500, content={"error": str(exc)})


# --------
# Routes
# --------

@app.get("/health")
def health() -> Dict[str, Any]:
    return {"ok": True, "time": now_iso(), "posts": len(store.posts)}


@app.get("/posts/mixed")
def posts_mixed(
    count: int = 20,
    x_user_id: Optional[str] = Header(default=None, convert_underscores=False),
) -> List[Dict[str, Any]]:
    uid = get_user_id(x_user_id)
    st = store.ensure_user(uid)
    c = clamp_int(count, 1, 200, 20)
    posts = store.mixed_posts(c)
    return [p.to_public(st) for p in posts]


@app.get("/posts")
def posts_list(
    topic: Optional[str] = None,
    limit: int = 30,
    offset: int = 0,
    x_user_id: Optional[str] = Header(default=None, convert_underscores=False),
) -> List[Dict[str, Any]]:
    uid = get_user_id(x_user_id)
    st = store.ensure_user(uid)

    lim = clamp_int(limit, 1, 200, 30)
    off = clamp_int(offset, 0, 10_000_000, 0)

    t = (topic or "").strip()
    if t == "":
        t = None

    posts = store.list_posts(t, lim, off)
    return [p.to_public(st) for p in posts]


@app.get("/posts/{post_id}")
def post_get(
    post_id: int,
    x_user_id: Optional[str] = Header(default=None, convert_underscores=False),
) -> Dict[str, Any]:
    uid = get_user_id(x_user_id)
    st = store.ensure_user(uid)
    try:
        p = store.get_post(post_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="post not found")
    return p.to_public(st)


@app.post("/posts/{post_id}/expand")
def post_expand(
    post_id: int,
    x_user_id: Optional[str] = Header(default=None, convert_underscores=False),
) -> Dict[str, Any]:
    uid = get_user_id(x_user_id)
    st = store.ensure_user(uid)
    try:
        p = store.expand_post(post_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="post not found")
    return p.to_public(st)


@app.post("/posts/{post_id}/vote")
async def post_vote(
    post_id: int,
    request: Request,
    x_user_id: Optional[str] = Header(default=None, convert_underscores=False),
) -> Dict[str, Any]:
    uid = get_user_id(x_user_id)
    body = await request.json()
    value = clamp_int(body.get("value", 0), -1, 1, 0)
    try:
        score, my_vote = store.set_vote(uid, post_id, value)
    except KeyError:
        raise HTTPException(status_code=404, detail="post not found")

    return {"id": post_id, "score": score, "my_vote": my_vote}


@app.post("/posts/{post_id}/react")
async def post_react(
    post_id: int,
    request: Request,
    x_user_id: Optional[str] = Header(default=None, convert_underscores=False),
) -> Dict[str, Any]:
    uid = get_user_id(x_user_id)
    body = await request.json()

    learned = body.get("learned", None)
    surprised = body.get("surprised", None)

    # Allow booleans or truthy strings/ints
    def to_opt_bool(v: Any) -> Optional[bool]:
        if v is None:
            return None
        if isinstance(v, bool):
            return v
        if isinstance(v, (int, float)):
            return bool(v)
        if isinstance(v, str):
            s = v.strip().lower()
            if s in ("1", "true", "yes", "y", "on"):
                return True
            if s in ("0", "false", "no", "n", "off", ""):
                return False
        return None

    learned_b = to_opt_bool(learned)
    surprised_b = to_opt_bool(surprised)

    if learned_b is None and surprised_b is None:
        raise HTTPException(status_code=400, detail="body must include learned or surprised")

    try:
        result = store.toggle_react(uid, post_id, learned=learned_b, surprised=surprised_b)
    except KeyError:
        raise HTTPException(status_code=404, detail="post not found")

    return result


@app.post("/posts/{post_id}/power")
async def post_power(
    post_id: int,
    request: Request,
    x_user_id: Optional[str] = Header(default=None, convert_underscores=False),
) -> Dict[str, Any]:
    uid = get_user_id(x_user_id)
    body = await request.json()
    enabled = body.get("enabled", None)

    # Accept enabled bool; tolerate 0/1, "true"/"false"
    def to_bool(v: Any) -> bool:
        if isinstance(v, bool):
            return v
        if isinstance(v, (int, float)):
            return bool(v)
        if isinstance(v, str):
            s = v.strip().lower()
            if s in ("1", "true", "yes", "y", "on"):
                return True
            return False
        return False

    if enabled is None:
        raise HTTPException(status_code=400, detail="body must include enabled")

    try:
        result = store.set_power(uid, post_id, enabled=to_bool(enabled))
    except KeyError:
        raise HTTPException(status_code=404, detail="post not found")

    return result
