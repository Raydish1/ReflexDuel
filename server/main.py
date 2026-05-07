"""
ReflexDuel - Phase 2.5 server.
Quickplay queue + private rooms with codes + PostgreSQL persistence.
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

from db import AsyncSessionLocal
from models import Match as MatchRow, Player as PlayerRow, Round as RoundRow

app = FastAPI(title="ReflexDuel")
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"]
)

ROUNDS_TO_WIN = 3
MAX_INACTIVE_ROUNDS = 3
MIN_DELAY_S = 2.0
MAX_DELAY_S = 6.0
HUMAN_FLOOR_MS = 100
ROOM_CODE_CHARS = string.ascii_uppercase + string.digits
ROOM_CODE_LEN = 6


@dataclass
class Player:
    player_id: str
    username: str
    websocket: WebSocket
    wins: int = 0
    click_received_us: Optional[int] = None
    client_reported_rt_ms: Optional[float] = None
    pre_clicked: bool = False


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
        self.private_rooms: dict[str, Player] = {}
        self.lock = asyncio.Lock()

    async def quickplay_join(self, player: Player) -> Optional[Match]:
        async with self.lock:
            for queued in self.quickplay_queue:
                if queued.player_id == player.player_id:
                    return None  # already queued, ignore duplicate
            if self.quickplay_queue:
                opponent = self.quickplay_queue.pop(0)
                return Match(match_id=str(uuid.uuid4())[:12], p1=opponent, p2=player, mode="ranked")
            self.quickplay_queue.append(player)
            return None

    async def quickplay_leave(self, player: Player) -> None:
        async with self.lock:
            if player in self.quickplay_queue:
                self.quickplay_queue.remove(player)

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
    return time.monotonic_ns() // 1000


async def safe_send(ws: WebSocket, msg: dict) -> bool:
    try:
        await ws.send_json(msg)
        return True
    except Exception:
        return False


async def ensure_player_row(player_id: str, username: str) -> None:
    async with AsyncSessionLocal() as session:
        existing = await session.get(PlayerRow, player_id)
        if existing is None:
            print(f"[DB] Creating player row: {player_id} ({username})")
            session.add(PlayerRow(id=player_id, username=username))
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
        ))
        for r in match.round_log:
            session.add(RoundRow(
                match_id=match.match_id,
                round_num=r["round_num"],
                t_stimulus_us=r["t_stimulus_us"],
                delay_s=r["delay_s"],
                p1_click_us=r["p1_click_us"],
                p2_click_us=r["p2_click_us"],
                p1_server_rt_ms=r["p1_rt_ms"],
                p2_server_rt_ms=r["p2_rt_ms"],
                p1_client_rt_ms=r["p1_client_rt_ms"],
                p2_client_rt_ms=r["p2_client_rt_ms"],
                winner_id=r["winner"],
                p1_pre_click=r["p1_pre_click"],
                p2_pre_click=r["p2_pre_click"],
            ))
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

    delay_s = random.uniform(MIN_DELAY_S, MAX_DELAY_S)

    for p in (p1, p2):
        await safe_send(p.websocket, {"type": "round_prepare", "round_num": match.round_num})

    await asyncio.sleep(delay_s)

    t_stimulus = now_us()
    fire = {"type": "stimulus", "server_time_us": t_stimulus}
    await asyncio.gather(safe_send(p1.websocket, fire), safe_send(p2.websocket, fire))

    deadline = t_stimulus + 3_000_000
    while p1.click_received_us is None or p2.click_received_us is None:
        if now_us() > deadline: break
        await asyncio.sleep(0.005)

    def rt_ms(p: Player) -> Optional[float]:
        return None if p.click_received_us is None else (p.click_received_us - t_stimulus) / 1000.0

    p1_rt, p2_rt = rt_ms(p1), rt_ms(p2)

    def is_valid(p: Player, rt: Optional[float]) -> bool:
        return not p.pre_clicked and rt is not None and rt >= HUMAN_FLOOR_MS

    p1_ok, p2_ok = is_valid(p1, p1_rt), is_valid(p2, p2_rt)
    if p1_ok and p2_ok:
        round_winner = p1 if p1_rt < p2_rt else p2
    elif p1_ok: round_winner = p1
    elif p2_ok: round_winner = p2
    else: round_winner = None

    if round_winner: round_winner.wins += 1

    p1_rt_str = f"{p1_rt:.1f}" if p1_rt is not None else "—"
    p2_rt_str = f"{p2_rt:.1f}" if p2_rt is not None else "—"
    winner_name = round_winner.username if round_winner else "no-contest"
    print(f"[ROUND {match.round_num}] {match.p1.username}={p1_rt_str}ms vs {match.p2.username}={p2_rt_str}ms -> {winner_name}")

    match.round_log.append({
        "round_num": match.round_num,
        "t_stimulus_us": t_stimulus,
        "delay_s": round(delay_s, 3),
        "p1_click_us": p1.click_received_us,
        "p2_click_us": p2.click_received_us,
        "p1_rt_ms": p1_rt, "p2_rt_ms": p2_rt,
        "p1_client_rt_ms": p1.client_reported_rt_ms,
        "p2_client_rt_ms": p2.client_reported_rt_ms,
        "p1_pre_click": p1.pre_clicked,
        "p2_pre_click": p2.pre_clicked,
        "winner": round_winner.player_id if round_winner else None,
    })

    for p, opp in [(p1, p2), (p2, p1)]:
        await safe_send(p.websocket, {
            "type": "round_result",
            "round_num": match.round_num,
            "your_rt_ms": rt_ms(p),
            "opponent_rt_ms": rt_ms(opp),
            "you_won_round": round_winner is p,
            "your_score": p.wins,
            "opponent_score": opp.wins,
        })

    await asyncio.sleep(2.0)
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

            if mtype == "set_username":
                player.username = (msg.get("username") or "anon")[:32]
                await ensure_player_row(player.player_id, player.username)
                await safe_send(websocket, {"type": "username_set", "username": player.username})

            elif mtype == "quickplay":
                await ensure_player_row(player.player_id, player.username)
                print(f"[QUEUE] {player.username} ({player.player_id}) joined quickplay")
                match = await lobby.quickplay_join(player)
                if match is None:
                    await safe_send(websocket, {"type": "queued", "mode": "quickplay"})
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

    except WebSocketDisconnect:
        print(f"[WS] Disconnected: {player.player_id}")
        await lobby.quickplay_leave(player)
        await lobby.cancel_room(player)
        rsid = player_to_rematch.pop(player.player_id, None)
        rs = rematch_sessions.pop(rsid, None) if rsid else None
        if rs is not None:
            partner = rs.p2 if rs.p1.player_id == player.player_id else rs.p1
            player_to_rematch.pop(partner.player_id, None)
            await safe_send(partner.websocket, {"type": "opponent_left"})


@app.get("/health")
async def health() -> dict:
    return {
        "status": "ok",
        "quickplay_queue": len(lobby.quickplay_queue),
        "private_rooms": len(lobby.private_rooms),
        "active_matches": len(active_matches),
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="127.0.0.1", port=8000, reload=True)