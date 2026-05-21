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
from models import (Match as MatchRow, Player as PlayerRow, Round as RoundRow,
                    CalibrationRound as CalibrationRoundRow,
                    TeamMatch as TeamMatchRow, TeamRound as TeamRoundRow,
                    FFAMatch as FFAMatchRow, FFARound as FFARoundRow)

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
CHEAT_DURATION_MS = 10.0  # click held < 10ms → auto-clicker flag
ROOM_CODE_CHARS = string.ascii_uppercase + string.digits
ROOM_CODE_LEN = 6
CLIENT_VERSION = "0.2.0"
# Pong must arrive before any valid click.
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
    click_pos_x: Optional[float] = None
    click_pos_y: Optional[float] = None
    pre_click_displacement_px: Optional[float] = None


@dataclass
class Match:
    match_id: str
    p1: Player
    p2: Player
    mode: str
    room_code: Optional[str] = None
    is_auditory: bool = False
    round_num: int = 0
    round_log: list[dict] = field(default_factory=list)
    inactive_rounds: int = 0


@dataclass
class TeamGameMatch:
    match_id: str
    t1: list[Player]  # [slot0, slot1]
    t2: list[Player]  # [slot0, slot1]
    round_num: int = 0
    t1_score: int = 0
    t2_score: int = 0
    round_log: list[dict] = field(default_factory=list)
    inactive_rounds: int = 0
    is_auditory: bool = False

    @property
    def all_players(self) -> list[Player]:
        return self.t1 + self.t2


@dataclass
class RematchSession:
    session_id: str
    p1: Player
    p2: Player
    mode: str
    room_code: Optional[str] = None
    votes: set = field(default_factory=set)


@dataclass
class TeamRematchSession:
    session_id: str
    t1: list
    t2: list
    votes: set = field(default_factory=set)

    @property
    def all_players(self) -> list:
        return self.t1 + self.t2


@dataclass
class FFAGame:
    match_id: str
    players: list
    round_num: int = 0
    scores: list = field(default_factory=list)
    round_log: list = field(default_factory=list)
    inactive_rounds: int = 0
    is_private: bool = False
    is_auditory: bool = False

    def __post_init__(self):
        if not self.scores:
            self.scores = [0] * len(self.players)


@dataclass
class FFARematchSession:
    session_id: str
    players: list  # 4 Player objects
    votes: set = field(default_factory=set)


class Lobby:
    def __init__(self) -> None:
        self.quickplay_queue: list[Player] = []
        self.auditory_queue: list[Player] = []
        self.practice_queue: list[Player] = []
        self.team_queue: list[Player] = []
        self.ffa_queue: list[Player] = []
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

    async def auditory_quickplay_join(self, player: Player) -> Optional[Match]:
        async with self.lock:
            for queued in self.auditory_queue:
                if queued.player_id == player.player_id:
                    return None
            if self.auditory_queue:
                opponent = self.auditory_queue.pop(0)
                return Match(match_id=str(uuid.uuid4())[:12], p1=opponent, p2=player, mode="ranked", is_auditory=True)
            self.auditory_queue.append(player)
            return None

    async def auditory_quickplay_leave(self, player: Player) -> None:
        async with self.lock:
            if player in self.auditory_queue:
                self.auditory_queue.remove(player)

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

    async def team_quickplay_join(self, player: Player) -> Optional[TeamGameMatch]:
        async with self.lock:
            for q in self.team_queue:
                if q.player_id == player.player_id:
                    return None
            self.team_queue.append(player)
            if len(self.team_queue) >= 4:
                players = [self.team_queue.pop(0) for _ in range(4)]
                random.shuffle(players)
                return TeamGameMatch(
                    match_id=str(uuid.uuid4())[:12],
                    t1=[players[0], players[1]],
                    t2=[players[2], players[3]],
                )
            return None

    async def team_quickplay_leave(self, player: Player) -> None:
        async with self.lock:
            if player in self.team_queue:
                self.team_queue.remove(player)

    async def ffa_quickplay_join(self, player: Player) -> Optional[FFAGame]:
        async with self.lock:
            for q in self.ffa_queue:
                if q.player_id == player.player_id:
                    return None
            self.ffa_queue.append(player)
            if len(self.ffa_queue) >= 4:
                players = [self.ffa_queue.pop(0) for _ in range(4)]
                random.shuffle(players)
                return FFAGame(match_id=str(uuid.uuid4())[:12], players=players)
            return None

    async def ffa_quickplay_leave(self, player: Player) -> None:
        async with self.lock:
            if player in self.ffa_queue:
                self.ffa_queue.remove(player)


lobby = Lobby()
active_matches: dict[str, Match] = {}
player_to_match: dict[str, str] = {}
rematch_sessions: dict[str, RematchSession] = {}
player_to_rematch: dict[str, str] = {}
active_team_matches: dict[str, TeamGameMatch] = {}
player_to_team_match: dict[str, str] = {}
team_rematch_sessions: dict[str, "TeamRematchSession"] = {}
player_to_team_rematch: dict[str, str] = {}
active_ffa_matches: dict[str, FFAGame] = {}
player_to_ffa_match: dict[str, str] = {}
ffa_rematch_sessions: dict[str, "FFARematchSession"] = {}
player_to_ffa_rematch: dict[str, str] = {}


@dataclass
class PrivateLobby:
    code: str
    leader_id: str
    players: list  # Player objects
    gamemode: str = "1v1"
    cue: str = "visual"

private_lobbies: dict[str, PrivateLobby] = {}
player_to_private_lobby: dict[str, str] = {}


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



_VALID_STATS = {"avg_rt", "best_match_rt", "wins", "winrate", "cheaters"}

async def fetch_leaderboard(stat: str) -> list[dict]:
    queries = {
        "avg_rt": text("""
            WITH player_rts AS (
                SELECT m.p1_id AS player_id, r.p1_server_rt_compensated_ms AS rt_ms
                FROM rounds r JOIN matches m ON r.match_id = m.id
                WHERE r.p1_server_rt_compensated_ms IS NOT NULL AND NOT r.p1_pre_click
                  AND m.mode != 'practice' AND NOT m.is_auditory
                UNION ALL
                SELECT m.p2_id AS player_id, r.p2_server_rt_compensated_ms AS rt_ms
                FROM rounds r JOIN matches m ON r.match_id = m.id
                WHERE r.p2_server_rt_compensated_ms IS NOT NULL AND NOT r.p2_pre_click
                  AND m.mode != 'practice' AND NOT m.is_auditory
            )
            SELECT p.username, ROUND(AVG(pr.rt_ms)::numeric, 1) AS value
            FROM player_rts pr JOIN players p ON pr.player_id = p.id
            WHERE p.cheat_flag_count = 0
            GROUP BY p.id, p.username
            HAVING COUNT(*) >= 3
            ORDER BY value ASC
            LIMIT 10
        """),
        "best_match_rt": text("""
            WITH match_avgs AS (
                SELECT m.p1_id AS player_id,
                       AVG(CASE WHEN r.p1_pre_click THEN 350.0
                                ELSE r.p1_server_rt_compensated_ms END) AS avg_rt
                FROM rounds r JOIN matches m ON r.match_id = m.id
                WHERE (r.p1_pre_click OR r.p1_server_rt_compensated_ms IS NOT NULL)
                  AND m.mode != 'practice' AND NOT m.is_auditory
                GROUP BY m.id, m.p1_id
                UNION ALL
                SELECT m.p2_id AS player_id,
                       AVG(CASE WHEN r.p2_pre_click THEN 350.0
                                ELSE r.p2_server_rt_compensated_ms END) AS avg_rt
                FROM rounds r JOIN matches m ON r.match_id = m.id
                WHERE (r.p2_pre_click OR r.p2_server_rt_compensated_ms IS NOT NULL)
                  AND m.mode != 'practice' AND NOT m.is_auditory
                GROUP BY m.id, m.p2_id
            )
            SELECT p.username, ROUND(MIN(ma.avg_rt)::numeric, 1) AS value
            FROM match_avgs ma JOIN players p ON ma.player_id = p.id
            WHERE p.cheat_flag_count = 0
            GROUP BY p.id, p.username
            ORDER BY value ASC
            LIMIT 10
        """),
        "wins": text("""
            SELECT p.username, COUNT(*) AS value
            FROM matches m
            JOIN players p ON m.winner_id = p.id
            WHERE m.mode != 'practice' AND NOT m.is_auditory AND p.cheat_flag_count = 0
            GROUP BY p.id, p.username
            ORDER BY value DESC
            LIMIT 10
        """),
        "winrate": text("""
            WITH player_matches AS (
                SELECT p1_id AS player_id, winner_id FROM matches WHERE mode != 'practice' AND NOT is_auditory
                UNION ALL
                SELECT p2_id AS player_id, winner_id FROM matches WHERE mode != 'practice' AND NOT is_auditory
            )
            SELECT p.username,
                   ROUND(100.0 * COUNT(*) FILTER (WHERE pm.winner_id = pm.player_id) / COUNT(*), 1) AS value,
                   COUNT(*) FILTER (WHERE pm.winner_id = pm.player_id) AS wins,
                   COUNT(*) AS total
            FROM player_matches pm
            JOIN players p ON pm.player_id = p.id
            WHERE p.cheat_flag_count = 0
            GROUP BY p.id, p.username
            HAVING COUNT(*) >= 5
            ORDER BY value DESC
            LIMIT 10
        """),
        "cheaters": text("""
            WITH player_round_counts AS (
                SELECT m.p1_id AS player_id, COUNT(r.id) AS n
                FROM matches m JOIN rounds r ON r.match_id = m.id
                GROUP BY m.p1_id
                UNION ALL
                SELECT m.p2_id AS player_id, COUNT(r.id) AS n
                FROM matches m JOIN rounds r ON r.match_id = m.id
                GROUP BY m.p2_id
            ),
            totals AS (
                SELECT player_id, SUM(n) AS rounds_played
                FROM player_round_counts GROUP BY player_id
            )
            SELECT p.username, p.cheat_flag_count AS value
            FROM players p
            LEFT JOIN totals t ON t.player_id = p.id
            WHERE p.cheat_flag_count > 0
            ORDER BY COALESCE(t.rounds_played, 0) DESC, p.cheat_flag_count DESC
            LIMIT 25
        """),
    }
    async with AsyncSessionLocal() as session:
        result = await session.execute(queries[stat])
        rows = result.fetchall()
        if stat == "winrate":
            return [{"username": r.username, "value": float(r.value),
                     "wins": int(r.wins), "losses": int(r.total) - int(r.wins)} for r in rows]
        return [{"username": r.username, "value": float(r.value)} for r in rows]


async def fetch_recent_matches(limit: int = 20, player_id: Optional[str] = None,
                               match_type: str = "all") -> list[dict]:
    results: list[dict] = []

    if match_type in ("all", "1v1"):
        results += await _fetch_1v1_recent(limit, player_id)

    if match_type in ("all", "2v2"):
        results += await _fetch_2v2_recent(limit, player_id)

    if match_type in ("all", "ffa"):
        results += await _fetch_ffa_recent(limit, player_id)

    results.sort(key=lambda m: m.get("started_at", ""), reverse=True)
    return results[:limit]


async def _fetch_1v1_recent(limit: int, player_id: Optional[str]) -> list[dict]:
    where = "WHERE mode != 'practice'"
    params: dict = {"limit": limit}
    if player_id:
        where += " AND (p1_id = :player_id OR p2_id = :player_id)"
        params["player_id"] = player_id
    async with AsyncSessionLocal() as session:
        result = await session.execute(text(f"""
            WITH recent AS (
                SELECT id, p1_username, p2_username, p1_final_score, p2_final_score,
                       winner_id, p1_id, p2_id, started_at, is_auditory, mode
                FROM matches
                {where}
                ORDER BY started_at DESC
                LIMIT :limit
            )
            SELECT m.id AS match_id, m.p1_username, m.p2_username,
                   m.p1_final_score, m.p2_final_score,
                   m.winner_id, m.p1_id, m.p2_id, m.started_at,
                   m.is_auditory, m.mode,
                   r.round_num, r.winner_id AS round_winner_id,
                   r.p1_server_rt_compensated_ms, r.p2_server_rt_compensated_ms,
                   r.p1_pre_click, r.p2_pre_click
            FROM recent m
            LEFT JOIN rounds r ON r.match_id = m.id
            ORDER BY m.started_at DESC, r.round_num ASC
        """), params)
        rows = result.fetchall()

    matches_ordered: list[dict] = []
    matches_map: dict[str, dict] = {}
    for row in rows:
        mid = row.match_id
        if mid not in matches_map:
            entry = {
                "match_type": "1v1",
                "match_id": mid,
                "p1_username": row.p1_username,
                "p2_username": row.p2_username,
                "p1_score": row.p1_final_score,
                "p2_score": row.p2_final_score,
                "winner_id": row.winner_id,
                "p1_id": row.p1_id,
                "p2_id": row.p2_id,
                "started_at": row.started_at.isoformat() if row.started_at else "",
                "is_auditory": bool(row.is_auditory),
                "mode": row.mode,
                "rounds": [],
            }
            matches_map[mid] = entry
            matches_ordered.append(entry)
        if row.round_num is not None:
            matches_map[mid]["rounds"].append({
                "round_num": row.round_num,
                "winner_id": row.round_winner_id,
                "p1_rt_ms": row.p1_server_rt_compensated_ms,
                "p2_rt_ms": row.p2_server_rt_compensated_ms,
                "p1_pre_click": bool(row.p1_pre_click) if row.p1_pre_click is not None else False,
                "p2_pre_click": bool(row.p2_pre_click) if row.p2_pre_click is not None else False,
            })
    return matches_ordered


async def _fetch_2v2_recent(limit: int, player_id: Optional[str]) -> list[dict]:
    where = "WHERE 1=1"
    params: dict = {"limit": limit}
    if player_id:
        where += " AND (t1_p1_id = :pid OR t1_p2_id = :pid OR t2_p1_id = :pid OR t2_p2_id = :pid)"
        params["pid"] = player_id
    async with AsyncSessionLocal() as session:
        result = await session.execute(text(f"""
            WITH recent AS (
                SELECT id, t1_p1_username, t1_p2_username, t2_p1_username, t2_p2_username,
                       t1_score, t2_score, winner_team, started_at
                FROM team_matches
                {where}
                ORDER BY started_at DESC
                LIMIT :limit
            )
            SELECT m.id AS match_id,
                   m.t1_p1_username, m.t1_p2_username, m.t2_p1_username, m.t2_p2_username,
                   m.t1_score, m.t2_score, m.winner_team, m.started_at,
                   r.round_num, r.winner_team AS round_winner_team,
                   r.t1_p1_rt_ms, r.t1_p2_rt_ms, r.t2_p1_rt_ms, r.t2_p2_rt_ms,
                   r.t1_combined_ms, r.t2_combined_ms,
                   r.t1_p1_pre_click, r.t1_p2_pre_click, r.t2_p1_pre_click, r.t2_p2_pre_click
            FROM recent m
            LEFT JOIN team_rounds r ON r.match_id = m.id
            ORDER BY m.started_at DESC, r.round_num ASC
        """), params)
        rows = result.fetchall()

    matches_ordered: list[dict] = []
    matches_map: dict[str, dict] = {}
    for row in rows:
        mid = row.match_id
        if mid not in matches_map:
            entry = {
                "match_type": "2v2",
                "match_id": mid,
                "t1_names": [row.t1_p1_username, row.t1_p2_username],
                "t2_names": [row.t2_p1_username, row.t2_p2_username],
                "t1_score": row.t1_score,
                "t2_score": row.t2_score,
                "winner_team": row.winner_team,
                "started_at": row.started_at.isoformat() if row.started_at else "",
                "rounds": [],
            }
            matches_map[mid] = entry
            matches_ordered.append(entry)
        if row.round_num is not None:
            matches_map[mid]["rounds"].append({
                "round_num": row.round_num,
                "winner_team": row.round_winner_team,
                "t1_rt_ms": [row.t1_p1_rt_ms, row.t1_p2_rt_ms],
                "t2_rt_ms": [row.t2_p1_rt_ms, row.t2_p2_rt_ms],
                "t1_combined_ms": row.t1_combined_ms,
                "t2_combined_ms": row.t2_combined_ms,
                "t1_pre_click": [bool(row.t1_p1_pre_click), bool(row.t1_p2_pre_click)],
                "t2_pre_click": [bool(row.t2_p1_pre_click), bool(row.t2_p2_pre_click)],
            })
    return matches_ordered


async def _fetch_ffa_recent(limit: int, player_id: Optional[str]) -> list[dict]:
    where = "WHERE 1=1"
    params: dict = {"limit": limit}
    if player_id:
        where += " AND (p1_id = :pid OR p2_id = :pid OR p3_id = :pid OR p4_id = :pid)"
        params["pid"] = player_id
    async with AsyncSessionLocal() as session:
        result = await session.execute(text(f"""
            WITH recent AS (
                SELECT id, p1_id, p2_id, p3_id, p4_id,
                       p1_username, p2_username, p3_username, p4_username,
                       p1_score, p2_score, p3_score, p4_score,
                       p1_placement, p2_placement, p3_placement, p4_placement,
                       winner_id, started_at
                FROM ffa_matches
                {where}
                ORDER BY started_at DESC
                LIMIT :limit
            )
            SELECT m.id AS match_id,
                   m.p1_id, m.p2_id, m.p3_id, m.p4_id,
                   m.p1_username, m.p2_username, m.p3_username, m.p4_username,
                   m.p1_score, m.p2_score, m.p3_score, m.p4_score,
                   m.p1_placement, m.p2_placement, m.p3_placement, m.p4_placement,
                   m.winner_id, m.started_at,
                   r.round_num, r.winner_slot,
                   r.p1_rt_ms, r.p2_rt_ms, r.p3_rt_ms, r.p4_rt_ms,
                   r.p1_pre_click, r.p2_pre_click, r.p3_pre_click, r.p4_pre_click
            FROM recent m
            LEFT JOIN ffa_rounds r ON r.match_id = m.id
            ORDER BY m.started_at DESC, r.round_num ASC
        """), params)
        rows = result.fetchall()

    print(f"[RECENT] _fetch_ffa_recent: {len(rows)} rows returned")
    matches_ordered: list[dict] = []
    matches_map: dict[str, dict] = {}
    for row in rows:
        mid = row.match_id
        if mid not in matches_map:
            entry = {
                "match_type": "ffa",
                "match_id": mid,
                "usernames": [row.p1_username, row.p2_username, row.p3_username, row.p4_username],
                "ids": [str(row.p1_id), str(row.p2_id), str(row.p3_id), str(row.p4_id)],
                "scores": [row.p1_score, row.p2_score, row.p3_score, row.p4_score],
                "placements": [row.p1_placement, row.p2_placement, row.p3_placement, row.p4_placement],
                "winner_id": str(row.winner_id) if row.winner_id is not None else "",
                "started_at": row.started_at.isoformat() if row.started_at else "",
                "rounds": [],
            }
            matches_map[mid] = entry
            matches_ordered.append(entry)
        if row.round_num is not None:
            matches_map[mid]["rounds"].append({
                "round_num": row.round_num,
                "winner_slot": row.winner_slot,
                "rt_ms": [row.p1_rt_ms, row.p2_rt_ms, row.p3_rt_ms, row.p4_rt_ms],
                "pre_click": [bool(row.p1_pre_click), bool(row.p2_pre_click),
                              bool(row.p3_pre_click), bool(row.p4_pre_click)],
            })
    return matches_ordered


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
        PRE_CLICK_PENALTY_MS = 350.0
        p1_rts = [PRE_CLICK_PENALTY_MS if r.get("p1_pre_click")
                  else r["p1_compensated_rt_ms"]
                  for r in match.round_log
                  if r.get("p1_pre_click") or r.get("p1_compensated_rt_ms") is not None]
        p2_rts = [PRE_CLICK_PENALTY_MS if r.get("p2_pre_click")
                  else r["p2_compensated_rt_ms"]
                  for r in match.round_log
                  if r.get("p2_pre_click") or r.get("p2_compensated_rt_ms") is not None]
        p1_avg_rt = round(sum(p1_rts) / len(p1_rts), 1) if p1_rts else None
        p2_avg_rt = round(sum(p2_rts) / len(p2_rts), 1) if p2_rts else None

        session.add(MatchRow(
            id=match.match_id,
            p1_id=match.p1.player_id, p2_id=match.p2.player_id,
            winner_id=winner.player_id if winner else None,
            mode=match.mode, room_code=match.room_code, is_auditory=match.is_auditory,
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
            p1_avg_rt_ms=p1_avg_rt,
            p2_avg_rt_ms=p2_avg_rt,
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
                p1_click_pos_x=r["p1_click_pos_x"],
                p1_click_pos_y=r["p1_click_pos_y"],
                p2_click_pos_x=r["p2_click_pos_x"],
                p2_click_pos_y=r["p2_click_pos_y"],
                p1_pre_click_displacement_px=r["p1_pre_click_displacement_px"],
                p2_pre_click_displacement_px=r["p2_pre_click_displacement_px"],
            ))
        p1_won = 1 if winner and winner.player_id == match.p1.player_id else 0
        p2_won = 1 if winner and winner.player_id == match.p2.player_id else 0
        p1_cheats = sum(1 for r in match.round_log if r.get("p1_cheat_flag", False))
        p2_cheats = sum(1 for r in match.round_log if r.get("p2_cheat_flag", False))
        await session.execute(
            update(PlayerRow).where(PlayerRow.id == match.p1.player_id).values(
                matches_played=PlayerRow.matches_played + 1,
                matches_won=PlayerRow.matches_won + p1_won,
                cheat_flag_count=PlayerRow.cheat_flag_count + p1_cheats,
            )
        )
        await session.execute(
            update(PlayerRow).where(PlayerRow.id == match.p2.player_id).values(
                matches_played=PlayerRow.matches_played + 1,
                matches_won=PlayerRow.matches_won + p2_won,
                cheat_flag_count=PlayerRow.cheat_flag_count + p2_cheats,
            )
        )
        await session.commit()
        print(f"[DB] Wrote match {match.match_id} with {len(match.round_log)} rounds")


async def run_team_round(match: TeamGameMatch) -> int:
    """Run one round of a 2v2 match. Returns winning team (1, 2) or 0 for no-contest."""
    PRE_CLICK_PENALTY_MS = 350.0
    MISSED_CLICK_PENALTY_MS = 5000.0

    all_players = match.all_players
    for p in all_players:
        p.click_received_us = None
        p.client_reported_rt_ms = None
        p.pre_clicked = False
        p.click_duration_ms = None
        p.click_pos_x = None
        p.click_pos_y = None
        p.pre_click_displacement_px = None
        p.ready = False

    delay_s = random.uniform(MIN_DELAY_S, MAX_DELAY_S)
    if match.round_num == 1:
        delay_s += 4.0

    for p in all_players:
        await safe_send(p.websocket, {"type": "team_round_prepare", "round_num": match.round_num})

    await asyncio.sleep(delay_s)

    t_stimulus = now_us()
    ping_id = match.round_num
    stimulus_msg = {"type": "stimulus", "server_time_us": t_stimulus}
    ping_msg = {"type": "ping", "ping_id": ping_id, "server_time_us": t_stimulus}
    await asyncio.gather(*[safe_send(p.websocket, stimulus_msg) for p in all_players])
    await asyncio.gather(*[safe_send(p.websocket, ping_msg) for p in all_players])

    deadline = t_stimulus + 3_000_000
    while not all(p.click_received_us is not None for p in all_players):
        if now_us() > deadline:
            break
        await asyncio.sleep(0.005)

    async def _update_latency(player: Player) -> None:
        try:
            while True:
                pong_msg, t_arrived = await asyncio.wait_for(
                    player.pong_queue.get(), timeout=ROUND_PING_TIMEOUT_S
                )
                if pong_msg.get("ping_id") == ping_id:
                    measured = (t_arrived - t_stimulus) / 2000.0
                    if player.one_way_latency_ms == 0.0:
                        player.one_way_latency_ms = measured
                    else:
                        player.one_way_latency_ms = 0.3 * measured + 0.7 * player.one_way_latency_ms
                    break
        except asyncio.TimeoutError:
            pass

    await asyncio.gather(*[_update_latency(p) for p in all_players])
    await asyncio.sleep(0.25)

    def _raw(p: Player) -> Optional[float]:
        return None if p.click_received_us is None else (p.click_received_us - t_stimulus) / 1000.0

    def _compensated(p: Player, _: Optional[float]) -> Optional[float]:
        return p.client_reported_rt_ms  # client-reported RT (testing only)

    def _eff_rt(p: Player) -> float:
        if p.pre_clicked:
            return PRE_CLICK_PENALTY_MS
        comp = _compensated(p, _raw(p))
        return comp if comp is not None else MISSED_CLICK_PENALTY_MS

    def _display_rt(p: Player) -> Optional[float]:
        if p.pre_clicked or p.click_received_us is None:
            return None
        return _compensated(p, _raw(p))

    t1_effs = [_eff_rt(p) for p in match.t1]
    t2_effs = [_eff_rt(p) for p in match.t2]
    t1_combined = sum(t1_effs)
    t2_combined = sum(t2_effs)
    t1_display = [_display_rt(p) for p in match.t1]
    t2_display = [_display_rt(p) for p in match.t2]

    if t1_combined < t2_combined:
        winner_team = 1
        match.t1_score += 1
    elif t2_combined < t1_combined:
        winner_team = 2
        match.t2_score += 1
    else:
        winner_team = 0

    t1p1, t1p2, t2p1, t2p2 = match.t1[0], match.t1[1], match.t2[0], match.t2[1]
    match.round_log.append({
        "round_num": match.round_num,
        "t_stimulus_us": t_stimulus,
        "delay_s": round(delay_s, 3),
        # Compensated individual RTs
        "t1_p1_rt_ms": t1_display[0], "t1_p2_rt_ms": t1_display[1],
        "t2_p1_rt_ms": t2_display[0], "t2_p2_rt_ms": t2_display[1],
        # Raw server-measured RTs
        "t1_p1_rt_raw_ms": _raw(t1p1), "t1_p2_rt_raw_ms": _raw(t1p2),
        "t2_p1_rt_raw_ms": _raw(t2p1), "t2_p2_rt_raw_ms": _raw(t2p2),
        # Client-reported RTs
        "t1_p1_client_rt_ms": t1p1.client_reported_rt_ms, "t1_p2_client_rt_ms": t1p2.client_reported_rt_ms,
        "t2_p1_client_rt_ms": t2p1.client_reported_rt_ms, "t2_p2_client_rt_ms": t2p2.client_reported_rt_ms,
        # RTT (2 × one_way_latency for this round)
        "t1_p1_rtt_ms": round(t1p1.one_way_latency_ms * 2, 3), "t1_p2_rtt_ms": round(t1p2.one_way_latency_ms * 2, 3),
        "t2_p1_rtt_ms": round(t2p1.one_way_latency_ms * 2, 3), "t2_p2_rtt_ms": round(t2p2.one_way_latency_ms * 2, 3),
        # Pre-click flags
        "t1_p1_pre_click": t1p1.pre_clicked, "t1_p2_pre_click": t1p2.pre_clicked,
        "t2_p1_pre_click": t2p1.pre_clicked, "t2_p2_pre_click": t2p2.pre_clicked,
        # Behavioral anti-cheat features
        "t1_p1_click_duration_ms": t1p1.click_duration_ms, "t1_p2_click_duration_ms": t1p2.click_duration_ms,
        "t2_p1_click_duration_ms": t2p1.click_duration_ms, "t2_p2_click_duration_ms": t2p2.click_duration_ms,
        "t1_p1_mouse_distance_5s_px": t1p1.mouse_distance_5s_px, "t1_p2_mouse_distance_5s_px": t1p2.mouse_distance_5s_px,
        "t2_p1_mouse_distance_5s_px": t2p1.mouse_distance_5s_px, "t2_p2_mouse_distance_5s_px": t2p2.mouse_distance_5s_px,
        "t1_p1_time_since_mouse_move_ms": t1p1.time_since_mouse_move_ms, "t1_p2_time_since_mouse_move_ms": t1p2.time_since_mouse_move_ms,
        "t2_p1_time_since_mouse_move_ms": t2p1.time_since_mouse_move_ms, "t2_p2_time_since_mouse_move_ms": t2p2.time_since_mouse_move_ms,
        "t1_p1_window_focused": t1p1.window_focused, "t1_p2_window_focused": t1p2.window_focused,
        "t2_p1_window_focused": t2p1.window_focused, "t2_p2_window_focused": t2p2.window_focused,
        "t1_p1_click_pos_x": t1p1.click_pos_x, "t1_p1_click_pos_y": t1p1.click_pos_y,
        "t1_p2_click_pos_x": t1p2.click_pos_x, "t1_p2_click_pos_y": t1p2.click_pos_y,
        "t2_p1_click_pos_x": t2p1.click_pos_x, "t2_p1_click_pos_y": t2p1.click_pos_y,
        "t2_p2_click_pos_x": t2p2.click_pos_x, "t2_p2_click_pos_y": t2p2.click_pos_y,
        "t1_p1_pre_click_displacement_px": t1p1.pre_click_displacement_px, "t1_p2_pre_click_displacement_px": t1p2.pre_click_displacement_px,
        "t2_p1_pre_click_displacement_px": t2p1.pre_click_displacement_px, "t2_p2_pre_click_displacement_px": t2p2.pre_click_displacement_px,
        # Combined team RTs
        "t1_combined_ms": t1_combined, "t2_combined_ms": t2_combined,
        "winner_team": winner_team,
    })

    print(
        f"[TEAM ROUND {match.round_num}] "
        f"T1: {t1_effs[0]:.0f}+{t1_effs[1]:.0f}={t1_combined:.0f}ms  "
        f"T2: {t2_effs[0]:.0f}+{t2_effs[1]:.0f}={t2_combined:.0f}ms  "
        f"-> team{winner_team if winner_team else 'tie'}"
    )

    for team_num, team in [(1, match.t1), (2, match.t2)]:
        for slot, p in enumerate(team):
            await safe_send(p.websocket, {
                "type": "team_round_result",
                "round_num": match.round_num,
                "your_team": team_num,
                "your_slot": slot,
                "team1_rt_ms": t1_display,
                "team2_rt_ms": t2_display,
                "team1_combined_ms": t1_combined,
                "team2_combined_ms": t2_combined,
                "team1_pre_click": [match.t1[0].pre_clicked, match.t1[1].pre_clicked],
                "team2_pre_click": [match.t2[0].pre_clicked, match.t2[1].pre_clicked],
                "winner_team": winner_team,
                "t1_score": match.t1_score,
                "t2_score": match.t2_score,
            })

    if match.t1_score >= ROUNDS_TO_WIN or match.t2_score >= ROUNDS_TO_WIN:
        return winner_team

    for p in all_players:
        p.ready = False
    ready_deadline = now_us() + 5_000_000
    while not all(p.ready for p in all_players):
        if now_us() > ready_deadline:
            break
        await asyncio.sleep(0.01)

    return winner_team


async def run_team_match(match: TeamGameMatch) -> None:
    for p in match.all_players:
        player_to_team_match[p.player_id] = match.match_id
    active_team_matches[match.match_id] = match

    for team_num, team in [(1, match.t1), (2, match.t2)]:
        for slot, p in enumerate(team):
            await safe_send(p.websocket, {
                "type": "team_match_start",
                "match_id": match.match_id,
                "your_team": team_num,
                "your_slot": slot,
                "team1": [{"player_id": t.player_id, "username": t.username} for t in match.t1],
                "team2": [{"player_id": t.player_id, "username": t.username} for t in match.t2],
                "rounds_to_win": ROUNDS_TO_WIN,
                "is_auditory": match.is_auditory,
            })

    final_winner_team = 0
    try:
        while match.t1_score < ROUNDS_TO_WIN and match.t2_score < ROUNDS_TO_WIN:
            match.round_num += 1
            wt = await run_team_round(match)
            if wt == 0:
                match.inactive_rounds += 1
                if match.inactive_rounds >= MAX_INACTIVE_ROUNDS:
                    print(f"[TEAM MATCH] Abandoning {match.match_id}: too many inactive rounds")
                    break
            else:
                match.inactive_rounds = 0
        final_winner_team = 1 if match.t1_score > match.t2_score else (2 if match.t2_score > match.t1_score else 0)
        print(f"[TEAM MATCH] Ended {match.match_id}: T1={match.t1_score} T2={match.t2_score} winner=team{final_winner_team}")
        for team_num, team in [(1, match.t1), (2, match.t2)]:
            for p in team:
                await safe_send(p.websocket, {
                    "type": "team_match_end",
                    "winner_team": final_winner_team,
                    "your_team": team_num,
                    "t1_score": match.t1_score,
                    "t2_score": match.t2_score,
                })
        trsid = str(uuid.uuid4())[:12]
        trs = TeamRematchSession(session_id=trsid, t1=match.t1, t2=match.t2)
        team_rematch_sessions[trsid] = trs
        for p in match.all_players:
            player_to_team_rematch[p.player_id] = trsid
        print(f"[TEAM REMATCH] Session {trsid} open for {match.t1[0].username}/{match.t1[1].username} vs {match.t2[0].username}/{match.t2[1].username}")
    finally:
        try:
            await persist_team_match(match, final_winner_team)
        except Exception as e:
            print(f"[DB ERROR] Failed to persist team match {match.match_id}: {e}")
        active_team_matches.pop(match.match_id, None)
        for p in match.all_players:
            player_to_team_match.pop(p.player_id, None)


async def persist_team_match(match: TeamGameMatch, winner_team: int) -> None:
    print(f"[DB] Persisting team match {match.match_id}, winner=team{winner_team}, rounds={len(match.round_log)}")
    async with AsyncSessionLocal() as session:
        session.add(TeamMatchRow(
            id=match.match_id,
            t1_p1_id=match.t1[0].player_id, t1_p2_id=match.t1[1].player_id,
            t2_p1_id=match.t2[0].player_id, t2_p2_id=match.t2[1].player_id,
            t1_p1_username=match.t1[0].username, t1_p2_username=match.t1[1].username,
            t2_p1_username=match.t2[0].username, t2_p2_username=match.t2[1].username,
            winner_team=winner_team,
            t1_score=match.t1_score,
            t2_score=match.t2_score,
            is_auditory=match.is_auditory,
        ))
        for r in match.round_log:
            session.add(TeamRoundRow(
                match_id=match.match_id,
                round_num=r["round_num"],
                t_stimulus_us=r["t_stimulus_us"],
                delay_s=r["delay_s"],
                t1_p1_rt_ms=r["t1_p1_rt_ms"], t1_p2_rt_ms=r["t1_p2_rt_ms"],
                t2_p1_rt_ms=r["t2_p1_rt_ms"], t2_p2_rt_ms=r["t2_p2_rt_ms"],
                t1_p1_rt_raw_ms=r["t1_p1_rt_raw_ms"], t1_p2_rt_raw_ms=r["t1_p2_rt_raw_ms"],
                t2_p1_rt_raw_ms=r["t2_p1_rt_raw_ms"], t2_p2_rt_raw_ms=r["t2_p2_rt_raw_ms"],
                t1_p1_client_rt_ms=r["t1_p1_client_rt_ms"], t1_p2_client_rt_ms=r["t1_p2_client_rt_ms"],
                t2_p1_client_rt_ms=r["t2_p1_client_rt_ms"], t2_p2_client_rt_ms=r["t2_p2_client_rt_ms"],
                t1_p1_rtt_ms=r["t1_p1_rtt_ms"], t1_p2_rtt_ms=r["t1_p2_rtt_ms"],
                t2_p1_rtt_ms=r["t2_p1_rtt_ms"], t2_p2_rtt_ms=r["t2_p2_rtt_ms"],
                t1_p1_pre_click=r["t1_p1_pre_click"], t1_p2_pre_click=r["t1_p2_pre_click"],
                t2_p1_pre_click=r["t2_p1_pre_click"], t2_p2_pre_click=r["t2_p2_pre_click"],
                t1_p1_click_duration_ms=r["t1_p1_click_duration_ms"], t1_p2_click_duration_ms=r["t1_p2_click_duration_ms"],
                t2_p1_click_duration_ms=r["t2_p1_click_duration_ms"], t2_p2_click_duration_ms=r["t2_p2_click_duration_ms"],
                t1_p1_mouse_distance_5s_px=r["t1_p1_mouse_distance_5s_px"], t1_p2_mouse_distance_5s_px=r["t1_p2_mouse_distance_5s_px"],
                t2_p1_mouse_distance_5s_px=r["t2_p1_mouse_distance_5s_px"], t2_p2_mouse_distance_5s_px=r["t2_p2_mouse_distance_5s_px"],
                t1_p1_time_since_mouse_move_ms=r["t1_p1_time_since_mouse_move_ms"], t1_p2_time_since_mouse_move_ms=r["t1_p2_time_since_mouse_move_ms"],
                t2_p1_time_since_mouse_move_ms=r["t2_p1_time_since_mouse_move_ms"], t2_p2_time_since_mouse_move_ms=r["t2_p2_time_since_mouse_move_ms"],
                t1_p1_window_focused=r["t1_p1_window_focused"], t1_p2_window_focused=r["t1_p2_window_focused"],
                t2_p1_window_focused=r["t2_p1_window_focused"], t2_p2_window_focused=r["t2_p2_window_focused"],
                t1_p1_click_pos_x=r["t1_p1_click_pos_x"], t1_p1_click_pos_y=r["t1_p1_click_pos_y"],
                t1_p2_click_pos_x=r["t1_p2_click_pos_x"], t1_p2_click_pos_y=r["t1_p2_click_pos_y"],
                t2_p1_click_pos_x=r["t2_p1_click_pos_x"], t2_p1_click_pos_y=r["t2_p1_click_pos_y"],
                t2_p2_click_pos_x=r["t2_p2_click_pos_x"], t2_p2_click_pos_y=r["t2_p2_click_pos_y"],
                t1_p1_pre_click_displacement_px=r["t1_p1_pre_click_displacement_px"], t1_p2_pre_click_displacement_px=r["t1_p2_pre_click_displacement_px"],
                t2_p1_pre_click_displacement_px=r["t2_p1_pre_click_displacement_px"], t2_p2_pre_click_displacement_px=r["t2_p2_pre_click_displacement_px"],
                t1_combined_ms=r["t1_combined_ms"],
                t2_combined_ms=r["t2_combined_ms"],
                winner_team=r["winner_team"],
            ))
        await session.commit()
        print(f"[DB] Wrote team match {match.match_id} with {len(match.round_log)} rounds")


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


async def start_team_rematch(session: TeamRematchSession) -> None:
    await asyncio.sleep(1.0)
    for p in session.all_players:
        p.wins = 0
    match = TeamGameMatch(
        match_id=str(uuid.uuid4())[:12],
        t1=session.t1,
        t2=session.t2,
    )
    asyncio.create_task(run_team_match(match))


async def run_ffa_round(match: FFAGame) -> int:
    """Run one FFA round. Returns winner slot (0-n) or -1 for no-contest."""
    n = len(match.players)
    PRE_CLICK_PENALTY_MS = 350.0
    MISSED_CLICK_PENALTY_MS = 5000.0

    for p in match.players:
        p.click_received_us = None
        p.client_reported_rt_ms = None
        p.pre_clicked = False
        p.click_duration_ms = None
        p.click_pos_x = None
        p.click_pos_y = None
        p.pre_click_displacement_px = None
        p.ready = False

    delay_s = random.uniform(MIN_DELAY_S, MAX_DELAY_S)
    if match.round_num == 1:
        delay_s += 4.0

    for p in match.players:
        await safe_send(p.websocket, {"type": "ffa_round_prepare", "round_num": match.round_num})

    await asyncio.sleep(delay_s)

    t_stimulus = now_us()
    ping_id = match.round_num
    stimulus_msg = {"type": "stimulus", "server_time_us": t_stimulus}
    ping_msg = {"type": "ping", "ping_id": ping_id, "server_time_us": t_stimulus}
    await asyncio.gather(*[safe_send(p.websocket, stimulus_msg) for p in match.players])
    await asyncio.gather(*[safe_send(p.websocket, ping_msg) for p in match.players])

    deadline = t_stimulus + 3_000_000
    while not all(p.click_received_us is not None for p in match.players):
        if now_us() > deadline:
            break
        await asyncio.sleep(0.005)

    async def _update_latency(player: Player) -> None:
        try:
            while True:
                pong_msg, t_arrived = await asyncio.wait_for(
                    player.pong_queue.get(), timeout=ROUND_PING_TIMEOUT_S
                )
                if pong_msg.get("ping_id") == ping_id:
                    measured = (t_arrived - t_stimulus) / 2000.0
                    if player.one_way_latency_ms == 0.0:
                        player.one_way_latency_ms = measured
                    else:
                        player.one_way_latency_ms = 0.3 * measured + 0.7 * player.one_way_latency_ms
                    break
        except asyncio.TimeoutError:
            pass

    await asyncio.gather(*[_update_latency(p) for p in match.players])
    await asyncio.sleep(0.25)

    def _raw(p: Player) -> Optional[float]:
        return None if p.click_received_us is None else (p.click_received_us - t_stimulus) / 1000.0

    def _eff_rt(p: Player) -> float:
        if p.pre_clicked:
            return PRE_CLICK_PENALTY_MS
        rt = p.client_reported_rt_ms
        return rt if rt is not None else MISSED_CLICK_PENALTY_MS

    def _display_rt(p: Player) -> Optional[float]:
        if p.pre_clicked or p.click_received_us is None:
            return None
        return p.client_reported_rt_ms

    eff_rts = [_eff_rt(p) for p in match.players]
    display_rts = [_display_rt(p) for p in match.players]
    raw_rts = [_raw(p) for p in match.players]

    min_eff = min(eff_rts)
    # Multiple players with the same effective RT → no-contest
    if eff_rts.count(min_eff) > 1 or min_eff >= MISSED_CLICK_PENALTY_MS:
        winner_slot = -1
    else:
        winner_slot = eff_rts.index(min_eff)
        match.scores[winner_slot] += 1

    match.round_log.append({
        "round_num": match.round_num,
        "t_stimulus_us": t_stimulus,
        "delay_s": round(delay_s, 3),
        "rt_ms": display_rts,
        "rt_raw_ms": raw_rts,
        "pre_click": [p.pre_clicked for p in match.players],
        "rtt_ms": [round(p.one_way_latency_ms * 2, 3) for p in match.players],
        "winner_slot": winner_slot,
    })

    print(
        f"[FFA ROUND {match.round_num}] "
        + "  ".join(f"{match.players[i].username}={eff_rts[i]:.0f}ms" for i in range(n))
        + f"  -> slot{winner_slot}"
    )

    for slot, p in enumerate(match.players):
        await safe_send(p.websocket, {
            "type": "ffa_round_result",
            "round_num": match.round_num,
            "your_slot": slot,
            "rt_ms": display_rts,
            "pre_click": [p.pre_clicked for p in match.players],
            "winner_slot": winner_slot,
            "scores": list(match.scores),
        })

    if max(match.scores) >= ROUNDS_TO_WIN:
        return winner_slot

    for p in match.players:
        p.ready = False
    ready_deadline = now_us() + 5_000_000
    while not all(p.ready for p in match.players):
        if now_us() > ready_deadline:
            break
        await asyncio.sleep(0.01)

    return winner_slot


async def run_ffa_match(match: FFAGame) -> None:
    n = len(match.players)
    for p in match.players:
        player_to_ffa_match[p.player_id] = match.match_id
    active_ffa_matches[match.match_id] = match

    for slot, p in enumerate(match.players):
        await safe_send(p.websocket, {
            "type": "ffa_match_start",
            "match_id": match.match_id,
            "your_slot": slot,
            "players": [{"player_id": q.player_id, "username": q.username} for q in match.players],
            "rounds_to_win": ROUNDS_TO_WIN,
            "is_auditory": match.is_auditory,
        })

    try:
        while max(match.scores) < ROUNDS_TO_WIN:
            match.round_num += 1
            ws = await run_ffa_round(match)
            if ws == -1:
                match.inactive_rounds += 1
                if match.inactive_rounds >= MAX_INACTIVE_ROUNDS:
                    print(f"[FFA MATCH] Abandoning {match.match_id}: too many inactive rounds")
                    break
            else:
                match.inactive_rounds = 0

        # Compute placements: sort by score descending
        order = sorted(range(n), key=lambda i: match.scores[i], reverse=True)
        placements = [0] * n
        place = 1
        i = 0
        while i < n:
            j = i
            while j < n and match.scores[order[j]] == match.scores[order[i]]:
                j += 1
            for k in range(i, j):
                placements[order[k]] = place
            place += j
            i = j

        winner_slot = placements.index(1)
        print(
            f"[FFA MATCH] Ended {match.match_id}: "
            + "  ".join(f"{match.players[i].username}={match.scores[i]}(#{placements[i]})" for i in range(n))
        )

        for slot, p in enumerate(match.players):
            await safe_send(p.websocket, {
                "type": "ffa_match_end",
                "your_slot": slot,
                "placements": placements,
                "scores": list(match.scores),
                "players": [{"player_id": q.player_id, "username": q.username} for q in match.players],
                "winner_slot": winner_slot,
            })

        frsid = str(uuid.uuid4())[:12]
        frs = FFARematchSession(session_id=frsid, players=list(match.players))
        ffa_rematch_sessions[frsid] = frs
        for p in match.players:
            player_to_ffa_rematch[p.player_id] = frsid
        print(f"[FFA REMATCH] Session {frsid} open")
    finally:
        try:
            await persist_ffa_match(match)
        except Exception as e:
            print(f"[DB ERROR] Failed to persist FFA match {match.match_id}: {e}")
        active_ffa_matches.pop(match.match_id, None)
        for p in match.players:
            player_to_ffa_match.pop(p.player_id, None)


async def persist_ffa_match(match: FFAGame) -> None:
    if len(match.players) != 4:
        return  # private FFA with non-4 players not persisted
    print(f"[DB] Persisting FFA match {match.match_id}, rounds={len(match.round_log)}")
    n = len(match.players)
    order = sorted(range(n), key=lambda i: match.scores[i], reverse=True)
    placements = [0] * n
    place = 1
    i = 0
    while i < n:
        j = i
        while j < n and match.scores[order[j]] == match.scores[order[i]]:
            j += 1
        for k in range(i, j):
            placements[order[k]] = place
        place += j
        i = j
    winner_slot = placements.index(1)
    async with AsyncSessionLocal() as session:
        session.add(FFAMatchRow(
            id=match.match_id,
            p1_id=match.players[0].player_id, p2_id=match.players[1].player_id,
            p3_id=match.players[2].player_id, p4_id=match.players[3].player_id,
            p1_username=match.players[0].username, p2_username=match.players[1].username,
            p3_username=match.players[2].username, p4_username=match.players[3].username,
            p1_score=match.scores[0], p2_score=match.scores[1],
            p3_score=match.scores[2], p4_score=match.scores[3],
            p1_placement=placements[0], p2_placement=placements[1],
            p3_placement=placements[2], p4_placement=placements[3],
            winner_id=match.players[winner_slot].player_id,
            is_auditory=match.is_auditory,
        ))
        for r in match.round_log:
            rt = r["rt_ms"]
            rr = r["rt_raw_ms"]
            pc = r["pre_click"]
            rtt = r["rtt_ms"]
            session.add(FFARoundRow(
                match_id=match.match_id,
                round_num=r["round_num"],
                t_stimulus_us=r["t_stimulus_us"],
                delay_s=r["delay_s"],
                p1_rt_ms=rt[0] if len(rt) > 0 else None,
                p2_rt_ms=rt[1] if len(rt) > 1 else None,
                p3_rt_ms=rt[2] if len(rt) > 2 else None,
                p4_rt_ms=rt[3] if len(rt) > 3 else None,
                p1_rt_raw_ms=rr[0] if len(rr) > 0 else None,
                p2_rt_raw_ms=rr[1] if len(rr) > 1 else None,
                p3_rt_raw_ms=rr[2] if len(rr) > 2 else None,
                p4_rt_raw_ms=rr[3] if len(rr) > 3 else None,
                p1_pre_click=pc[0] if len(pc) > 0 else False,
                p2_pre_click=pc[1] if len(pc) > 1 else False,
                p3_pre_click=pc[2] if len(pc) > 2 else False,
                p4_pre_click=pc[3] if len(pc) > 3 else False,
                p1_rtt_ms=rtt[0] if len(rtt) > 0 else None,
                p2_rtt_ms=rtt[1] if len(rtt) > 1 else None,
                p3_rtt_ms=rtt[2] if len(rtt) > 2 else None,
                p4_rtt_ms=rtt[3] if len(rtt) > 3 else None,
                winner_slot=r["winner_slot"] if r["winner_slot"] >= 0 else 0,
            ))
        await session.commit()
        print(f"[DB] Wrote FFA match {match.match_id} with {len(match.round_log)} rounds")


async def start_ffa_rematch(session: FFARematchSession) -> None:
    await asyncio.sleep(1.0)
    for p in session.players:
        p.wins = 0
    match = FFAGame(match_id=str(uuid.uuid4())[:12], players=list(session.players))
    asyncio.create_task(run_ffa_match(match))


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
            "is_auditory": match.is_auditory,
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
    p1.click_pos_x = None; p2.click_pos_x = None
    p1.click_pos_y = None; p2.click_pos_y = None
    p1.pre_click_displacement_px = None; p2.pre_click_displacement_px = None

    delay_s = random.uniform(MIN_DELAY_S, MAX_DELAY_S)
    if match.round_num == 1:
        # Client spends 2s on the matchmaking screen, then shows a 2s intro overlay,
        # then waits an additional 2s. Total client overhead = 6s from round_prepare.
        delay_s += 4.0

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
                    measured = (t_arrived - t_stimulus) / 2000.0
                    if player.one_way_latency_ms == 0.0:
                        player.one_way_latency_ms = measured
                    else:
                        player.one_way_latency_ms = 0.3 * measured + 0.7 * player.one_way_latency_ms
                    break
                # stale pong from a previous round — discard and keep waiting
        except asyncio.TimeoutError:
            pass  # keep last known value

    await asyncio.gather(_update_latency(p1), _update_latency(p2))

    # Give click_info (mouseup) messages time to arrive before logging.
    # click is sent on mousedown; click_info is sent on mouseup (~50-150ms later).
    # Without this wait the round is logged before mouseup arrives → null duration.
    await asyncio.sleep(0.25)

    # Raw server-measured RT (network latency included).
    def _raw(p: Player) -> Optional[float]:
        return None if p.click_received_us is None else (p.click_received_us - t_stimulus) / 1000.0

    p1_raw = _raw(p1)
    p2_raw = _raw(p2)

    def _compensated(p: Player, _: Optional[float]) -> Optional[float]:
        return p.client_reported_rt_ms  # client-reported RT (testing only)

    p1_compensated = _compensated(p1, p1_raw)
    p2_compensated = _compensated(p2, p2_raw)

    p1_eff = p1_compensated
    p2_eff = p2_compensated

    def is_valid(p: Player, rt: Optional[float]) -> bool:
        return not p.pre_clicked and rt is not None

    p1_ok, p2_ok = is_valid(p1, p1_eff), is_valid(p2, p2_eff)

    # Cheat detection: click held shorter than a human physically can (~10 ms)
    p1_cheat = p1.click_duration_ms is not None and p1.click_duration_ms < CHEAT_DURATION_MS
    p2_cheat = p2.click_duration_ms is not None and p2.click_duration_ms < CHEAT_DURATION_MS

    if p1_cheat or p2_cheat:
        if p1_cheat and p2_cheat:
            round_winner = None
        elif p1_cheat:
            round_winner = p2 if p2_ok else None
        else:
            round_winner = p1 if p1_ok else None
    else:
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
        "p1_cheat_flag": p1_cheat,
        "p2_cheat_flag": p2_cheat,
        "p1_mouse_distance_5s_px": p1.mouse_distance_5s_px,
        "p2_mouse_distance_5s_px": p2.mouse_distance_5s_px,
        "p1_time_since_mouse_move_ms": p1.time_since_mouse_move_ms,
        "p2_time_since_mouse_move_ms": p2.time_since_mouse_move_ms,
        "p1_window_focused": p1.window_focused,
        "p2_window_focused": p2.window_focused,
        "p1_click_pos_x": p1.click_pos_x,
        "p1_click_pos_y": p1.click_pos_y,
        "p2_click_pos_x": p2.click_pos_x,
        "p2_click_pos_y": p2.click_pos_y,
        "p1_pre_click_displacement_px": p1.pre_click_displacement_px,
        "p2_pre_click_displacement_px": p2.pre_click_displacement_px,
    })

    for p, opp in [(p1, p2), (p2, p1)]:
        p_cheat   = p1_cheat if p is p1 else p2_cheat
        opp_cheat = p2_cheat if p is p1 else p1_cheat
        p_rt      = p1_eff   if p is p1 else p2_eff
        opp_rt    = p2_eff   if p is p1 else p1_eff
        await safe_send(p.websocket, {
            "type": "round_result",
            "round_num": match.round_num,
            "your_rt_ms": p_rt,
            "opponent_rt_ms": opp_rt,
            "opponent_pre_click": opp.pre_clicked,
            "you_won_round": round_winner is p,
            "you_cheated": p_cheat,
            "opponent_cheated": opp_cheat,
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


def _generate_lobby_code() -> str:
    for _ in range(20):
        code = "".join(random.choices("0123456789", k=6))
        if code not in private_lobbies:
            return code
    raise RuntimeError("Could not generate unique lobby code")


def _private_lobby_state(lobby: PrivateLobby) -> dict:
    return {
        "code": lobby.code,
        "leader_id": lobby.leader_id,
        "players": [{"id": p.player_id, "username": p.username} for p in lobby.players],
        "mode": lobby.gamemode,
        "cue": lobby.cue,
    }


async def _broadcast_private_lobby(lobby: PrivateLobby) -> None:
    msg = {"type": "private_lobby_update", **_private_lobby_state(lobby)}
    await asyncio.gather(*[safe_send(p.websocket, msg) for p in lobby.players])


async def _leave_private_lobby(player: Player) -> None:
    code = player_to_private_lobby.pop(player.player_id, None)
    if not code:
        return
    lobby = private_lobbies.get(code)
    if not lobby:
        return
    if player in lobby.players:
        lobby.players.remove(player)
    if not lobby.players:
        private_lobbies.pop(code, None)
        return
    # Transfer leadership if leader left
    if lobby.leader_id == player.player_id:
        lobby.leader_id = lobby.players[0].player_id
    await _broadcast_private_lobby(lobby)


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

            elif mtype == "team_quickplay":
                await ensure_player_row(player.player_id, player.username)
                print(f"[QUEUE] {player.username} ({player.player_id}) joined 2v2")
                team_match = await lobby.team_quickplay_join(player)
                if team_match is None:
                    await safe_send(websocket, {"type": "queued", "mode": "team"})
                    needed = max(0, 4 - len(lobby.team_queue))
                    qmsg = {"type": "queue_update", "mode": "team", "needed": needed}
                    await asyncio.gather(*[safe_send(p.websocket, qmsg) for p in lobby.team_queue])
                else:
                    asyncio.create_task(run_team_match(team_match))

            elif mtype == "ffa_quickplay":
                await ensure_player_row(player.player_id, player.username)
                print(f"[QUEUE] {player.username} ({player.player_id}) joined FFA")
                ffa_match = await lobby.ffa_quickplay_join(player)
                if ffa_match is None:
                    await safe_send(websocket, {"type": "queued", "mode": "ffa"})
                    needed = max(0, 4 - len(lobby.ffa_queue))
                    qmsg = {"type": "queue_update", "mode": "ffa", "needed": needed}
                    await asyncio.gather(*[safe_send(p.websocket, qmsg) for p in lobby.ffa_queue])
                else:
                    asyncio.create_task(run_ffa_match(ffa_match))

            elif mtype == "quickplay":
                await ensure_player_row(player.player_id, player.username)
                print(f"[QUEUE] {player.username} ({player.player_id}) joined ranked")
                match = await lobby.quickplay_join(player)
                if match is None:
                    await safe_send(websocket, {"type": "queued", "mode": "ranked"})
                else:
                    asyncio.create_task(run_match(match))

            elif mtype == "auditory_quickplay":
                await ensure_player_row(player.player_id, player.username)
                print(f"[QUEUE] {player.username} ({player.player_id}) joined auditory 1v1")
                match = await lobby.auditory_quickplay_join(player)
                if match is None:
                    await safe_send(websocket, {"type": "queued", "mode": "auditory"})
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

            elif mtype == "private_create":
                await ensure_player_row(player.player_id, player.username)
                await _leave_private_lobby(player)
                code = _generate_lobby_code()
                lobby_obj = PrivateLobby(code=code, leader_id=player.player_id, players=[player])
                private_lobbies[code] = lobby_obj
                player_to_private_lobby[player.player_id] = code
                await safe_send(player.websocket, {
                    "type": "private_lobby_created",
                    "code": code,
                    **_private_lobby_state(lobby_obj),
                })

            elif mtype == "private_join":
                code = str(msg.get("code", "")).strip()
                lobby_obj = private_lobbies.get(code)
                if not lobby_obj:
                    await safe_send(player.websocket, {"type": "private_join_error", "reason": "Invalid room code"})
                elif any(p.player_id == player.player_id for p in lobby_obj.players):
                    await safe_send(player.websocket, {"type": "private_join_error", "reason": "Already in lobby"})
                elif len(lobby_obj.players) >= 8:
                    await safe_send(player.websocket, {"type": "private_join_error", "reason": "Lobby is full"})
                else:
                    await ensure_player_row(player.player_id, player.username)
                    await _leave_private_lobby(player)
                    lobby_obj.players.append(player)
                    player_to_private_lobby[player.player_id] = code
                    await _broadcast_private_lobby(lobby_obj)

            elif mtype == "private_kick":
                target_id = str(msg.get("player_id", ""))
                code = player_to_private_lobby.get(player.player_id)
                lobby_obj = private_lobbies.get(code) if code else None
                if lobby_obj and lobby_obj.leader_id == player.player_id:
                    target = next((p for p in lobby_obj.players if p.player_id == target_id), None)
                    if target and target.player_id != player.player_id:
                        lobby_obj.players.remove(target)
                        player_to_private_lobby.pop(target.player_id, None)
                        await safe_send(target.websocket, {"type": "private_kicked"})
                        await _broadcast_private_lobby(lobby_obj)

            elif mtype == "private_set_mode":
                mode = str(msg.get("mode", "1v1"))
                if mode not in ("1v1", "2v2", "ffa"):
                    mode = "1v1"
                code = player_to_private_lobby.get(player.player_id)
                lobby_obj = private_lobbies.get(code) if code else None
                if lobby_obj and lobby_obj.leader_id == player.player_id:
                    lobby_obj.gamemode = mode
                    await _broadcast_private_lobby(lobby_obj)

            elif mtype == "private_set_cue":
                cue = str(msg.get("cue", "visual"))
                if cue not in ("visual", "auditory"):
                    cue = "visual"
                code = player_to_private_lobby.get(player.player_id)
                lobby_obj = private_lobbies.get(code) if code else None
                if lobby_obj and lobby_obj.leader_id == player.player_id:
                    lobby_obj.cue = cue
                    await _broadcast_private_lobby(lobby_obj)

            elif mtype == "private_leave":
                await _leave_private_lobby(player)
                await safe_send(player.websocket, {"type": "private_left"})

            elif mtype == "private_start":
                code = player_to_private_lobby.get(player.player_id)
                lobby_obj = private_lobbies.get(code) if code else None
                if not lobby_obj or lobby_obj.leader_id != player.player_id:
                    pass
                else:
                    n = len(lobby_obj.players)
                    mode = lobby_obj.gamemode
                    valid = (mode == "1v1" and n == 2) or (mode == "2v2" and n == 4) or (mode == "ffa" and 3 <= n <= 8)
                    if valid:
                        # Remove all players from private lobby state before starting game
                        for p in lobby_obj.players:
                            player_to_private_lobby.pop(p.player_id, None)
                        private_lobbies.pop(code, None)
                        players = lobby_obj.players
                        is_aud = (lobby_obj.cue == "auditory")
                        if mode == "1v1":
                            m = Match(match_id=str(uuid.uuid4())[:12], p1=players[0], p2=players[1], mode="private", is_auditory=is_aud)
                            asyncio.create_task(run_match(m))
                        elif mode == "2v2":
                            tm = TeamGameMatch(
                                match_id=str(uuid.uuid4())[:12],
                                t1=[players[0], players[1]],
                                t2=[players[2], players[3]],
                                is_auditory=is_aud,
                            )
                            asyncio.create_task(run_team_match(tm))
                        elif mode == "ffa":
                            fm = FFAGame(match_id=str(uuid.uuid4())[:12], players=players, is_private=True, is_auditory=is_aud)
                            asyncio.create_task(run_ffa_match(fm))

            elif mtype == "cancel_queue":
                await lobby.quickplay_leave(player)
                await lobby.auditory_quickplay_leave(player)
                await lobby.practice_leave(player)
                await lobby.team_quickplay_leave(player)
                await lobby.ffa_quickplay_leave(player)
                await _leave_private_lobby(player)
                if lobby.team_queue:
                    needed = max(0, 4 - len(lobby.team_queue))
                    qmsg = {"type": "queue_update", "mode": "team", "needed": needed}
                    await asyncio.gather(*[safe_send(p.websocket, qmsg) for p in lobby.team_queue])
                if lobby.ffa_queue:
                    needed = max(0, 4 - len(lobby.ffa_queue))
                    qmsg = {"type": "queue_update", "mode": "ffa", "needed": needed}
                    await asyncio.gather(*[safe_send(p.websocket, qmsg) for p in lobby.ffa_queue])
                await safe_send(websocket, {"type": "cancelled"})

            elif mtype == "rematch_vote":
                rsid = player_to_rematch.get(player.player_id)
                rs = rematch_sessions.get(rsid) if rsid else None
                trsid = player_to_team_rematch.get(player.player_id)
                trs = team_rematch_sessions.get(trsid) if trsid else None
                frsid = player_to_ffa_rematch.get(player.player_id)
                frs = ffa_rematch_sessions.get(frsid) if frsid else None
                if frs is not None:
                    frs.votes.add(player.player_id)
                    for p in frs.players:
                        await safe_send(p.websocket, {"type": "rematch_status", "votes": len(frs.votes)})
                    if len(frs.votes) == 4:
                        ffa_rematch_sessions.pop(frsid, None)
                        for p in frs.players:
                            player_to_ffa_rematch.pop(p.player_id, None)
                            await safe_send(p.websocket, {"type": "rematch_go"})
                        print(f"[FFA REMATCH] All voted — starting")
                        asyncio.create_task(start_ffa_rematch(frs))
                elif rs is not None:
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
                elif trs is not None:
                    trs.votes.add(player.player_id)
                    for p in trs.all_players:
                        await safe_send(p.websocket, {"type": "rematch_status", "votes": len(trs.votes)})
                    if len(trs.votes) == 4:
                        team_rematch_sessions.pop(trsid, None)
                        for p in trs.all_players:
                            player_to_team_rematch.pop(p.player_id, None)
                            await safe_send(p.websocket, {"type": "rematch_go"})
                        print(f"[TEAM REMATCH] All voted — starting {trs.t1[0].username}/{trs.t1[1].username} vs {trs.t2[0].username}/{trs.t2[1].username}")
                        asyncio.create_task(start_team_rematch(trs))

            elif mtype == "rematch_cancel":
                rsid = player_to_rematch.pop(player.player_id, None)
                rs = rematch_sessions.pop(rsid, None) if rsid else None
                trsid = player_to_team_rematch.pop(player.player_id, None)
                trs = team_rematch_sessions.pop(trsid, None) if trsid else None
                frsid = player_to_ffa_rematch.pop(player.player_id, None)
                frs = ffa_rematch_sessions.pop(frsid, None) if frsid else None
                if rs is not None:
                    partner = rs.p2 if rs.p1.player_id == player.player_id else rs.p1
                    player_to_rematch.pop(partner.player_id, None)
                    await safe_send(partner.websocket, {"type": "opponent_left"})
                    print(f"[REMATCH] {player.username} cancelled — notified {partner.username}")
                elif trs is not None:
                    for p in trs.all_players:
                        if p.player_id != player.player_id:
                            player_to_team_rematch.pop(p.player_id, None)
                            await safe_send(p.websocket, {"type": "opponent_left"})
                    print(f"[TEAM REMATCH] {player.username} cancelled")
                elif frs is not None:
                    for p in frs.players:
                        if p.player_id != player.player_id:
                            player_to_ffa_rematch.pop(p.player_id, None)
                            await safe_send(p.websocket, {"type": "opponent_left"})
                    print(f"[FFA REMATCH] {player.username} cancelled")

            elif mtype == "client_info":
                player.platform = (msg.get("platform") or "unknown")[:16]
                player.screen_refresh_hz = msg.get("screen_refresh_hz")
                player.screen_resolution = (msg.get("screen_resolution") or "")[:16]
                player.client_version = (msg.get("client_version") or "")[:16]

            elif mtype == "click_info":
                # Sent on mouseup after a click; attaches click_duration to the current round
                player.click_duration_ms = msg.get("click_duration_ms")

            elif mtype == "click":
                # 1v1 routing
                match_id = player_to_match.get(player.player_id)
                if match_id:
                    m = active_matches.get(match_id)
                    if m:
                        target = m.p1 if m.p1.player_id == player.player_id else m.p2
                        if target.click_received_us is None:
                            target.click_received_us = t_received
                            target.client_reported_rt_ms = msg.get("client_rt_ms")
                            target.pre_clicked = bool(msg.get("pre_click", False))
                            target.mouse_distance_5s_px = msg.get("mouse_distance_5s_px")
                            target.time_since_mouse_move_ms = msg.get("time_since_mouse_move_ms")
                            target.window_focused = msg.get("window_focused")
                            target.click_pos_x = msg.get("click_pos_x")
                            target.click_pos_y = msg.get("click_pos_y")
                            target.pre_click_displacement_px = msg.get("pre_click_displacement_px")
                            opponent = m.p2 if target is m.p1 else m.p1
                            await safe_send(opponent.websocket, {
                                "type": "opponent_clicked",
                                "pre_click": target.pre_clicked,
                            })
                # 2v2 routing
                team_mid = player_to_team_match.get(player.player_id)
                if team_mid:
                    tm = active_team_matches.get(team_mid)
                    if tm:
                        for t_num, team in [(1, tm.t1), (2, tm.t2)]:
                            for slot, tp in enumerate(team):
                                if tp.player_id == player.player_id and tp.click_received_us is None:
                                    tp.click_received_us = t_received
                                    tp.client_reported_rt_ms = msg.get("client_rt_ms")
                                    tp.pre_clicked = bool(msg.get("pre_click", False))
                                    tp.mouse_distance_5s_px = msg.get("mouse_distance_5s_px")
                                    tp.time_since_mouse_move_ms = msg.get("time_since_mouse_move_ms")
                                    tp.window_focused = msg.get("window_focused")
                                    tp.click_pos_x = msg.get("click_pos_x")
                                    tp.click_pos_y = msg.get("click_pos_y")
                                    tp.pre_click_displacement_px = msg.get("pre_click_displacement_px")
                                    for other in tm.all_players:
                                        if other.player_id != player.player_id:
                                            await safe_send(other.websocket, {
                                                "type": "team_player_clicked",
                                                "team": t_num, "slot": slot,
                                                "pre_click": tp.pre_clicked,
                                            })
                # FFA routing
                ffa_mid = player_to_ffa_match.get(player.player_id)
                if ffa_mid:
                    fm = active_ffa_matches.get(ffa_mid)
                    if fm:
                        for slot, fp in enumerate(fm.players):
                            if fp.player_id == player.player_id and fp.click_received_us is None:
                                fp.click_received_us = t_received
                                fp.client_reported_rt_ms = msg.get("client_rt_ms")
                                fp.pre_clicked = bool(msg.get("pre_click", False))
                                fp.mouse_distance_5s_px = msg.get("mouse_distance_5s_px")
                                fp.time_since_mouse_move_ms = msg.get("time_since_mouse_move_ms")
                                fp.window_focused = msg.get("window_focused")
                                fp.click_pos_x = msg.get("click_pos_x")
                                fp.click_pos_y = msg.get("click_pos_y")
                                fp.pre_click_displacement_px = msg.get("pre_click_displacement_px")
                                for other in fm.players:
                                    if other.player_id != player.player_id:
                                        await safe_send(other.websocket, {
                                            "type": "ffa_player_clicked",
                                            "slot": slot,
                                            "pre_click": fp.pre_clicked,
                                        })
                                break

            elif mtype == "ready_up":
                match_id = player_to_match.get(player.player_id)
                if match_id:
                    m = active_matches.get(match_id)
                    if m:
                        (m.p1 if m.p1.player_id == player.player_id else m.p2).ready = True
                team_mid = player_to_team_match.get(player.player_id)
                if team_mid:
                    tm = active_team_matches.get(team_mid)
                    if tm:
                        for p in tm.all_players:
                            if p.player_id == player.player_id:
                                p.ready = True
                                break
                ffa_mid = player_to_ffa_match.get(player.player_id)
                if ffa_mid:
                    fm = active_ffa_matches.get(ffa_mid)
                    if fm:
                        for p in fm.players:
                            if p.player_id == player.player_id:
                                p.ready = True
                                break

            elif mtype == "calibration_click":
                rt_ms = msg.get("rt_ms")
                side = msg.get("side", "unknown")
                if rt_ms is not None and 50.0 <= float(rt_ms) <= 2000.0:
                    asyncio.create_task(save_calibration(player, float(rt_ms), side))

            elif mtype == "recent_matches_request":
                pid = msg.get("player_id") or None
                filter_type = msg.get("match_type", "all")
                try:
                    matches = await fetch_recent_matches(player_id=pid, match_type=filter_type)
                except Exception as e:
                    print(f"[RECENT_MATCHES] Query failed: {e}")
                    matches = []
                await safe_send(websocket, {
                    "type": "recent_matches_data",
                    "player_id": pid or "",
                    "matches": matches,
                })

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
        await lobby.auditory_quickplay_leave(player)
        await lobby.practice_leave(player)
        await lobby.team_quickplay_leave(player)
        await lobby.ffa_quickplay_leave(player)
        if lobby.team_queue:
            needed = max(0, 4 - len(lobby.team_queue))
            qmsg = {"type": "queue_update", "mode": "team", "needed": needed}
            await asyncio.gather(*[safe_send(p.websocket, qmsg) for p in lobby.team_queue])
        if lobby.ffa_queue:
            needed = max(0, 4 - len(lobby.ffa_queue))
            qmsg = {"type": "queue_update", "mode": "ffa", "needed": needed}
            await asyncio.gather(*[safe_send(p.websocket, qmsg) for p in lobby.ffa_queue])
        await _leave_private_lobby(player)
        rsid = player_to_rematch.pop(player.player_id, None)
        rs = rematch_sessions.pop(rsid, None) if rsid else None
        if rs is not None:
            partner = rs.p2 if rs.p1.player_id == player.player_id else rs.p1
            player_to_rematch.pop(partner.player_id, None)
            await safe_send(partner.websocket, {"type": "opponent_left"})
        trsid = player_to_team_rematch.pop(player.player_id, None)
        trs = team_rematch_sessions.pop(trsid, None) if trsid else None
        if trs is not None:
            for p in trs.all_players:
                if p.player_id != player.player_id:
                    player_to_team_rematch.pop(p.player_id, None)
                    await safe_send(p.websocket, {"type": "opponent_left"})
        frsid = player_to_ffa_rematch.pop(player.player_id, None)
        frs = ffa_rematch_sessions.pop(frsid, None) if frsid else None
        if frs is not None:
            for p in frs.players:
                if p.player_id != player.player_id:
                    player_to_ffa_rematch.pop(p.player_id, None)
                    await safe_send(p.websocket, {"type": "opponent_left"})
        team_mid = player_to_team_match.get(player.player_id)
        if team_mid:
            tm = active_team_matches.get(team_mid)
            if tm:
                for other in tm.all_players:
                    if other.player_id != player.player_id:
                        await safe_send(other.websocket, {"type": "opponent_left"})
        ffa_mid = player_to_ffa_match.get(player.player_id)
        if ffa_mid:
            fm = active_ffa_matches.get(ffa_mid)
            if fm:
                for other in fm.players:
                    if other.player_id != player.player_id:
                        await safe_send(other.websocket, {"type": "opponent_left"})


@app.get("/health")
async def health_detail() -> dict:
    return {
        "status": "ok",
        "quickplay_queue": len(lobby.quickplay_queue),
        "practice_queue": len(lobby.practice_queue),
        "team_queue": len(lobby.team_queue),
        "private_lobbies": len(private_lobbies),
        "active_matches": len(active_matches),
        "active_team_matches": len(active_team_matches),
        "ffa_queue": len(lobby.ffa_queue),
        "active_ffa_matches": len(active_ffa_matches),
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="127.0.0.1", port=8000, reload=True)
