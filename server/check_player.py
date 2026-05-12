import asyncio, os, sys
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker

PLAYER_ID = sys.argv[1] if len(sys.argv) > 1 else "b549d72c-64c"

async def check():
    engine = create_async_engine(os.environ["DATABASE_URL"], echo=False, connect_args={"statement_cache_size": 0})
    Session = async_sessionmaker(engine, expire_on_commit=False)
    async with Session() as s:
        r = await s.execute(text(
            "SELECT id, username, cheat_flag_count FROM players WHERE id = :pid"
        ), {"pid": PLAYER_ID})
        row = r.fetchone()
        print(f"Player: {row}")

        r2 = await s.execute(text("""
            SELECT r.id, r.match_id, r.round_num,
                   r.p1_click_duration_ms, r.p2_click_duration_ms,
                   m.p1_id, m.p2_id
            FROM rounds r JOIN matches m ON r.match_id = m.id
            WHERE (m.p1_id = :pid AND r.p1_click_duration_ms IS NOT NULL AND r.p1_click_duration_ms < 10)
               OR (m.p2_id = :pid AND r.p2_click_duration_ms IS NOT NULL AND r.p2_click_duration_ms < 10)
        """), {"pid": PLAYER_ID})
        rows = r2.fetchall()
        print(f"Rounds with click_duration < 10ms: {len(rows)}")
        for row in rows:
            print(f"  {row}")
    await engine.dispose()

asyncio.run(check())
