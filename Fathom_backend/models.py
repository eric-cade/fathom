# models.py
from datetime import datetime

from sqlalchemy import (
	Column, Integer, String, Text, DateTime,
	UniqueConstraint, ForeignKey, Boolean
)
from sqlalchemy.orm import declarative_base, relationship

Base = declarative_base()

class Post(Base):
	__tablename__ = "posts"

	id = Column(Integer, primary_key=True, index=True)
	topic = Column(String, index=True, nullable=False)
	text = Column(Text, nullable=False, unique=True)
	timestamp = Column(DateTime, default=datetime.utcnow, nullable=False)

	# expansion cache
	expanded_text = Column(Text, nullable=True)
	expanded_at = Column(DateTime, nullable=True)

	# voting counters (denormalized for fast sorting)
	score = Column(Integer, nullable=False, default=0)
	upvotes = Column(Integer, nullable=False, default=0)
	downvotes = Column(Integer, nullable=False, default=0)

	__table_args__ = (
		# optional but useful if you ever remove the unique=True above
		# UniqueConstraint("text", name="uq_posts_text"),
	)

	learned_count = Column(Integer, nullable=False, default=0)
	surprised_count = Column(Integer, nullable=False, default=0)

	# NEW: power
	power_count = Column(Integer, nullable=False, default=0)
	parent_id   = Column(Integer, ForeignKey("posts.id", ondelete="SET NULL"), nullable=True)

# One-per-user per post
class Power(Base):
	__tablename__ = "powers"
	id = Column(Integer, primary_key=True)
	post_id = Column(Integer, ForeignKey("posts.id", ondelete="CASCADE"), index=True, nullable=False)
	user_id = Column(String, nullable=False)
	# user can toggle power for that post; v1: boolean
	enabled = Column(Boolean, nullable=False, default=False)
	timestamp = Column(DateTime, default=datetime.utcnow, nullable=False)

	__table_args__ = (UniqueConstraint("post_id", "user_id", name="uq_power_post_user"),)

	# optional relation
	post = relationship("Post", lazy="joined")


class Reaction(Base):
	__tablename__ = "reactions"
	id = Column(Integer, primary_key=True)
	post_id = Column(Integer, ForeignKey("posts.id", ondelete="CASCADE"), index=True, nullable=False)
	user_id = Column(String, nullable=False)
	learned = Column(Boolean, nullable=False, default=False)
	surprised = Column(Boolean, nullable=False, default=False)
	timestamp = Column(DateTime, default=datetime.utcnow, nullable=False)

	__table_args__ = (UniqueConstraint("post_id", "user_id", name="uq_reaction_post_user"),)


class Vote(Base):
	__tablename__ = "votes"

	id = Column(Integer, primary_key=True)
	post_id = Column(Integer, ForeignKey("posts.id", ondelete="CASCADE"), index=True, nullable=False)
	user_id = Column(String, nullable=False)      # device/user identifier from header
	value = Column(Integer, nullable=False, default=0)  # -1, 0, or 1
	timestamp = Column(DateTime, default=datetime.utcnow, nullable=False)

	__table_args__ = (
		UniqueConstraint("post_id", "user_id", name="uq_vote_post_user"),
	)

	# Optional relation if you ever need joined access
	post = relationship("Post", lazy="joined")

