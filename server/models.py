"""
SQLAlchemy models for ReflexDuel.
Players, matches, rounds — designed so every round becomes one row of training data.
"""
from __future__ import annotations

from datetime import datetime
from sqlalchemy import (
    BigInteger, Boolean, Float, ForeignKey, Integer, String, DateTime, func
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    pass


class Player(Base):
    """
    Anonymous player record. Username is just for display; we identify by id.
    Phase 3+ will add Steam ID, email/auth, etc.
    """
    __tablename__ = "players"

    id: Mapped[str] = mapped_column(String(16), primary_key=True)
    username: Mapped[str] = mapped_column(String(32), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    # Aggregate stats (denormalized for fast leaderboard reads)
    matches_played: Mapped[int] = mapped_column(Integer, default=0)
    matches_won: Mapped[int] = mapped_column(Integer, default=0)
    cheat_flag_count: Mapped[int] = mapped_column(Integer, default=0)

    matches_as_p1: Mapped[list["Match"]] = relationship(
        "Match", foreign_keys="Match.p1_id", back_populates="p1"
    )
    matches_as_p2: Mapped[list["Match"]] = relationship(
        "Match", foreign_keys="Match.p2_id", back_populates="p2"
    )


class Match(Base):
    """One full match between two players (best of N rounds)."""
    __tablename__ = "matches"

    id: Mapped[str] = mapped_column(String(16), primary_key=True)
    p1_id: Mapped[str] = mapped_column(ForeignKey("players.id"), nullable=False)
    p2_id: Mapped[str] = mapped_column(ForeignKey("players.id"), nullable=False)
    winner_id: Mapped[str | None] = mapped_column(
        ForeignKey("players.id"), nullable=True
    )

    mode: Mapped[str] = mapped_column(String(16), default="ranked")  # ranked / private
    room_code: Mapped[str | None] = mapped_column(String(8), nullable=True)

    started_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    ended_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    p1_final_score: Mapped[int] = mapped_column(Integer, default=0)
    p2_final_score: Mapped[int] = mapped_column(Integer, default=0)

    # Latency measured at match start (one-time RTT probe)
    p1_rtt_ms: Mapped[float | None] = mapped_column(Float, nullable=True)
    p2_rtt_ms: Mapped[float | None] = mapped_column(Float, nullable=True)

    p1: Mapped["Player"] = relationship(
        "Player", foreign_keys=[p1_id], back_populates="matches_as_p1"
    )
    p2: Mapped["Player"] = relationship(
        "Player", foreign_keys=[p2_id], back_populates="matches_as_p2"
    )
    rounds: Mapped[list["Round"]] = relationship(
        "Round", back_populates="match", cascade="all, delete-orphan"
    )


class Round(Base):
    """
    One round of one match. THIS is the unit of ML training data —
    every column here is either a feature or a label for the anti-cheat model.
    """
    __tablename__ = "rounds"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    match_id: Mapped[str] = mapped_column(
        ForeignKey("matches.id", ondelete="CASCADE"), nullable=False
    )
    round_num: Mapped[int] = mapped_column(Integer, nullable=False)

    # Server-authoritative timing (microseconds)
    t_stimulus_us: Mapped[int] = mapped_column(BigInteger, nullable=False)
    delay_s: Mapped[float] = mapped_column(Float, nullable=False)

    # Per-player measurements (server-side)
    p1_click_us: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    p2_click_us: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    p1_server_rt_ms: Mapped[float | None] = mapped_column(Float, nullable=True)
    p2_server_rt_ms: Mapped[float | None] = mapped_column(Float, nullable=True)

    # Client-reported (for cross-check, never trusted)
    p1_client_rt_ms: Mapped[float | None] = mapped_column(Float, nullable=True)
    p2_client_rt_ms: Mapped[float | None] = mapped_column(Float, nullable=True)

    # Round outcome
    winner_id: Mapped[str | None] = mapped_column(
        ForeignKey("players.id"), nullable=True
    )
    p1_pre_click: Mapped[bool] = mapped_column(Boolean, default=False)
    p2_pre_click: Mapped[bool] = mapped_column(Boolean, default=False)

    match: Mapped["Match"] = relationship("Match", back_populates="rounds")