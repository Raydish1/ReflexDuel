"""
Backfill cheat_flag_count on the players table by scanning historical round data.

Counts rounds where p1_click_duration_ms < 10 or p2_click_duration_ms < 10
(same threshold as the live cheat detection: CHEAT_DURATION_MS = 10.0).

Usage:
    DATABASE_URL=<supabase_postgres_url> python backfill_cheaters.py [--dry-run]

The Supabase "Direct connection" URL looks like:
    postgresql+asyncpg://postgres:<password>@db.<project-ref>.supabase.co:5432/postgres
"""
import asyncio
import os
import sys

from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker

CHEAT_DURATION_MS = 10.0


async def backfill(dry_run: bool) -> None:
    url = os.environ.get("DATABASE_URL")
    if not url:
        sys.exit("ERROR: DATABASE_URL env var not set")

    engine = create_async_engine(url, echo=False, connect_args={"statement_cache_size": 0})
    Session = async_sessionmaker(engine, expire_on_commit=False)

    async with Session() as session:
        result = await session.execute(text("""
            WITH cheat_counts AS (
                SELECT m.p1_id AS player_id, COUNT(*) AS flags
                FROM rounds r
                JOIN matches m ON r.match_id = m.id
                WHERE r.p1_click_duration_ms IS NOT NULL
                  AND r.p1_click_duration_ms < :threshold
                GROUP BY m.p1_id
                UNION ALL
                SELECT m.p2_id AS player_id, COUNT(*) AS flags
                FROM rounds r
                JOIN matches m ON r.match_id = m.id
                WHERE r.p2_click_duration_ms IS NOT NULL
                  AND r.p2_click_duration_ms < :threshold
                GROUP BY m.p2_id
            ),
            totals AS (
                SELECT player_id, SUM(flags) AS total_flags
                FROM cheat_counts
                GROUP BY player_id
            )
            SELECT p.id, p.username, p.cheat_flag_count AS current_flags, t.total_flags AS computed_flags
            FROM players p
            JOIN totals t ON t.player_id = p.id
            ORDER BY t.total_flags DESC
        """), {"threshold": CHEAT_DURATION_MS})

        rows = result.fetchall()

        if not rows:
            print("No players with sub-10ms click durations found.")
            await engine.dispose()
            return

        print(f"{'Username':<20} {'Current':>8} {'Computed':>9} {'Delta':>6}")
        print("-" * 48)
        for row in rows:
            delta = row.computed_flags - row.current_flags
            print(f"{row.username:<20} {row.current_flags:>8} {row.computed_flags:>9} {delta:>+6}")

        if dry_run:
            print("\n[dry-run] No changes written.")
            await engine.dispose()
            return

        updated = 0
        for row in rows:
            if row.computed_flags != row.current_flags:
                await session.execute(
                    text("UPDATE players SET cheat_flag_count = :n WHERE id = :id"),
                    {"n": int(row.computed_flags), "id": row.id},
                )
                updated += 1

        await session.commit()
        print(f"\nUpdated {updated} player(s).")

    await engine.dispose()


if __name__ == "__main__":
    dry = "--dry-run" in sys.argv
    asyncio.run(backfill(dry))
