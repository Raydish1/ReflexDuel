import asyncio, os
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker

async def run():
    engine = create_async_engine(os.environ["DATABASE_URL"], echo=False, connect_args={"statement_cache_size": 0})
    Session = async_sessionmaker(engine, expire_on_commit=False)
    async with Session() as s:
        r = await s.execute(text("SELECT id, username FROM players WHERE username = 'RRRE'"))
        player = r.fetchone()
        if not player:
            print("RRRE not found"); return
        print("Player id:", player.id)

        r2 = await s.execute(text("""
            SELECT m.id, m.p1_id, m.p2_id, m.p1_avg_rt_ms, m.p2_avg_rt_ms, m.mode
            FROM matches m
            WHERE (m.p1_id = :pid OR m.p2_id = :pid) AND m.mode != 'practice'
            ORDER BY m.started_at DESC LIMIT 20
        """), {"pid": player.id})
        rows = r2.fetchall()
        print(f"\nMatches ({len(rows)}):")
        for row in rows:
            side = "p1" if row.p1_id == player.id else "p2"
            avg = row.p1_avg_rt_ms if side == "p1" else row.p2_avg_rt_ms
            print(f"  match {row.id[:8]} side={side} avg_rt={avg}")

        r3 = await s.execute(text("""
            SELECT r.match_id, r.round_num,
                   r.p1_server_rt_compensated_ms, r.p2_server_rt_compensated_ms,
                   r.p1_pre_click, r.p2_pre_click,
                   r.p1_rtt_ms_round, r.p2_rtt_ms_round,
                   m.p1_id, m.p2_id
            FROM rounds r JOIN matches m ON r.match_id = m.id
            WHERE (m.p1_id = :pid OR m.p2_id = :pid) AND m.mode != 'practice'
            ORDER BY m.started_at DESC, r.round_num ASC LIMIT 80
        """), {"pid": player.id})
        rows3 = r3.fetchall()
        print(f"\nRounds ({len(rows3)}):")
        current_match = None
        for row in rows3:
            if row.match_id != current_match:
                current_match = row.match_id
                print(f"  --- match {row.match_id[:8]} ---")
            side = "p1" if row.p1_id == player.id else "p2"
            comp = row.p1_server_rt_compensated_ms if side == "p1" else row.p2_server_rt_compensated_ms
            pre = row.p1_pre_click if side == "p1" else row.p2_pre_click
            rtt = row.p1_rtt_ms_round if side == "p1" else row.p2_rtt_ms_round
            print(f"    r{row.round_num} comp={comp} pre={pre} rtt={rtt}")

    await engine.dispose()

asyncio.run(run())
