"""
Backfill p1_avg_rt_ms and p2_avg_rt_ms on existing matches rows.
Pre-clicks and null RTs are excluded, matching the live persist_match() logic.

Usage:
    DATABASE_URL=<supabase_postgres_url> python backfill_match_avg_rt.py [--dry-run]
"""
import asyncio
import os
import sys

from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker


async def backfill(dry_run: bool) -> None:
    url = os.environ.get("DATABASE_URL")
    if not url:
        sys.exit("ERROR: DATABASE_URL env var not set")

    engine = create_async_engine(url, echo=False, connect_args={"statement_cache_size": 0})
    Session = async_sessionmaker(engine, expire_on_commit=False)

    async with Session() as session:
        result = await session.execute(text("""
            WITH p1_avgs AS (
                SELECT m.id AS match_id,
                       ROUND(AVG(CASE WHEN r.p1_pre_click THEN 350.0
                                      ELSE r.p1_server_rt_compensated_ms END)::numeric, 1) AS avg_rt
                FROM matches m
                JOIN rounds r ON r.match_id = m.id
                WHERE r.p1_pre_click OR r.p1_server_rt_compensated_ms IS NOT NULL
                GROUP BY m.id
            ),
            p2_avgs AS (
                SELECT m.id AS match_id,
                       ROUND(AVG(CASE WHEN r.p2_pre_click THEN 350.0
                                      ELSE r.p2_server_rt_compensated_ms END)::numeric, 1) AS avg_rt
                FROM matches m
                JOIN rounds r ON r.match_id = m.id
                WHERE r.p2_pre_click OR r.p2_server_rt_compensated_ms IS NOT NULL
                GROUP BY m.id
            )
            SELECT m.id,
                   p1.avg_rt AS p1_avg_rt,
                   p2.avg_rt AS p2_avg_rt
            FROM matches m
            LEFT JOIN p1_avgs p1 ON p1.match_id = m.id
            LEFT JOIN p2_avgs p2 ON p2.match_id = m.id
            ORDER BY m.started_at DESC
        """))
        rows = result.fetchall()

        if not rows:
            print("No matches found.")
            await engine.dispose()
            return

        print(f"Found {len(rows)} matches to backfill.")
        if dry_run:
            for r in rows[:10]:
                print(f"  {r.id}: p1={r.p1_avg_rt} ms  p2={r.p2_avg_rt} ms")
            if len(rows) > 10:
                print(f"  ... and {len(rows) - 10} more")
            print("\n[dry-run] No changes written.")
            await engine.dispose()
            return

        await session.execute(text("""
            WITH p1_avgs AS (
                SELECT m.id AS match_id,
                       ROUND(AVG(r.p1_server_rt_compensated_ms)::numeric, 1) AS avg_rt
                FROM matches m
                JOIN rounds r ON r.match_id = m.id
                WHERE r.p1_server_rt_compensated_ms IS NOT NULL
                  AND NOT r.p1_pre_click
                GROUP BY m.id
            ),
            p2_avgs AS (
                SELECT m.id AS match_id,
                       ROUND(AVG(r.p2_server_rt_compensated_ms)::numeric, 1) AS avg_rt
                FROM matches m
                JOIN rounds r ON r.match_id = m.id
                WHERE r.p2_server_rt_compensated_ms IS NOT NULL
                  AND NOT r.p2_pre_click
                GROUP BY m.id
            )
            UPDATE matches m
            SET p1_avg_rt_ms = p1.avg_rt,
                p2_avg_rt_ms = p2.avg_rt
            FROM p1_avgs p1
            FULL OUTER JOIN p2_avgs p2 ON p1.match_id = p2.match_id
            WHERE m.id = COALESCE(p1.match_id, p2.match_id)
        """))
        await session.commit()
        print(f"Backfilled {len(rows)} matches.")

    await engine.dispose()


if __name__ == "__main__":
    dry = "--dry-run" in sys.argv
    asyncio.run(backfill(dry))
