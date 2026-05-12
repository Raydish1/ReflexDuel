"""Debug: run the best_match_rt leaderboard query without the cheat filter to compare."""
import asyncio, os
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker

async def run():
    engine = create_async_engine(os.environ["DATABASE_URL"], echo=False, connect_args={"statement_cache_size": 0})
    Session = async_sessionmaker(engine, expire_on_commit=False)
    async with Session() as s:
        print("=== best_match_rt WITH cheat filter ===")
        r = await s.execute(text("""
            WITH match_avgs AS (
                SELECT m.p2_id AS player_id,
                       AVG(CASE WHEN r.p2_pre_click THEN 350.0
                                ELSE r.p2_server_rt_compensated_ms END) AS avg_rt,
                       m.id AS match_id
                FROM rounds r JOIN matches m ON r.match_id = m.id
                WHERE (r.p2_pre_click OR r.p2_server_rt_compensated_ms IS NOT NULL)
                  AND m.mode != 'practice'
                GROUP BY m.id, m.p2_id
                UNION ALL
                SELECT m.p1_id AS player_id,
                       AVG(CASE WHEN r.p1_pre_click THEN 350.0
                                ELSE r.p1_server_rt_compensated_ms END) AS avg_rt,
                       m.id AS match_id
                FROM rounds r JOIN matches m ON r.match_id = m.id
                WHERE (r.p1_pre_click OR r.p1_server_rt_compensated_ms IS NOT NULL)
                  AND m.mode != 'practice'
                GROUP BY m.id, m.p1_id
            )
            SELECT p.username, ROUND(MIN(ma.avg_rt)::numeric, 1) AS value, p.cheat_flag_count
            FROM match_avgs ma JOIN players p ON ma.player_id = p.id
            WHERE p.cheat_flag_count = 0
            GROUP BY p.id, p.username, p.cheat_flag_count
            ORDER BY value ASC
            LIMIT 10
        """))
        for row in r.fetchall():
            print(f"  {row.username:<20} {row.value} ms  (flags={row.cheat_flag_count})")

        print()
        print("=== best_match_rt WITHOUT cheat filter (all players) ===")
        r2 = await s.execute(text("""
            WITH match_avgs AS (
                SELECT m.p2_id AS player_id,
                       AVG(CASE WHEN r.p2_pre_click THEN 350.0
                                ELSE r.p2_server_rt_compensated_ms END) AS avg_rt,
                       m.id AS match_id
                FROM rounds r JOIN matches m ON r.match_id = m.id
                WHERE (r.p2_pre_click OR r.p2_server_rt_compensated_ms IS NOT NULL)
                  AND m.mode != 'practice'
                GROUP BY m.id, m.p2_id
                UNION ALL
                SELECT m.p1_id AS player_id,
                       AVG(CASE WHEN r.p1_pre_click THEN 350.0
                                ELSE r.p1_server_rt_compensated_ms END) AS avg_rt,
                       m.id AS match_id
                FROM rounds r JOIN matches m ON r.match_id = m.id
                WHERE (r.p1_pre_click OR r.p1_server_rt_compensated_ms IS NOT NULL)
                  AND m.mode != 'practice'
                GROUP BY m.id, m.p1_id
            )
            SELECT p.username, ROUND(MIN(ma.avg_rt)::numeric, 1) AS value, p.cheat_flag_count
            FROM match_avgs ma JOIN players p ON ma.player_id = p.id
            GROUP BY p.id, p.username, p.cheat_flag_count
            ORDER BY value ASC
            LIMIT 15
        """))
        for row in r2.fetchall():
            marker = " <-- FILTERED (cheat flags)" if row.cheat_flag_count > 0 else ""
            print(f"  {row.username:<20} {row.value} ms  (flags={row.cheat_flag_count}){marker}")

    await engine.dispose()

asyncio.run(run())
