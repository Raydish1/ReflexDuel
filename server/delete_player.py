"""
Delete a player and all their data from the production DB.
Usage:
    DATABASE_URL=postgresql+psycopg2://... python delete_player.py gentlebrawlers
    # Add --confirm to actually delete (dry-run by default)
    DATABASE_URL=postgresql+psycopg2://... python delete_player.py gentlebrawlers --confirm
"""
import sys
import os
from sqlalchemy import create_engine, text

DATABASE_URL = os.environ.get("DATABASE_URL")
if not DATABASE_URL:
    print("ERROR: set DATABASE_URL env var")
    sys.exit(1)

if len(sys.argv) < 2:
    print("Usage: python delete_player.py <username> [--confirm]")
    sys.exit(1)

username = sys.argv[1]
confirm  = "--confirm" in sys.argv

engine = create_engine(DATABASE_URL)

with engine.begin() as conn:
    # Find the player (case-insensitive)
    row = conn.execute(
        text("SELECT id, username, matches_played, matches_won FROM players WHERE LOWER(username) = LOWER(:u)"),
        {"u": username},
    ).fetchone()

    if row is None:
        print(f"No player found with username '{username}' (case-insensitive).")
        sys.exit(0)

    pid, uname, mp, mw = row
    print(f"\nFound player: '{uname}'  id={pid}  matches_played={mp}  matches_won={mw}")

    # Count data that will be deleted
    match_count = conn.execute(
        text("SELECT COUNT(*) FROM matches WHERE p1_id = :pid OR p2_id = :pid"),
        {"pid": pid},
    ).scalar()

    round_count = conn.execute(
        text("""
            SELECT COUNT(*) FROM rounds r
            JOIN matches m ON r.match_id = m.id
            WHERE m.p1_id = :pid OR m.p2_id = :pid
        """),
        {"pid": pid},
    ).scalar()

    team_match_count = conn.execute(
        text("""
            SELECT COUNT(*) FROM team_matches
            WHERE t1_p1_id = :pid OR t1_p2_id = :pid OR t2_p1_id = :pid OR t2_p2_id = :pid
        """),
        {"pid": pid},
    ).scalar()

    team_round_count = conn.execute(
        text("""
            SELECT COUNT(*) FROM team_rounds tr
            JOIN team_matches tm ON tr.match_id = tm.id
            WHERE tm.t1_p1_id = :pid OR tm.t1_p2_id = :pid
               OR tm.t2_p1_id = :pid OR tm.t2_p2_id = :pid
        """),
        {"pid": pid},
    ).scalar()

    cal_count = conn.execute(
        text("SELECT COUNT(*) FROM calibration_rounds WHERE player_id = :pid"),
        {"pid": pid},
    ).scalar()

    print(f"\nData that will be deleted:")
    print(f"  {match_count} 1v1 match(es) + {round_count} round(s)")
    print(f"  {team_match_count} 2v2 match(es) + {team_round_count} team round(s)")
    print(f"  {cal_count} calibration round(s)")
    print(f"  1 player row")

    if not confirm:
        print("\nDRY RUN — no changes made. Re-run with --confirm to delete.")
        sys.exit(0)

    print("\nDeleting...")

    # 1. Calibration rounds
    n = conn.execute(
        text("DELETE FROM calibration_rounds WHERE player_id = :pid"),
        {"pid": pid},
    ).rowcount
    print(f"  Deleted {n} calibration round(s)")

    # 2. 1v1 matches (rounds cascade automatically via ON DELETE CASCADE)
    n = conn.execute(
        text("DELETE FROM matches WHERE p1_id = :pid OR p2_id = :pid"),
        {"pid": pid},
    ).rowcount
    print(f"  Deleted {n} 1v1 match(es) (rounds cascade)")

    # 3. 2v2 team matches (team_rounds cascade)
    n = conn.execute(
        text("""
            DELETE FROM team_matches
            WHERE t1_p1_id = :pid OR t1_p2_id = :pid
               OR t2_p1_id = :pid OR t2_p2_id = :pid
        """),
        {"pid": pid},
    ).rowcount
    print(f"  Deleted {n} 2v2 match(es) (team_rounds cascade)")

    # 4. Player row
    conn.execute(text("DELETE FROM players WHERE id = :pid"), {"pid": pid})
    print(f"  Deleted player row '{uname}' (id={pid})")

    print("\nDone. All data for this player has been removed.")
