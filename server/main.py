"""
ReflexDuel - Phase 2.5 server.
Quickplay queue + private rooms with codes + PostgreSQL persistence.
Modes: ranked (latency-compensated server RT), practice (client-reported RT).
"""
from __future__ import annotations

import asyncio
import random
import secrets
import string
import time
import uuid
from dataclasses import dataclass, field
from typing import Optional

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware

from sqlalchemy import text, update

from db import AsyncSessionLocal
from models import Match as MatchRow, Player as PlayerRow, Round as RoundRow, CalibrationRound as CalibrationRoundRow

app = FastAPI(title="ReflexDuel")
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"]
)


@app.get("/health")
async def health():
    return {"status": "ok"}

ROUNDS_TO_WIN = 3
MAX_INACTIVE_ROUNDS = 3
MIN_DELAY_S = 2.0
MAX_DELAY_S = 6.0
HUMAN_FLOOR_MS = 100
ROOM_CODE_CHARS = string.ascii_uppercase + string.digits
ROOM_CODE_LEN = 6
CLIENT_VERSION = "0.2.0"
# Pong must arrive before any valid click (HUMAN_FLOOR_MS guarantees this).
# 0.5s fallback timeout covers extreme packet loss.
ROUND_PING_TIMEOUT_S = 0.5


@dataclass
class Player:
    player_id: str
    username: str
    websocket: WebSocket
    wins: int = 0
    click_received_us: Optional[int] = None
    client_reported_rt_ms: Optional[float] = None
    pre_clicked: bool = False
    ready: bool = False
    one_way_latency_ms: float = 0.0
    pong_queue: asyncio.Queue = field(default_factory=asyncio.Queue)
    # Client hardware (set once via client_info message)
    platform: Optional[str] = None
    screen_refresh_hz: Optional[float] = None
    screen_resolution: Optional[str] = None
    client_version: Optional[str] = None
    # Per-round behavioral features (reset each round, set via click/click_info messages)
    click_duration_ms: Optional[float] = None
    mouse_distance_5s_px: Optional[float] = None
    time_since_mouse_move_ms: Optional[float] = None
    window_focused: Optional[bool] = None


@dataclass
class Match:
    match_id: str
    p1: Player
    p2: Player
    mode: str
    room_code: Optional[str] = None
    round_num: int = 0
    round_log: list[dict] = field(default_factory=list)
    inactive_rounds: int = 0


@dataclass
class RematchSession:
    session_id: str
    p1: Player
    p2: Player
    mode: str
    room_code: Optional[str] = None
    votes: set = field(default_factory=set)


class Lobby:
    def __init__(self) -> None:
        self.quickplay_queue: list[Player] = []
        self.practice_queue: list[Player] = []
        self.private_rooms: dict[str, Player] = {}
        self.lock = asyncio.Lock()

    async def quickplay_join(self, player: Player) -> Optional[Match]:
        async with self.lock:
            for queued in self.quickplay_queue:
                if queued.player_id == player.player_id:
                    return None
            if self.quickplay_queue:
                opponent = self.quickplay_queue.pop(0)
                return Match(match_id=str(uuid.uuid4())[:12], p1=opponent, p2=player, mode="ranked")
            self.quickplay_queue.append(player)
            return None

    async def quickplay_leave(self, player: Player) -> None:
        async with self.lock:
            if player in self.quickplay_queue:
                self.quickplay_queue.remove(player)

    async def practice_join(self, player: Player) -> Optional[Match]:
        async with self.lock:
            for queued in self.practice_queue:
                if queued.player_id == player.player_id:
                    return None
            if self.practice_queue:
                opponent = self.practice_queue.pop(0)
                return Match(match_id=str(uuid.uuid4())[:12], p1=opponent, p2=player, mode="practice")
            self.practice_queue.append(player)
            return None

    async def practice_leave(self, player: Player) -> None:
        async with self.lock:
            if player in self.practice_queue:
                self.practice_queue.remove(player)

    async def create_room(self, player: Player) -> str:
        async with self.lock:
            for _ in range(10):
                code = "".join(secrets.choice(ROOM_CODE_CHARS) for _ in range(ROOM_CODE_LEN))
                if code not in self.private_rooms:
                    self.private_rooms[code] = player
                    return code
            raise RuntimeError("Could not generate unique room code")

    async def join_room(self, code: str, player: Player) -> Optional[Match]:
        async with self.lock:
            host = self.private_rooms.get(code)
            if host is None or host.player_id == player.player_id:
                return None
            del self.private_rooms[code]
            return Match(match_id=str(uuid.uuid4())[:12], p1=host, p2=player, mode="private", room_code=code)

    async def cancel_room(self, player: Player) -> None:
        async with self.lock:
            for code, p in list(self.private_rooms.items()):
                if p.player_id == player.player_id:
                    del self.private_rooms[code]


lobby = Lobby()
active_matches: dict[str, Match] = {}
player_to_match: dict[str, str] = {}
rematch_sessions: dict[str, RematchSession] = {}
player_to_rematch: dict[str, str] = {}


def now_us() -> int:
    return time.perf_counter_ns() // 1000


async def safe_send(ws: WebSocket, msg: dict) -> bool:
    try:
        await ws.send_json(msg)
        return True
    except Exception:
        return False


async def ensure_player_row(player_id: str, username: str) -> None:
    try:
        async with AsyncSessionLocal() as session:
            existing = await session.get(PlayerRow, player_id)
            if existing is None:
                print(f"[DB] Creating player row: {player_id} ({username})")
                session.add(PlayerRow(id=player_id, username=username))
                await session.commit()
    except Exception as e:
        print(f"[DB] ensure_player_row failed for {player_id}: {e}")



_VALID_STATS = {"avg_rt", "best_match_rt", "wins", "winrate"}

async def fetch_leaderboard(stat: str) -> list[dict]:
    queries = {
        "avg_rt": text("""
            WITH player_rts AS (
                SELECT m.p1_id AS player_id, r.p1_server_rt_compensated_ms AS rt_ms
                FROM rounds r JOIN matches m ON r.match_id = m.id
                WHERE r.p1_server_rt_compensated_ms IS NOT NULL AND NOT r.p1_pre_click
                  AND m.mode != 'practice'
                UNION ALL
                SELECT m.p2_id AS player_id, r.p2_server_rt_compensated_ms AS rt_ms
                FROM rounds r JOIN matches m ON r.match_id = m.id
                WHERE r.p2_server_rt_compensated_ms IS NOT NULL AND NOT r.p2_pre_click
                  AND m.mode != 'practice'
            )
            SELECT p.username, ROUND(AVG(pr.rt_ms)::numeric, 1) AS value
            FROM player_rts pr JOIN players p ON pr.player_id = p.id
            GROUP BY p.id, p.username
            HAVING COUNT(*) >= 3
            ORDER BY value ASC
            LIMIT 10
        """),
        "best_match_rt": text("""
            WITH match_avgs AS (
                SELECT m.p1_id AS player_id, AVG(r.p1_server_rt_compensated_ms) AS avg_rt
                FROM rounds r JOIN matches m ON r.match_id = m.id
                WHERE r.p1_server_rt_compensated_ms IS NOT NULL AND NOT r.p1_pre_click
                  AND m.mode != 'practice'
                GROUP BY m.id, m.p1_id
                UNION ALL
                SELECT m.p2_id AS player_id, AVG(r.p2_server_rt_compensated_ms) AS avg_rt
                FROM rounds r JOIN matches m ON r.match_id = m.id
                WHERE r.p2_server_rt_compensated_ms IS NOT NULL AND NOT r.p2_pre_click
                  AND m.mode != 'practice'
                GROUP BY m.id, m.p2_id
            )
            SELECT p.username, ROUND(MIN(ma.avg_rt)::numeric, 1) AS value
            FROM match_avgs ma JOIN players p ON ma.player_id = p.id
            GROUP BY p.id, p.username
            ORDER BY value ASC
            LIMIT 10
        """),
        "wins": text("""
            SELECT p.username, COUNT(*) AS value
            FROM matches m
            JOIN players p ON m.winner_id = p.id
            WHERE m.mode != 'practice'
            GROUP BY p.id, p.username
            ORDER BY value DESC
            LIMIT 10
        """),
        "winrate": text("""
            WITH player_matches AS (
                SELECT p1_id AS player_id, winner_id FROM matches WHERE mode != 'practice'
                UNION ALL
                SELECT p2_id AS player_id, winner_id FROM matches WHERE mode != 'practice'
            )
            SELECT p.username,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE pm.winner_id = pm.player_id) / COUNT(*), 1) AS value
            FROM player_matches pm
            JOIN players p ON pm.player_id = p.id
            GROUP BY p.id, p.username
            HAVING COUNT(*) >= 2
            ORDER BY value DESC
            LIMIT 10
        """),
    }
    async with AsyncSessionLocal() as session:
        result = await session.execute(queries[stat])
        return [{"username": r.username, "value": float(r.value)} for r in result.fetchall()]


async def save_calibration(player: Player, rt_ms: float, side: str) -> None:
    await ensure_player_row(player.player_id, player.username)
    async with AsyncSessionLocal() as session:
        session.add(CalibrationRoundRow(
            player_id=player.player_id,
            username=player.username,
            rt_ms=rt_ms,
            side=side,
        ))
        await session.commit()


async def persist_match(match: Match, winner: Optional[Player]) -> None:
    winner_name = winner.username if winner else "none"
    print(f"[DB] Persisting match {match.match_id}, winner={winner_name}, rounds={len(match.round_log)}")
    async with AsyncSessionLocal() as session:
        session.add(MatchRow(
            id=match.match_id,
            p1_id=match.p1.player_id, p2_id=match.p2.player_id,
            winner_id=winner.player_id if winner else None,
            mode=match.mode, room_code=match.room_code,
            p1_final_score=match.p1.wins, p2_final_score=match.p2.wins,
            p1_username=match.p1.username,
            p2_username=match.p2.username,
            p1_platform=match.p1.platform,
            p2_platform=match.p2.platform,
            p1_screen_refresh_hz=match.p1.screen_refresh_hz,
            p2_screen_refresh_hz=match.p2.screen_refresh_hz,
            p1_screen_resolution=match.p1.screen_resolution,
            p2_screen_resolution=match.p2.screen_resolution,
            p1_client_version=match.p1.client_version,
            p2_client_version=match.p2.client_version,
        ))
        for r in match.round_log:
            session.add(RoundRow(
                match_id=match.match_id,
                round_num=r["round_num"],
                p1_username=match.p1.username,
                p2_username=match.p2.username,
                t_stimulus_us=r["t_stimulus_us"],
                delay_s=r["delay_s"],
                p1_click_us=r["p1_click_us"],
                p2_click_us=r["p2_click_us"],
                p1_client_rt_ms=r["p1_client_rt_ms"],
                p2_client_rt_ms=r["p2_client_rt_ms"],
                p1_server_rt_raw_ms=r["p1_raw_rt_ms"],
                p1_server_rt_compensated_ms=r["p1_compensated_rt_ms"],
                p2_server_rt_raw_ms=r["p2_raw_rt_ms"],
                p2_server_rt_compensated_ms=r["p2_compensated_rt_ms"],
                winner_id=r["winner"],
                p1_pre_click=r["p1_pre_click"],
                p2_pre_click=r["p2_pre_click"],
                p1_rtt_ms_round=r["p1_rtt_ms_round"],
                p2_rtt_ms_round=r["p2_rtt_ms_round"],
                p1_click_duration_ms=r["p1_click_duration_ms"],
                p2_click_duration_ms=r["p2_click_duration_ms"],
                p1_mouse_distance_5s_px=r["p1_mouse_distance_5s_px"],
                p2_mouse_distance_5s_px=r["p2_mouse_distance_5s_px"],
                p1_time_since_mouse_move_ms=r["p1_time_since_mouse_move_ms"],
                p2_time_since_mouse_move_ms=r["p2_time_since_mouse_move_ms"],
                p1_window_focused=r["p1_window_focused"],
                p2_window_focused=r["p2_window_focused"],
            ))
        p1_won = 1 if winner and winner.player_id == match.p1.player_id else 0
        p2_won = 1 if winner and winner.player_id == match.p2.player_id else 0
        await session.execute(
            update(PlayerRow).where(PlayerRow.id == match.p1.player_id).values(
                matches_played=PlayerRow.matches_played + 1,
                matches_won=PlayerRow.matches_won + p1_won,
            )
        )
        await session.execute(
            update(PlayerRow).where(PlayerRow.id == match.p2.player_id).values(
                matches_played=PlayerRow.matches_played + 1,
                matches_won=PlayerRow.matches_won + p2_won,
            )
        )
        await session.commit()
        print(f"[DB] Wrote match {match.match_id} with {len(match.round_log)} rounds")


async def start_rematch(session: RematchSession) -> None:
    await asyncio.sleep(1.0)
    match = Match(
        match_id=str(uuid.uuid4())[:12],
        p1=session.p1,
        p2=session.p2,
        mode=session.mode,
        room_code=session.room_code,
    )
    asyncio.create_task(run_match(match))


async def run_match(match: Match) -> None:
    match.p1.wins = 0
    match.p2.wins = 0
    print(f"[MATCH] Starting {match.match_id}: {match.p1.username} vs {match.p2.username} ({match.mode})")
    active_matches[match.match_id] = match
    player_to_match[match.p1.player_id] = match.match_id
    player_to_match[match.p2.player_id] = match.match_id

    match.p1.one_way_latency_ms = 0.0
    match.p2.one_way_latency_ms = 0.0

    for p, opp in [(match.p1, match.p2), (match.p2, match.p1)]:
        await safe_send(p.websocket, {
            "type": "match_start",
            "match_id": match.match_id,
            "your_id": p.player_id,
            "your_username": p.username,
            "opponent_id": opp.player_id,
            "opponent_username": opp.username,
            "mode": match.mode,
            "rounds_to_win": ROUNDS_TO_WIN,
        })

    winner: Optional[Player] = None
    loser: Optional[Player] = None
    try:
        while match.p1.wins < ROUNDS_TO_WIN and match.p2.wins < ROUNDS_TO_WIN:
            match.round_num += 1
            round_winner = await run_round(match)
            if round_winner is None:
                match.inactive_rounds += 1
                if match.inactive_rounds >= MAX_INACTIVE_ROUNDS:
                    print(f"[MATCH] Abandoning {match.match_id}: {MAX_INACTIVE_ROUNDS} consecutive inactive rounds")
                    break
            else:
                match.inactive_rounds = 0
        if match.p1.wins > match.p2.wins:
            winner, loser = match.p1, match.p2
        elif match.p2.wins > match.p1.wins:
            winner, loser = match.p2, match.p1
        final_score = f"{winner.wins}-{loser.wins}" if winner else f"{match.p1.wins}-{match.p2.wins}"
        if winner:
            print(f"[MATCH] Ended {match.match_id}: {winner.username} {winner.wins}-{loser.wins}")
        else:
            print(f"[MATCH] Abandoned {match.match_id}: {match.p1.wins}-{match.p2.wins} (inactive)")
        for p in [match.p1, match.p2]:
            await safe_send(p.websocket, {
                "type": "match_end",
                "you_won": p is winner,
                "final_score": final_score,
                "mode": match.mode,
            })
        rsid = str(uuid.uuid4())[:12]
        rs = RematchSession(
            session_id=rsid, p1=match.p1, p2=match.p2,
            mode=match.mode, room_code=match.room_code,
        )
        rematch_sessions[rsid] = rs
        player_to_rematch[match.p1.player_id] = rsid
        player_to_rematch[match.p2.player_id] = rsid
        print(f"[REMATCH] Session {rsid} open for {match.p1.username} vs {match.p2.username}")
    finally:
        try:
            await persist_match(match, winner)
        except Exception as e:
            print(f"[DB ERROR] Failed to persist {match.match_id}: {e}")
        active_matches.pop(match.match_id, None)
        player_to_match.pop(match.p1.player_id, None)
        player_to_match.pop(match.p2.player_id, None)


async def run_round(match: Match) -> Optional[Player]:
    p1, p2 = match.p1, match.p2
    p1.click_received_us = None; p2.click_received_us = None
    p1.client_reported_rt_ms = None; p2.client_reported_rt_ms = None
    p1.pre_clicked = False; p2.pre_clicked = False
    p1.click_duration_ms = None; p2.click_duration_ms = None
    p1.mouse_distance_5s_px = None; p2.mouse_distance_5s_px = None
    p1.time_since_mouse_move_ms = None; p2.time_since_mouse_move_ms = None
    p1.window_focused = None; p2.window_focused = None

    delay_s = random.uniform(MIN_DELAY_S, MAX_DELAY_S)
    if match.round_num == 1:
        delay_s += 2.0  # extra buffer for the "Name vs Name" intro overlay

    for p in (p1, p2):
        await safe_send(p.websocket, {"type": "round_prepare", "round_num": match.round_num})

    await asyncio.sleep(delay_s)

    t_stimulus = now_us()
    fire = {"type": "stimulus", "server_time_us": t_stimulus}
    # Ping fires with the stimulus. Pong is guaranteed to arrive before any valid
    # click because the human reaction delay (≥ HUMAN_FLOOR_MS) always exceeds RTT.
    ping_id = match.round_num
    round_ping = {"type": "ping", "ping_id": ping_id, "server_time_us": t_stimulus}
    await asyncio.gather(
        safe_send(p1.websocket, fire),
        safe_send(p2.websocket, fire),
        safe_send(p1.websocket, round_ping),
        safe_send(p2.websocket, round_ping),
    )

    deadline = t_stimulus + 3_000_000
    while p1.click_received_us is None or p2.click_received_us is None:
        if now_us() > deadline: break
        await asyncio.sleep(0.005)

    # Collect the pongs that arrived during the reaction window.
    # If somehow the pong is missing (packet loss), fall back to last known latency.
    async def _update_latency(player: Player) -> None:
        try:
            while True:
                pong_msg, t_arrived = await asyncio.wait_for(
                    player.pong_queue.get(), timeout=ROUND_PING_TIMEOUT_S
                )
                if pong_msg.get("ping_id") == ping_id:
                    player.one_way_latency_ms = (t_arrived - t_stimulus) / 2000.0
                    break
                # stale pong from a previous round — discard and keep waiting
        except asyncio.TimeoutError:
            pass  # keep last known value

    await asyncio.gather(_update_latency(p1), _update_latency(p2))

    # Raw server-measured RT (network latency included).
    def _raw(p: Player) -> Optional[float]:
        return None if p.click_received_us is None else (p.click_received_us - t_stimulus) / 1000.0

    p1_raw = _raw(p1)
    p2_raw = _raw(p2)

    # Compensated RT: subtract full RTT (2 × one-way latency) measured this round.
    def _compensated(p: Player, raw: Optional[float]) -> Optional[float]:
        return None if raw is None else raw - 2.0 * p.one_way_latency_ms

    p1_compensated = _compensated(p1, p1_raw)
    p2_compensated = _compensated(p2, p2_raw)

    # Effective RT used for win determination depends on mode.
    if match.mode == "practice":
        p1_eff = p1.client_reported_rt_ms
        p2_eff = p2.client_reported_rt_ms
    else:
        p1_eff = p1_compensated
        p2_eff = p2_compensated

    def is_valid(p: Player, rt: Optional[float]) -> bool:
        return not p.pre_clicked and rt is not None and rt >= HUMAN_FLOOR_MS

    p1_ok, p2_ok = is_valid(p1, p1_eff), is_valid(p2, p2_eff)
    if p1_ok and p2_ok:
        round_winner = p1 if p1_eff < p2_eff else p2
    elif p1_ok: round_winner = p1
    elif p2_ok: round_winner = p2
    else: round_winner = None

    if round_winner: round_winner.wins += 1

    def _fmt(v: Optional[float]) -> str:
        return f"{v:.1f}" if v is not None else "—"

    winner_name = round_winner.username if round_winner else "no-contest"
    mode_tag = "[PRACTICE]" if match.mode == "practice" else "[RANKED]"
    print(
        f"[ROUND {match.round_num}]{mode_tag} "
        f"{p1.username}={_fmt(p1_eff)}ms(raw={_fmt(p1_raw)},rtt={p1.one_way_latency_ms*2:.1f}ms) vs "
        f"{p2.username}={_fmt(p2_eff)}ms(raw={_fmt(p2_raw)},rtt={p2.one_way_latency_ms*2:.1f}ms) "
        f"-> {winner_name}"
    )

    match.round_log.append({
        "round_num": match.round_num,
        "t_stimulus_us": t_stimulus,
        "delay_s": round(delay_s, 3),
        "p1_click_us": p1.click_received_us,
        "p2_click_us": p2.click_received_us,
        "p1_raw_rt_ms": p1_raw,
        "p1_compensated_rt_ms": p1_compensated,
        "p2_raw_rt_ms": p2_raw,
        "p2_compensated_rt_ms": p2_compensated,
        "p1_client_rt_ms": p1.client_reported_rt_ms,
        "p2_client_rt_ms": p2.client_reported_rt_ms,
        "p1_pre_click": p1.pre_clicked,
        "p2_pre_click": p2.pre_clicked,
        "winner": round_winner.player_id if round_winner else None,
        "p1_rtt_ms_round": round(p1.one_way_latency_ms * 2, 3),
        "p2_rtt_ms_round": round(p2.one_way_latency_ms * 2, 3),
        "p1_click_duration_ms": p1.click_duration_ms,
        "p2_click_duration_ms": p2.click_duration_ms,
        "p1_mouse_distance_5s_px": p1.mouse_distance_5s_px,
        "p2_mouse_distance_5s_px": p2.mouse_distance_5s_px,
        "p1_time_since_mouse_move_ms": p1.time_since_mouse_move_ms,
        "p2_time_since_mouse_move_ms": p2.time_since_mouse_move_ms,
        "p1_window_focused": p1.window_focused,
        "p2_window_focused": p2.window_focused,
    })

    for p, opp in [(p1, p2), (p2, p1)]:
        await safe_send(p.websocket, {
            "type": "round_result",
            "round_num": match.round_num,
            "your_rt_ms": p.client_reported_rt_ms,
            "opponent_rt_ms": opp.client_reported_rt_ms,
            "opponent_pre_click": opp.pre_clicked,
            "you_won_round": round_winner is p,
            "your_score": p.wins,
            "opponent_score": opp.wins,
        })

    # Skip ready-wait on the decisive final round so match_end arrives immediately.
    if p1.wins >= ROUNDS_TO_WIN or p2.wins >= ROUNDS_TO_WIN:
        return round_winner

    p1.ready = False
    p2.ready = False
    ready_deadline = now_us() + 5_000_000  # 5 s in µs
    while not (p1.ready and p2.ready):
        if now_us() > ready_deadline:
            break
        await asyncio.sleep(0.01)

    return round_winner


@app.websocket("/ws/play")
async def ws_play(websocket: WebSocket) -> None:
    await websocket.accept()
    player = Player(player_id=str(uuid.uuid4())[:12], username="anon", websocket=websocket)
    print(f"[WS] Connected: {player.player_id}")
    await safe_send(websocket, {"type": "hello", "player_id": player.player_id})

    try:
        while True:
            msg = await websocket.receive_json()
            t_received = now_us()
            mtype = msg.get("type")

            if mtype == "pong":
                await player.pong_queue.put((msg, now_us()))

            elif mtype == "set_username":
                player.username = (msg.get("username") or "anon")[:32]
                await ensure_player_row(player.player_id, player.username)
                await safe_send(websocket, {"type": "username_set", "username": player.username})

            elif mtype == "quickplay":
                await ensure_player_row(player.player_id, player.username)
                print(f"[QUEUE] {player.username} ({player.player_id}) joined ranked")
                match = await lobby.quickplay_join(player)
                if match is None:
                    await safe_send(websocket, {"type": "queued", "mode": "ranked"})
                else:
                    asyncio.create_task(run_match(match))

            elif mtype == "practice_quickplay":
                await ensure_player_row(player.player_id, player.username)
                print(f"[QUEUE] {player.username} ({player.player_id}) joined practice")
                match = await lobby.practice_join(player)
                if match is None:
                    await safe_send(websocket, {"type": "queued", "mode": "practice"})
                else:
                    asyncio.create_task(run_match(match))

            elif mtype == "create_room":
                await ensure_player_row(player.player_id, player.username)
                code = await lobby.create_room(player)
                print(f"[ROOM] {player.username} created room {code}")
                await safe_send(websocket, {"type": "room_created", "room_code": code})

            elif mtype == "join_room":
                await ensure_player_row(player.player_id, player.username)
                code = (msg.get("room_code") or "").upper().strip()
                match = await lobby.join_room(code, player)
                if match is None:
                    await safe_send(websocket, {"type": "room_join_failed", "code": code})
                else:
                    asyncio.create_task(run_match(match))

            elif mtype == "cancel_queue":
                await lobby.quickplay_leave(player)
                await lobby.practice_leave(player)
                await lobby.cancel_room(player)
                await safe_send(websocket, {"type": "cancelled"})

            elif mtype == "rematch_vote":
                rsid = player_to_rematch.get(player.player_id)
                rs = rematch_sessions.get(rsid) if rsid else None
                if rs is None:
                    continue
                rs.votes.add(player.player_id)
                for p in [rs.p1, rs.p2]:
                    await safe_send(p.websocket, {"type": "rematch_status", "votes": len(rs.votes)})
                if len(rs.votes) == 2:
                    rematch_sessions.pop(rsid, None)
                    player_to_rematch.pop(rs.p1.player_id, None)
                    player_to_rematch.pop(rs.p2.player_id, None)
                    for p in [rs.p1, rs.p2]:
                        await safe_send(p.websocket, {"type": "rematch_go"})
                    print(f"[REMATCH] Both voted — starting {rs.p1.username} vs {rs.p2.username}")
                    asyncio.create_task(start_rematch(rs))

            elif mtype == "rematch_cancel":
                rsid = player_to_rematch.pop(player.player_id, None)
                rs = rematch_sessions.pop(rsid, None) if rsid else None
                if rs is None:
                    continue
                partner = rs.p2 if rs.p1.player_id == player.player_id else rs.p1
                player_to_rematch.pop(partner.player_id, None)
                await safe_send(partner.websocket, {"type": "opponent_left"})
                print(f"[REMATCH] {player.username} cancelled — notified {partner.username}")

            elif mtype == "client_info":
                player.platform = (msg.get("platform") or "unknown")[:16]
                player.screen_refresh_hz = msg.get("screen_refresh_hz")
                player.screen_resolution = (msg.get("screen_resolution") or "")[:16]
                player.client_version = (msg.get("client_version") or "")[:16]

            elif mtype == "click_info":
                # Sent on mouseup after a click; attaches click_duration to the current round
                player.click_duration_ms = msg.get("click_duration_ms")

            elif mtype == "click":
                match_id = player_to_match.get(player.player_id)
                if not match_id: continue
                m = active_matches.get(match_id)
                if not m: continue
                target = m.p1 if m.p1.player_id == player.player_id else m.p2
                if target.click_received_us is None:
                    target.click_received_us = t_received
                    target.client_reported_rt_ms = msg.get("client_rt_ms")
                    target.pre_clicked = bool(msg.get("pre_click", False))
                    target.mouse_distance_5s_px = msg.get("mouse_distance_5s_px")
                    target.time_since_mouse_move_ms = msg.get("time_since_mouse_move_ms")
                    target.window_focused = msg.get("window_focused")
                    opponent = m.p2 if target is m.p1 else m.p1
                    await safe_send(opponent.websocket, {
                        "type": "opponent_clicked",
                        "pre_click": target.pre_clicked,
                    })

            elif mtype == "ready_up":
                match_id = player_to_match.get(player.player_id)
                if not match_id: continue
                m = active_matches.get(match_id)
                if not m: continue
                target = m.p1 if m.p1.player_id == player.player_id else m.p2
                target.ready = True

            elif mtype == "calibration_click":
                rt_ms = msg.get("rt_ms")
                side = msg.get("side", "unknown")
                if rt_ms is not None and 50.0 <= float(rt_ms) <= 2000.0:
                    asyncio.create_task(save_calibration(player, float(rt_ms), side))

            elif mtype == "leaderboard_request":
                stat = msg.get("stat", "avg_rt")
                if stat not in _VALID_STATS:
                    stat = "avg_rt"
                try:
                    rows = await fetch_leaderboard(stat)
                except Exception as e:
                    print(f"[LEADERBOARD] Query failed: {e}")
                    rows = []
                await safe_send(websocket, {"type": "leaderboard_data", "stat": stat, "rows": rows})

    except WebSocketDisconnect:
        print(f"[WS] Disconnected: {player.player_id}")
        await lobby.quickplay_leave(player)
        await lobby.practice_leave(player)
        await lobby.cancel_room(player)
        rsid = player_to_rematch.pop(player.player_id, None)
        rs = rematch_sessions.pop(rsid, None) if rsid else None
        if rs is not None:
            partner = rs.p2 if rs.p1.player_id == player.player_id else rs.p1
            player_to_rematch.pop(partner.player_id, None)
            await safe_send(partner.websocket, {"type": "opponent_left"})


@app.get("/health")
async def health_detail() -> dict:
    return {
        "status": "ok",
        "quickplay_queue": len(lobby.quickplay_queue),
        "practice_queue": len(lobby.practice_queue),
        "private_rooms": len(lobby.private_rooms),
        "active_matches": len(active_matches),
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="127.0.0.1", port=8000, reload=True)
