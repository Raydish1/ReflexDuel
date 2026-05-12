# ReflexDuel

A 2-player real-time reaction game. Players compete to click a stimulus faster. The server measures latency-compensated reaction times and determines the winner server-side.

---

## Architecture

| Layer | Tech | Hosted |
|---|---|---|
| Client | Godot 4 (GDScript) | Exported Windows build + web export |
| Server | Python / FastAPI / WebSocket | Fly.io (`reflexduel-server`) |
| Database | PostgreSQL via SQLAlchemy + Alembic | Supabase |

```
client/ — Godot project
server/ — Python server
  main.py     — WebSocket game logic
  models.py   — SQLAlchemy ORM models
  db.py       — DB engine setup (reads DATABASE_URL env var)
  alembic/    — DB migration scripts
```

---

## Local Development

### Server

```bash
cd server
cp .env.example .env        # fill in DATABASE_URL for local postgres
uv run uvicorn main:app --reload --port 8000
```

The client auto-connects to `ws://127.0.0.1:8000/ws/play` when run from the Godot editor.

### Client

Open `client/` in Godot 4. Press **F5** to run. It connects to local server automatically (switches to production URL in exported builds).

---

## Deploying

### Server → Fly.io

Any change to `server/` requires a redeploy:

```bash
cd server
flyctl deploy
```

Monitor logs:
```bash
flyctl logs
```

Check health:
```
GET https://reflexduel-server.fly.dev/health
```

### Client → Windows Build

1. Godot → **Project > Export > Windows Desktop**
2. Replace `ReflexDuel.exe` and `ReflexDuel-web.zip` in the repo root

### Client → Web Build

1. Godot → **Project > Export > Web**
2. Replace files in `ReflexDuel-web/` (mainly `index.html` and `index.pck`)

---

## Database

### Credentials

Stored as Fly.io secrets — never committed. To view or update:
```bash
flyctl secrets list
flyctl secrets set DATABASE_URL="postgresql+asyncpg://..."
```

The Supabase direct-connection URL format:
```
postgresql+asyncpg://postgres:<password>@db.<project-ref>.supabase.co:5432/postgres
```

For Alembic (sync driver needed):
```
postgresql+psycopg2://postgres:<password>@db.<project-ref>.supabase.co:5432/postgres
```

### Running Migrations

Migrations apply schema changes to the live DB. Always run against Supabase, not locally, unless you have a local Postgres instance set up.

```bash
cd server
ALEMBIC_DATABASE_URL="postgresql+psycopg2://..." alembic upgrade head
```

To create a new migration after editing `models.py`:
```bash
alembic revision --autogenerate -m "description of change"
alembic upgrade head
```

### Schema Overview

- **players** — one row per anonymous session ID; tracks aggregate stats
- **matches** — one row per match; records mode, scores, hardware info (Hz, platform, resolution)
- **rounds** — one row per round; the unit of anti-cheat ML training data (reaction times, click duration, mouse movement, window focus, RTT)
- **calibration_rounds** — solo reaction clicks from the main menu practice boxes

### Data Utilities

**Delete all data for a specific username:**
```bash
cd server
DATABASE_URL="postgresql+asyncpg://..." python purge_player.py <username>
```

---

## Fly.io Configuration (`server/fly.toml`)

- Region: `ord` (Chicago)
- 1 machine always running (`auto_stop_machines = "off"`, `min_machines_running = 1`)
- Health check: `GET /health` every 15s
- Memory: 1 GB

---

## Game Flow

```
Client connects via WebSocket → receives player_id ("hello")
Player sets username → enters queue (quickplay / practice / private room)
Server pairs two players → runs match coroutine

Per match:
  while neither player has 3 wins:
    server sends round_prepare
    server sleeps delay_s (random 2–6s; +4s extra on round 1 for intro overlay)
    server sends stimulus + ping simultaneously
    clients report click (mousedown) and click_info (mouseup) separately
    server collects both clicks, measures RTT via pong, compensates for latency
    server logs round data → sends round_result to both players
    players ready up → next round

  server sends match_end → persists match + rounds to DB
  rematch session opened (60s window for both players to vote)
```

**Latency compensation:** `compensated_rt = raw_server_rt − (RTT / 2)`. RTT is measured each round via a ping sent simultaneously with the stimulus.

**Modes:**
- `ranked` — uses server-compensated RT for win determination
- `practice` — uses client-reported RT (unranked, not saved to leaderboard)
- `private` — same as ranked but via room code; saves to DB

---

## Key Client Files

| File | Purpose |
|---|---|
| `scripts/network.gd` | WebSocket singleton (`Net`), all send/receive logic |
| `scripts/game.gd` | In-match UI and input handling (built programmatically) |
| `scripts/main_menu.gd` | Main menu, leaderboard, username popup, profanity filter |
| `scripts/matchmaking.gd` | Queue screen |
| `scripts/results.gd` | Post-match results and rematch voting |
| `scripts/private_lobby.gd` | Create/join private room |

---

## Environment Variables

| Variable | Used by | Description |
|---|---|---|
| `DATABASE_URL` | server (`db.py`, `purge_player.py`) | asyncpg connection string |
| `ALEMBIC_DATABASE_URL` | `alembic/env.py` | psycopg2 connection string for migrations |
| `ENV` | `db.py` | `development` falls back to localhost; `production` (default) requires DATABASE_URL |
