"""
Recomputes latency-compensated RTs for all 1v1 matches using EMA smoothing.

The original code set one_way_latency = rtt/2 each round, so a single RTT spike
would massively over-compensate. This script replaces those values with the EMA
(alpha=0.3) that the server now uses going forward.

Run from the server/ directory with DATABASE_URL in env (or .env file):
    python fix_ema_latency.py [--dry-run] [--username RRRE]

Without --username it fixes all players who have at least one corrupted round
(defined as compensated_ms < 10ms despite a raw_ms > 100ms).
"""
import asyncio, os, sys, argparse
from pathlib import Path
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker
from dotenv import load_dotenv

load_dotenv(Path(__file__).parent / ".env")

EMA_ALPHA = 0.3
MIN_COMP_MS = 1.0  # floor — compensated RT can't be below 1 ms


async def fix_player(s, player_id: str, side: str, match_id: str, dry_run: bool) -> dict:
    """Recompute EMA-corrected compensated RTs for one player in one match."""
    rtt_col  = f"p{side}_rtt_ms_round"
    raw_col  = f"p{side}_server_rt_raw_ms"
    comp_col = f"p{side}_server_rt_compensated_ms"
    pre_col  = f"p{side}_pre_click"

    r = await s.execute(text(f"""
        SELECT id, round_num, {rtt_col}, {raw_col}, {comp_col}, {pre_col}
        FROM rounds
        WHERE match_id = :mid
        ORDER BY round_num ASC
    """), {"mid": match_id})
    rounds = r.fetchall()
    if not rounds:
        return {"updated": 0}

    ema_latency = 0.0
    updates = []
    valid_comps = []

    for row in rounds:
        rtt = getattr(row, rtt_col)
        raw = getattr(row, raw_col)
        old_comp = getattr(row, comp_col)
        pre = getattr(row, pre_col)

        if rtt is not None:
            measured = rtt / 2.0
            if ema_latency == 0.0:
                ema_latency = measured
            else:
                ema_latency = EMA_ALPHA * measured + (1 - EMA_ALPHA) * ema_latency

        if raw is not None:
            new_comp = max(MIN_COMP_MS, raw - 2.0 * ema_latency)
        else:
            new_comp = None

        if new_comp != old_comp:
            updates.append((row.id, new_comp))

        if new_comp is not None and not pre:
            valid_comps.append(new_comp)

    new_avg = (sum(valid_comps) / len(valid_comps)) if valid_comps else None

    if not dry_run:
        for row_id, new_comp in updates:
            await s.execute(text(f"""
                UPDATE rounds SET {comp_col} = :comp WHERE id = :rid
            """), {"comp": new_comp, "rid": row_id})

        avg_col = f"p{side}_avg_rt_ms"
        await s.execute(text(f"""
            UPDATE matches SET {avg_col} = :avg WHERE id = :mid
        """), {"avg": new_avg, "mid": match_id})

    return {"updated": len(updates), "new_avg": new_avg, "rounds": len(rounds)}


async def run(username_filter: str | None, dry_run: bool) -> None:
    engine = create_async_engine(
        os.environ["DATABASE_URL"], echo=False,
        connect_args={"statement_cache_size": 0}
    )
    Session = async_sessionmaker(engine, expire_on_commit=False)

    async with Session() as s:
        if username_filter:
            r = await s.execute(text(
                "SELECT id, username FROM players WHERE LOWER(username) = LOWER(:u)"
            ), {"u": username_filter})
            players = r.fetchall()
        else:
            # Find any player who has a round where compensated < 10 but raw > 100
            r = await s.execute(text("""
                SELECT DISTINCT p.id, p.username
                FROM players p
                JOIN matches m ON (m.p1_id = p.id OR m.p2_id = p.id)
                JOIN rounds r ON r.match_id = m.id
                WHERE (
                    (m.p1_id = p.id AND r.p1_server_rt_raw_ms > 100
                        AND r.p1_server_rt_compensated_ms < 10
                        AND r.p1_rtt_ms_round > 50)
                    OR
                    (m.p2_id = p.id AND r.p2_server_rt_raw_ms > 100
                        AND r.p2_server_rt_compensated_ms < 10
                        AND r.p2_rtt_ms_round > 50)
                )
            """))
            players = r.fetchall()

        print(f"Players to fix: {len(players)}")
        total_round_updates = 0

        for player in players:
            pid = player.id
            uname = player.username

            # Find all 1v1 matches for this player (ranked + private)
            r2 = await s.execute(text("""
                SELECT id, p1_id, p2_id, p1_avg_rt_ms, p2_avg_rt_ms
                FROM matches
                WHERE (p1_id = :pid OR p2_id = :pid) AND mode != 'practice'
                ORDER BY started_at ASC
            """), {"pid": pid})
            matches = r2.fetchall()

            print(f"\n{uname} ({pid[:8]}): {len(matches)} matches")

            for m in matches:
                side = "1" if m.p1_id == pid else "2"
                result = await fix_player(s, pid, side, m.id, dry_run)
                if result["updated"] > 0:
                    old_avg = m.p1_avg_rt_ms if side == "1" else m.p2_avg_rt_ms
                    print(f"  match {m.id[:8]}: {result['updated']}/{result['rounds']} rounds updated"
                          f"  old_avg={old_avg:.1f}  new_avg={result['new_avg']:.1f}" if result["new_avg"] else
                          f"  match {m.id[:8]}: {result['updated']}/{result['rounds']} rounds updated  no valid rounds")
                    total_round_updates += result["updated"]

        if not dry_run:
            await s.commit()
            print(f"\nCommitted. Total round rows updated: {total_round_updates}")
        else:
            print(f"\nDRY RUN — {total_round_updates} round rows would be updated (no changes written)")

    await engine.dispose()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--username", default=None)
    args = parser.parse_args()
    asyncio.run(run(args.username, args.dry_run))
