"""
Delete all data for a given username from the database.

Usage:
    DATABASE_URL=<supabase_postgres_url> python purge_player.py <username>

The Supabase "Direct connection" URL looks like:
    postgresql+asyncpg://postgres:<password>@db.<project-ref>.supabase.co:5432/postgres

Find it in: Supabase dashboard → Project Settings → Database → Connection string (asyncpg).
"""
import asyncio
import os
import sys

from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker


async def purge(username: str) -> None:
    url = os.environ.get("DATABASE_URL")
    if not url:
        sys.exit("ERROR: DATABASE_URL env var not set")

    engine = create_async_engine(url, echo=False, connect_args={"statement_cache_size": 0})
    Session = async_sessionmaker(engine, expire_on_commit=False)

    async with Session() as session:
        r_cal = await session.execute(
            text("DELETE FROM calibration_rounds WHERE username = :n"), {"n": username}
        )
        # Deleting a match cascades to its rounds (FK ondelete=CASCADE)
        r_matches = await session.execute(
            text("DELETE FROM matches WHERE p1_username = :n OR p2_username = :n"),
            {"n": username},
        )
        # Also delete any orphaned rounds (denormalised username column)
        r_rounds = await session.execute(
            text("DELETE FROM rounds WHERE p1_username = :n OR p2_username = :n"),
            {"n": username},
        )
        r_players = await session.execute(
            text("DELETE FROM players WHERE username = :n"), {"n": username}
        )
        await session.commit()

    await engine.dispose()

    print(
        f"Purged '{username}':\n"
        f"  players:           {r_players.rowcount}\n"
        f"  matches:           {r_matches.rowcount}  (rounds cascade automatically)\n"
        f"  rounds (orphaned): {r_rounds.rowcount}\n"
        f"  calibration_rounds:{r_cal.rowcount}"
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: python purge_player.py <username>")
    asyncio.run(purge(sys.argv[1]))
