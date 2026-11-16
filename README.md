# Project Zomboid AI Director (Build 42 MCP Bridge)

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Build 42](https://img.shields.io/badge/Project%20Zomboid-Build%2042%2B-orange.svg)](https://projectzomboid.com/)
[![MCP](https://img.shields.io/badge/MCP-1.6%2B-blue.svg)](https://modelcontextprotocol.io/)

**[Русская версия (README.ru.md)](README.ru.md)**

A **Project Zomboid Build 42 Lua Mod** + **Python MCP Server** bridge that turns any MCP-compatible AI assistant (Antigravity, Claude Desktop, Cursor) into a live **AI Game Master & Military Radio Dispatcher (`98.4 MHz`)** for solo or co-op campaigns.

## Features

- **Real DynamicRadio Channel (`98.4 MHz`)**: Registers `Extraction Command [98.4 MHz]` inside Project Zomboid's radio system (`AIDirectorRadio.lua`).
- **Two-Way Player Comms**: Players can transmit via right-click context menu (`Extraction Radio [98.4 MHz]`), tuned handheld/vehicle radios, or multiplayer chat (`@message` / `!ai message`).
- **Live Telemetry (`get_game_state`)**: Coordinates, nearest Kentucky landmark, health, infection/bites/bleeding, hunger/fatigue/panic, vehicle fuel & condition, weather, and unread player radio messages.
- **16 Real-Time Director Tools**:
  - `send_radio_transmission` — Broadcast voice/HUD radio lines in any language (`radio_and_hud` or `strict_radio`).
  - `give_starter_radios` — Equip players with tuned `98.4 MHz` military walkie-talkies.
  - `spawn_supply_drop` — Drop crates with smoke flares, ground loot, or direct inventory gifts.
  - `spawn_story_note` — Create readable `Base.Notebook` items with custom multi-page lore/clues.
  - `spawn_zombie_horde` — Spawn targeted zombie ambushes/hordes around coordinates or players.
  - `trigger_sound_or_alarm` — Distant helicopter, gunshots, screams, or building alarms.
  - `set_weather` — Dynamic storms, heavy rain, dense fog, or clear skies.
  - `spawn_vehicle` — Spawn vehicles (`good`, `wrecked`, or `random`) with optional keys.
  - `trigger_world_effect` — Fire, smoke, or explosion at coordinates.
  - `modify_player_status` — `heal_full`, `cure_infection` (Build 42 safe), `give_xp`, `calm_panic`, `induce_panic`.
  - `schedule_zone_trigger` / `remove_zone_trigger` — Deferred encounters that fire when survivors enter distant unloaded towns (`radius` 10–90).
  - `get_kentucky_landmarks` & `search_game_catalog` — Search vanilla Build 42 AND installed Workshop mod item/vehicle IDs.
  - `sync_mod_to_zomboid` — Sync mod files into `~/Zomboid/mods/ZomboidAIDirector`.

## Architecture

```
Project Zomboid (Lua, Kahlua2)                Python MCP Server (stdio)
──────────────────────────────                ─────────────────────────
~/Zomboid/Lua/AIDirector/state.json   ──────► get_game_state()
~/Zomboid/Lua/AIDirector/cmd_index.txt ◄───── send_radio_transmission(), spawn_supply_drop(), ...
~/Zomboid/Lua/AIDirector/events.jsonl  ──────► zone_trigger_fired / ack tracking
```

## Quick Start

### 1. Install the Build 42 Mod
- **From Steam Workshop**: Subscribe to **Project Zomboid AI Director (MCP Bridge)** (Workshop ID `3840209384`) and enable `ZomboidAIDirector` in Mods / Server `Mods=`.
- **Or from this repo**: Run `uv run server.py` once (it automatically copies `mod/ZomboidAIDirector/` to `~/Zomboid/mods/ZomboidAIDirector`).

### 2. Run the MCP Server
Requires Python 3.12+ and [`uv`](https://docs.astral.sh/uv/):

```bash
cd pz-ai-director
uv sync
uv run server.py
```

### 3. Connect to Your AI Client
See ready-to-use templates in [`examples/mcp_configs/`](examples/mcp_configs/):
- [`antigravity_mcp_config.json`](examples/mcp_configs/antigravity_mcp_config.json)
- [`claude_desktop_config.json`](examples/mcp_configs/claude_desktop_config.json)
- [`cursor_mcp.json`](examples/mcp_configs/cursor_mcp.json)

### Environment Variables (Optional)
- `PZ_ZOMBOID_DIR` — Override Zomboid user data folder (default: `~/Zomboid`).
- `PZ_GAME_DIR` — Override Project Zomboid Steam installation folder for `search_game_catalog`.

## Running Tests

```bash
cd pz-ai-director
uv run python -m unittest discover -s tests -v
```

## License

MIT — see [LICENSE](LICENSE).
