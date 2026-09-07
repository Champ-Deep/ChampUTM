"""Daily MaxMind web-service usage and remaining credit."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import Column, Date, DateTime, Integer

from app.db.postgres import Base


class MaxMindUsage(Base):
    """One row per UTC day.

    ``lookups``/``errors`` are counted by us; ``queries_remaining`` is MaxMind's
    own figure, carried on every web-service response, so it stays authoritative
    even if our counters miss calls (process restart, direct API use elsewhere).
    """

    __tablename__ = "maxmind_usage"

    day = Column(Date, primary_key=True)
    lookups = Column(Integer, nullable=False, default=0, server_default="0")
    errors = Column(Integer, nullable=False, default=0, server_default="0")
    queries_remaining = Column(Integer, nullable=True)
    updated_at = Column(DateTime, nullable=False, default=datetime.utcnow)
