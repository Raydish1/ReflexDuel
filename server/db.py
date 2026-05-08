"""Async SQLAlchemy session setup."""
from __future__ import annotations

import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from sqlalchemy.ext.asyncio import (
    AsyncSession, async_sessionmaker, create_async_engine
)
from sqlalchemy.pool import NullPool

load_dotenv(Path(__file__).parent / ".env")

_env = os.getenv("ENV", "production")
_url = os.getenv("DATABASE_URL")

if not _url:
    if _env == "development":
        _url = "postgresql+asyncpg://postgres:postgres@localhost:5432/reflexduel"
        print("[db] DATABASE_URL not set — using localhost dev fallback")
    else:
        print("ERROR: DATABASE_URL environment variable is not set. "
              "Set it via flyctl secrets set or a .env file.", file=sys.stderr)
        sys.exit(1)

engine = create_async_engine(
    _url,
    echo=False,
    poolclass=NullPool,
    connect_args={"statement_cache_size": 0},  # required for PgBouncer (Supabase pooler) compat
)
AsyncSessionLocal = async_sessionmaker(engine, expire_on_commit=False)


async def get_session() -> AsyncSession:
    async with AsyncSessionLocal() as session:
        yield session
