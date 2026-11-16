from __future__ import annotations

import json
import math
import os
import re
import shutil
import struct
import time
import zlib
from pathlib import Path
from typing import Any, Literal

from mcp.server import MCPServer

# ---------------------------------------------------------------------------
# Paths & Configuration
# ---------------------------------------------------------------------------

PROJECT_ROOT = Path(__file__).resolve().parent
MOD_SOURCE_DIR = PROJECT_ROOT / "mod" / "ZomboidAIDirector"

ZOMBOID_USER_DIR = Path(os.environ.get("PZ_ZOMBOID_DIR", str(Path.home() / "Zomboid")))
IPC_DIR = ZOMBOID_USER_DIR / "Lua" / "AIDirector"
STATE_FILE = IPC_DIR / "state.json"
CMD_INDEX_FILE = IPC_DIR / "cmd_index.txt"
CURSOR_FILE = IPC_DIR / "cursor.txt"
SEEN_INBOX_FILE = IPC_DIR / "mcp_seen_inbox.json"
MOD_INSTALL_DIR = ZOMBOID_USER_DIR / "mods" / "ZomboidAIDirector"

DEFAULT_PZ_INSTALL_CANDIDATES = [
    Path(os.environ.get("PZ_GAME_DIR", "")) if os.environ.get("PZ_GAME_DIR") else None,
    Path(r"C:\Programs\Steam\steamapps\common\ProjectZomboid"),
    Path(r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid"),
    Path(r"D:\SteamLibrary\steamapps\common\ProjectZomboid"),
]

# Major Kentucky locations in Project Zomboid Build 42 (approximate centers)
KENTUCKY_LANDMARKS: list[dict[str, Any]] = [
    {"name": "Rosewood (Пожарная часть / Центр)", "x": 8115, "y": 11640, "region": "Rosewood"},
    {"name": "Rosewood (Южная заправка на трассе)", "x": 8335, "y": 12215, "region": "Rosewood"},
    {"name": "Muldraugh (Главная трасса / Склады)", "x": 10630, "y": 9750, "region": "Muldraugh"},
    {"name": "Muldraugh (Южная заправка)", "x": 10615, "y": 10630, "region": "Muldraugh"},
    {"name": "March Ridge (Военные общежития)", "x": 10050, "y": 12720, "region": "March Ridge"},
    {"name": "Riverside (Центр у реки)", "x": 6430, "y": 5320, "region": "Riverside"},
    {"name": "Brandenburg (Причал / Город B42)", "x": 2050, "y": 6150, "region": "Brandenburg"},
    {"name": "Echo Creek (Заправка / Перекрёсток B42)", "x": 3570, "y": 10910, "region": "Echo Creek"},
    {"name": "Ekron / Fallas Lake (Фермерский городок)", "x": 7270, "y": 8340, "region": "Ekron"},
    {"name": "Irvington (Юго-западный город B42)", "x": 2580, "y": 14250, "region": "Irvington"},
    {"name": "Secret Military Research Base (Секретный бункер)", "x": 5575, "y": 12485, "region": "Military Base"},
    {"name": "West Point (Центр города)", "x": 11910, "y": 6910, "region": "West Point"},
    {"name": "Valley Station (КПП карантинной зоны Луисвилля)", "x": 12525, "y": 4175, "region": "Louisville Checkpoint"},
    {"name": "Louisville — Больница Св. Перегрина (Отличная точка эвакуации)", "x": 12945, "y": 2040, "region": "Louisville South"},
    {"name": "Louisville — Центральный парк / Радиостанция LBMW", "x": 12650, "y": 1550, "region": "Louisville Central"},
    {"name": "Louisville — Северный ж/д и автодорожный мост через Огайо (Финальная эвакуация)", "x": 12595, "y": 1015, "region": "Louisville North Bridge"},
]

mcp = MCPServer(
    "pz-ai-director",
    title="Project Zomboid Build 42 AI Director",
    version="1.0.0",
    instructions=(
        "Real-time AI Game Master & Extraction Dispatcher for Project Zomboid Build 42. "
        "Always call get_game_state first to inspect player coordinates, health, vehicle fuel, weather, "
        "and unread player radio transmissions on 98.4 MHz. Use send_radio_transmission to roleplay "
        "over the radio in the players' preferred language (English, Russian, etc.), "
        "spawn_supply_drop / spawn_story_note for rewards and clues, "
        "spawn_zombie_horde / trigger_sound_or_alarm / set_weather for dramatic tension, and "
        "schedule_zone_trigger when setting up scenes at distant coordinates (>70 tiles from players)."
    ),
)


# ---------------------------------------------------------------------------
# Helpers: PNG Generation & Mod Installation
# ---------------------------------------------------------------------------


def _make_solid_png(width: int, height: int, rgb: tuple[int, int, int]) -> bytes:
    """Create a valid minimal RGB PNG image using only the Python standard library."""
    r, g, b = rgb
    raw_rows = b"".join(b"\x00" + bytes([r, g, b]) * width for _ in range(height))

    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    idat = zlib.compress(raw_rows, level=9)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


def ensure_mod_assets_and_installed(force_sync: bool = False) -> dict[str, Any]:
    """Ensure poster.png / icon.png exist in source mod and sync mod into ~/Zomboid/mods/."""
    if not MOD_SOURCE_DIR.exists():
        IPC_DIR.mkdir(parents=True, exist_ok=True)
        return {
            "source_dir": str(MOD_SOURCE_DIR),
            "installed_dir": str(MOD_INSTALL_DIR),
            "ipc_dir": str(IPC_DIR),
            "installed_ok": (MOD_INSTALL_DIR / "42" / "mod.info").exists(),
            "warning": "Mod source directory not found; assuming mod was installed via Steam Workshop.",
        }

    mod_42_dir = MOD_SOURCE_DIR / "42"
    mod_42_dir.mkdir(parents=True, exist_ok=True)
    poster_path = mod_42_dir / "poster.png"
    icon_path = mod_42_dir / "icon.png"

    if not poster_path.exists():
        poster_path.write_bytes(_make_solid_png(256, 256, (28, 58, 36)))
    if not icon_path.exists():
        icon_path.write_bytes(_make_solid_png(32, 32, (64, 210, 95)))

    if force_sync or not (MOD_INSTALL_DIR / "42" / "mod.info").exists():
        MOD_INSTALL_DIR.parent.mkdir(parents=True, exist_ok=True)
        if MOD_INSTALL_DIR.exists():
            shutil.rmtree(MOD_INSTALL_DIR)
        shutil.copytree(MOD_SOURCE_DIR, MOD_INSTALL_DIR)

    IPC_DIR.mkdir(parents=True, exist_ok=True)
    return {
        "source_dir": str(MOD_SOURCE_DIR),
        "installed_dir": str(MOD_INSTALL_DIR),
        "ipc_dir": str(IPC_DIR),
        "installed_ok": (MOD_INSTALL_DIR / "42" / "mod.info").exists(),
    }


# ---------------------------------------------------------------------------
# Helpers: State Reading, Geography & Command Queueing
# ---------------------------------------------------------------------------


def _compass_bearing(dx: float, dy: float) -> str:
    # In Zomboid: +X is East, +Y is South, -Y is North, -X is West
    angle_deg = (math.degrees(math.atan2(dx, -dy)) + 360) % 360
    dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    return dirs[int((angle_deg + 22.5) // 45) % 8]


def resolve_kentucky_location(x: float, y: float) -> dict[str, Any]:
    best = None
    best_dist = float("inf")
    for lm in KENTUCKY_LANDMARKS:
        dx = x - lm["x"]
        dy = y - lm["y"]
        dist = math.hypot(dx, dy)
        if dist < best_dist:
            best_dist = dist
            # Direction FROM landmark TO player, and FROM player TO landmark
            to_landmark = _compass_bearing(lm["x"] - x, lm["y"] - y)
            best = {
                "nearest_landmark": lm["name"],
                "region": lm["region"],
                "distance_tiles": round(dist),
                "direction_to_landmark": to_landmark,
            }
    return best or {"nearest_landmark": "Kentucky Wilderness", "distance_tiles": 0}


def read_raw_state() -> dict[str, Any] | None:
    if not STATE_FILE.exists():
        return None
    for _ in range(4):
        try:
            raw = STATE_FILE.read_text(encoding="utf-8")
            if raw.endswith("__EOF__"):
                json_part = raw[: -len("__EOF__")].strip()
                return json.loads(json_part)
        except Exception:
            pass
        time.sleep(0.05)
    return None


def _load_seen_ids() -> set[str]:
    if SEEN_INBOX_FILE.exists():
        try:
            data = json.loads(SEEN_INBOX_FILE.read_text(encoding="utf-8"))
            if isinstance(data, list):
                return set(str(x) for x in data[-200:])
        except Exception:
            pass
    return set()


def _save_seen_ids(seen: set[str]) -> None:
    IPC_DIR.mkdir(parents=True, exist_ok=True)
    trimmed = sorted(seen)[-200:]
    SEEN_INBOX_FILE.write_text(json.dumps(trimmed, ensure_ascii=False), encoding="utf-8")


def enqueue_command(command: str, args: dict[str, Any], wait_for_ack_sec: float = 2.5) -> dict[str, Any]:
    IPC_DIR.mkdir(parents=True, exist_ok=True)
    current_seq = 0
    if CMD_INDEX_FILE.exists():
        try:
            current_seq = int(CMD_INDEX_FILE.read_text(encoding="utf-8").strip() or "0")
        except ValueError:
            current_seq = 0

    next_seq = current_seq + 1
    cmd_id = f"{command}_{next_seq}_{int(time.time() * 1000)}"
    payload = {
        "seq": next_seq,
        "id": cmd_id,
        "command": command,
        "args": args,
        "created_unix": time.time(),
    }

    cmd_path = IPC_DIR / f"cmd_{next_seq}.json"
    cmd_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    CMD_INDEX_FILE.write_text(str(next_seq), encoding="utf-8")

    # Check if the game world is actively ticking (state updated within last 12s)
    state_before = read_raw_state()
    game_seems_live = False
    if STATE_FILE.exists():
        age_sec = time.time() - STATE_FILE.stat().st_mtime
        game_seems_live = age_sec < 12.0

    if game_seems_live and wait_for_ack_sec > 0:
        deadline = time.time() + wait_for_ack_sec
        while time.time() < deadline:
            time.sleep(0.25)
            st = read_raw_state()
            if st and isinstance(st.get("acks"), list):
                for ack in st["acks"]:
                    if isinstance(ack, dict) and ack.get("seq") == next_seq:
                        return {
                            "status": "executed_in_game" if ack.get("ok") else "in_game_error",
                            "seq": next_seq,
                            "command": command,
                            "ack": ack,
                        }

    return {
        "status": "queued",
        "seq": next_seq,
        "command": command,
        "note": (
            "Команда записана в очередь и выполнится сразу, как только мир Zomboid будет активен (не на паузе)."
            if not game_seems_live
            else "Команда отправлена в Zomboid (ожидает следующего тика сервера)."
        ),
        "last_known_cursor": state_before.get("last_processed_seq") if state_before else None,
    }


def _find_game_install_dir() -> Path | None:
    for cand in DEFAULT_PZ_INSTALL_CANDIDATES:
        if cand and (cand / "media" / "scripts").exists():
            return cand
    return None


# ---------------------------------------------------------------------------
# MCP Tools
# ---------------------------------------------------------------------------


@mcp.tool()
def get_game_state(mark_messages_read: bool = True) -> dict[str, Any]:
    """
    Read real-time telemetry from Project Zomboid Build 42:
    players (coordinates, nearest town, wounds, infection, hunger, panic, current vehicle & fuel),
    weather, world date/time, unread player radio transmissions on 98.4 MHz, and active zone triggers.
    """
    mod_status = ensure_mod_assets_and_installed(force_sync=False)
    st = read_raw_state()
    if st is None:
        return {
            "game_connected": False,
            "mod_installed": mod_status["installed_ok"],
            "mod_install_path": mod_status["installed_dir"],
            "message": (
                "state.json пока не создан. Запустите Project Zomboid, включите мод "
                "'Project Zomboid AI Director (MCP Bridge)' в меню Моды / настройках Сервера и загрузите мир."
            ),
        }

    file_age_sec = round(time.time() - STATE_FILE.stat().st_mtime, 1)
    is_live = file_age_sec < 8.0

    # Enrich player locations with Kentucky town names
    players = st.get("players", [])
    if isinstance(players, list):
        for p in players:
            if isinstance(p, dict) and "x" in p and "y" in p:
                p["location"] = resolve_kentucky_location(p["x"], p["y"])

    # Separate unread player radio messages from previously seen ones
    seen_ids = _load_seen_ids()
    inbox = st.get("inbox", []) if isinstance(st.get("inbox"), list) else []
    unread_messages = []
    for msg in inbox:
        if isinstance(msg, dict):
            mid = str(msg.get("msg_id", ""))
            if mid and mid not in seen_ids:
                if "x" in msg and "y" in msg:
                    msg["location"] = resolve_kentucky_location(msg["x"], msg["y"])
                unread_messages.append(msg)
                if mark_messages_read:
                    seen_ids.add(mid)

    if mark_messages_read and unread_messages:
        _save_seen_ids(seen_ids)

    return {
        "game_connected": True,
        "world_actively_ticking": is_live,
        "state_age_seconds": file_age_sec,
        "is_multiplayer_server": st.get("is_multiplayer_server"),
        "radio_channel": st.get("radio_channel"),
        "world_time": st.get("world_time"),
        "weather": st.get("weather"),
        "players": players,
        "unread_radio_messages": unread_messages,
        "recent_inbox_history": inbox[-8:],
        "active_zone_triggers": st.get("zone_triggers", []),
        "recent_events": st.get("recent_events", [])[-10:],
        "recent_command_acks": st.get("acks", [])[-6:],
    }


@mcp.tool()
def send_radio_transmission(
    message: str,
    sender: str = "Диспетчер 'Орёл-1' [98.4 MHz]",
    is_alert: bool = False,
    delivery_mode: Literal["radio_and_hud", "strict_radio"] = "radio_and_hud",
    freq: int = 98400,
) -> dict[str, Any]:
    """
    Broadcast an in-game radio transmission to survivors on 98.4 MHz (freq=98400).
    - delivery_mode='radio_and_hud': airs on Zomboid's real DynamicRadio 98.4 MHz AND shows overhead/chat text so nobody misses it.
    - delivery_mode='strict_radio': only players near or carrying a turned-on radio tuned to `freq` receive the HUD/chat message.
    Split multi-sentence messages with newlines ('\\n') for realistic radio pacing.
    """
    lines = [ln.strip() for ln in message.splitlines() if ln.strip()]
    return enqueue_command(
        "radio_broadcast",
        {
            "lines": lines,
            "sender": sender,
            "is_alert": is_alert,
            "delivery_mode": delivery_mode,
            "freq": freq,
            "r": 1.0 if is_alert else 0.35,
            "g": 0.42 if is_alert else 1.0,
            "b": 0.35 if is_alert else 0.45,
        },
    )


@mcp.tool()
def give_starter_radios(target_player: str = "", freq: int = 98400) -> dict[str, Any]:
    """
    Give a powered, pre-tuned Military Walkie-Talkie (98.4 MHz) directly to a specific player
    or to ALL active players (when target_player is empty).
    """
    return enqueue_command(
        "give_starter_radio",
        {"target_player": target_player, "freq": freq},
    )


@mcp.tool()
def spawn_supply_drop(
    items: list[dict[str, Any]],
    placement: Literal["crate", "ground", "inventory"] = "crate",
    target_player: str = "",
    offset_x: int = 4,
    offset_y: int = 4,
    crate_name: str = "Военный груз снабжения",
    add_smoke_flare: bool = True,
    x: int | None = None,
    y: int | None = None,
    z: int = 0,
) -> dict[str, Any]:
    """
    Spawn items in the world!
    `items` example: [{"type": "Base.PetrolCan", "count": 2}, {"type": "Base.FirstAidKit_Military", "count": 1}]
    - placement='crate': builds a wooden supply crate near the player (or at x,y) with optional smoke flare!
    - placement='ground': drops items directly on the ground.
    - placement='inventory': puts items directly into the player's inventory.
    Note: If (x, y) is >70 tiles from all players, use `schedule_zone_trigger` instead so the chunk is loaded first.
    """
    args: dict[str, Any] = {
        "items": items,
        "placement": placement,
        "target_player": target_player,
        "offset_x": offset_x,
        "offset_y": offset_y,
        "crate_name": crate_name,
        "add_smoke": add_smoke_flare,
        "z": z,
    }
    if x is not None and y is not None:
        args["x"] = x
        args["y"] = y
    return enqueue_command("spawn_items", args)


@mcp.tool()
def spawn_story_note(
    title: str,
    pages: list[str],
    placement: Literal["inventory", "crate", "ground"] = "inventory",
    target_player: str = "",
    x: int | None = None,
    y: int | None = None,
) -> dict[str, Any]:
    """
    Create an actual readable in-game Notebook (`Base.Notebook`) with a custom title and AI-written pages
    (supports Russian Cyrillic text!). Ideal for survivor journals, military orders, or coordinate clues.
    """
    args: dict[str, Any] = {
        "title": title,
        "pages": pages,
        "placement": placement,
        "target_player": target_player,
    }
    if x is not None and y is not None:
        args["x"] = x
        args["y"] = y
    return enqueue_command("spawn_story_note", args)


@mcp.tool()
def spawn_zombie_horde(
    count: int = 12,
    outfit: str = "",
    distance_from_player: int = 35,
    direction: Literal["RANDOM", "N", "S", "E", "W", "NE", "NW", "SE", "SW"] = "RANDOM",
    radius: int = 6,
    lure_to_player: bool = True,
    crawler: bool = False,
    fake_dead: bool = False,
    health: float = 1.0,
    on_fire: bool = False,
    target_player: str = "",
    x: int | None = None,
    y: int | None = None,
) -> dict[str, Any]:
    """
    Spawn a zombie horde or themed squad!
    - Common outfits: '' (random civilians), 'ArmyCamoGreen', 'Police', 'HazardSuit', 'Doctor', 'Fireman', 'Mechanic', 'Inmate', 'Bandit'.
    - Keep `distance_from_player` between 20 and 65 so zombies appear out of immediate sight within loaded chunks and march in naturally.
    """
    args: dict[str, Any] = {
        "count": count,
        "outfit": outfit,
        "distance_from_player": distance_from_player,
        "direction": direction,
        "radius": radius,
        "lure_to_player": lure_to_player,
        "crawler": crawler,
        "fake_dead": fake_dead,
        "health": health,
        "on_fire": on_fire,
        "target_player": target_player,
    }
    if x is not None and y is not None:
        args["x"] = x
        args["y"] = y
    return enqueue_command("spawn_horde", args)


@mcp.tool()
def trigger_sound_or_alarm(
    event_type: Literal["gunshot", "scream", "helicopter", "building_alarm", "thunder", "invisible_attractor"] = "gunshot",
    target_player: str = "",
    radius: int = 130,
    volume: int = 90,
    notice: str = "",
    x: int | None = None,
    y: int | None = None,
) -> dict[str, Any]:
    """
    Trigger atmospheric sound and meta-events that organically move existing zombies in the area:
    - 'helicopter': triggers Zomboid's overhead helicopter event!
    - 'building_alarm': sets off a burglar alarm in the nearest building!
    - 'gunshot' / 'scream': plays distant audio + attracts zombies within `radius`.
    - 'invisible_attractor': pulls surrounding zombies toward (x, y) or player without spawning new ones.
    """
    args: dict[str, Any] = {
        "event_type": event_type,
        "target_player": target_player,
        "radius": radius,
        "volume": volume,
        "notice": notice,
    }
    if x is not None and y is not None:
        args["x"] = x
        args["y"] = y
    return enqueue_command("sound_event", args)


@mcp.tool()
def set_weather(
    preset: Literal["clear", "storm", "tropical_storm", "blizzard", "dense_fog", "natural", "custom"] = "storm",
    duration_hours: int = 6,
    fog: float | None = None,
    wind_kph: float | None = None,
    precipitation: float | None = None,
    is_snow: bool | None = None,
    temperature_c: float | None = None,
) -> dict[str, Any]:
    """
    Control Project Zomboid's ClimateManager in real time!
    Use `preset='dense_fog'` before an ambush, `preset='tropical_storm'` for a dramatic night drive,
    `preset='clear'` to reward survivors with sunshine, or `preset='natural'` to hand control back to vanilla weather.
    """
    args: dict[str, Any] = {
        "preset": None if preset == "custom" else preset,
        "duration_hours": duration_hours,
        "fog": fog,
        "wind_kph": wind_kph,
        "precipitation": precipitation,
        "is_snow": is_snow,
        "temperature_c": temperature_c,
    }
    return enqueue_command("weather", {k: v for k, v in args.items() if v is not None})


@mcp.tool()
def spawn_vehicle(
    vehicle_type: str = "Base.StepVan",
    condition: Literal["mint", "survivor", "wrecked"] = "survivor",
    fuel_percent: float = 35.0,
    create_key: bool = True,
    key_to_player: bool = False,
    direction: Literal["N", "S", "E", "W"] = "E",
    trunk_items: list[dict[str, Any]] | None = None,
    target_player: str = "",
    offset_x: int = 6,
    offset_y: int = 6,
    x: int | None = None,
    y: int | None = None,
) -> dict[str, Any]:
    """
    Spawn any vanilla or modded vehicle (e.g. 'Base.StepVan', 'Base.VanAmbulance', 'Base.PickUpVanLightsPolice',
    'Base.SUV', 'Base.OffRoad', or modded RV/bus IDs found via `search_game_catalog`).
    - If `key_to_player=False` and `create_key=True`, the vehicle key is placed inside the GloveBox!
    - `trunk_items`: optional list of `{"type": "Base.PetrolCan", "count": 2}` placed in the trunk!
    """
    args: dict[str, Any] = {
        "vehicle_type": vehicle_type,
        "condition": condition,
        "fuel_percent": fuel_percent,
        "create_key": create_key,
        "key_to_player": key_to_player,
        "direction": direction,
        "trunk_items": trunk_items or [],
        "target_player": target_player,
        "offset_x": offset_x,
        "offset_y": offset_y,
    }
    if x is not None and y is not None:
        args["x"] = x
        args["y"] = y
    return enqueue_command("spawn_vehicle", args)


@mcp.tool()
def trigger_world_effect(
    effect: Literal["smoke", "fire", "explosion", "lightning", "power_on", "power_off"] = "smoke",
    target_player: str = "",
    offset_x: int = 6,
    offset_y: int = 6,
    x: int | None = None,
    y: int | None = None,
) -> dict[str, Any]:
    """
    Trigger world effects:
    - 'smoke': signal smoke flare on square
    - 'fire' / 'explosion' / 'lightning': hazard at square
    - 'power_on' / 'power_off': toggle global Kentucky power grid!
    """
    args: dict[str, Any] = {
        "effect": effect,
        "target_player": target_player,
        "offset_x": offset_x,
        "offset_y": offset_y,
    }
    if x is not None and y is not None:
        args["x"] = x
        args["y"] = y
    return enqueue_command("world_effect", args)


@mcp.tool()
def modify_player_status(
    action: Literal["heal_full", "cure_infection", "give_xp", "calm_panic", "induce_panic"] = "heal_full",
    target_player: str = "",
    perk: str = "Mechanics",
    amount: float = 150.0,
) -> dict[str, Any]:
    """
    Reward or affect a player directly:
    - 'give_xp': grant XP in perks like 'Mechanics', 'MetalWelding', 'Electricity', 'Woodwork', 'Aiming', 'Doctor', 'Fitness', 'Strength'.
    - 'heal_full' / 'cure_infection' / 'calm_panic' / 'induce_panic'.
    """
    return enqueue_command(
        "modify_player",
        {
            "action": action,
            "target_player": target_player,
            "perk": perk,
            "amount": amount,
        },
    )


@mcp.tool()
def schedule_zone_trigger(
    name: str,
    x: int,
    y: int,
    actions: list[dict[str, Any]],
    radius: int = 55,
    trigger_id: str = "",
) -> dict[str, Any]:
    """
    Schedule a deferred multi-action story encounter at ANY `(x, y)` coordinates on the Kentucky map
    (even miles away in unloaded chunks!). As soon as any survivor approaches within `radius` tiles (10..90)
    and the chunk loads, Zomboid automatically executes `actions` and logs `zone_trigger_fired`.

    Example `actions`:
    [
      {"command": "spawn_vehicle", "args": {"vehicle_type": "Base.VanAmbulance", "x": 10615, "y": 10630, "condition": "wrecked"}},
      {"command": "spawn_items", "args": {"x": 10617, "y": 10630, "placement": "crate", "add_smoke": true, "items": [{"type": "Base.FirstAidKit_Military", "count": 2}]}},
      {"command": "spawn_horde", "args": {"x": 10620, "y": 10635, "count": 18, "outfit": "ArmyCamoGreen"}},
      {"command": "radio_broadcast", "args": {"text": "Внимание! Вы вышли к санитарному конвою! Вижу зелёный дым!"}}
    ]
    """
    return enqueue_command(
        "add_zone_trigger",
        {
            "id": trigger_id or None,
            "name": name,
            "x": x,
            "y": y,
            "radius": radius,
            "actions": actions,
        },
    )


@mcp.tool()
def remove_zone_trigger(trigger_id: str = "ALL") -> dict[str, Any]:
    """Remove a scheduled zone trigger by ID, or pass trigger_id='ALL' to clear all pending triggers."""
    return enqueue_command("remove_zone_trigger", {"id": trigger_id})


@mcp.tool()
def get_kentucky_landmarks() -> list[dict[str, Any]]:
    """Return key Build 42 Kentucky towns, gas stations, checkpoints, and Louisville extraction coordinates."""
    return KENTUCKY_LANDMARKS


@mcp.tool()
def search_game_catalog(
    query: str,
    category: Literal["items", "vehicles", "all"] = "all",
    limit: int = 30,
) -> dict[str, Any]:
    """
    Search Project Zomboid's actual installed script files (both vanilla Build 42 AND any installed mods!)
    for exact `Module.ItemName` or `Module.VehicleName` IDs so you never guess an item or vehicle ID.
    """
    q = query.strip().lower()
    if not q:
        return {"error": "Provide a non-empty search query (e.g. 'Walkie', 'Welding', 'Van', 'Generator', 'Rifle')."}

    roots: list[Path] = []
    pz_dir = _find_game_install_dir()
    if pz_dir:
        roots.append(pz_dir / "media" / "scripts")
        workshop_dir = pz_dir.parent.parent / "workshop" / "content" / "108600"
        if workshop_dir.exists():
            roots.append(workshop_dir)
    if (ZOMBOID_USER_DIR / "mods").exists():
        roots.append(ZOMBOID_USER_DIR / "mods")

    module_re = re.compile(r"^\s*module\s+([A-Za-z0-9_]+)", re.IGNORECASE)
    item_re = re.compile(r"^\s*item\s+([A-Za-z0-9_]+)")
    veh_re = re.compile(r"^\s*vehicle\s+([A-Za-z0-9_]+)")

    found_items: list[str] = []
    found_vehicles: list[str] = []

    for root in roots:
        for txt_file in root.rglob("*.txt"):
            try:
                text = txt_file.read_text(encoding="utf-8", errors="ignore")
            except Exception:
                continue
            current_mod = "Base"
            for line in text.splitlines():
                m_mod = module_re.match(line)
                if m_mod:
                    current_mod = m_mod.group(1)
                    continue
                if category in ("items", "all") and len(found_items) < limit:
                    m_it = item_re.match(line)
                    if m_it:
                        full_id = f"{current_mod}.{m_it.group(1)}"
                        if q in full_id.lower() and full_id not in found_items:
                            found_items.append(full_id)
                if category in ("vehicles", "all") and len(found_vehicles) < limit:
                    m_vh = veh_re.match(line)
                    if m_vh:
                        full_id = f"{current_mod}.{m_vh.group(1)}"
                        if q in full_id.lower() and full_id not in found_vehicles:
                            found_vehicles.append(full_id)
            if len(found_items) >= limit and len(found_vehicles) >= limit:
                break

    return {
        "query": query,
        "items": found_items[:limit],
        "vehicles": found_vehicles[:limit],
    }


@mcp.tool()
def sync_mod_to_zomboid() -> dict[str, Any]:
    """Force-sync the ZomboidAIDirector Build 42 Lua mod from workspace into ~/Zomboid/mods/ZomboidAIDirector."""
    return ensure_mod_assets_and_installed(force_sync=True)


def main() -> None:
    """Run the Project Zomboid AI Director MCP server over stdio."""
    ensure_mod_assets_and_installed(force_sync=False)
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
