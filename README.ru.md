# Project Zomboid AI Director (Build 42 MCP Bridge)

**[English version (README.md)](README.md)**

Связка **серверного/клиентского мода на Lua под Project Zomboid Build 42** и **Python MCP-сервера**, превращающая Antigravity, Claude Desktop или Cursor в живого **ИИ-режиссёра и военного радиодиспетчера (`98.4 MHz`)** для одиночной игры и кооператива.

## Возможности

* **Настоящий радиоканал (`98.4 MHz`)**: регистрирует станцию `Extraction Command [98.4 MHz]` в системе `DynamicRadio` (`AIDirectorRadio.lua`).
* **Двусторонняя связь с игроками**:
  1. **Через ПКМ в любой точке экрана:** `Рация Эвакуации [98.4 MHz]` → `Передать сообщение Диспетчеру...` (работает в соло и коопе).
  2. **Через рацию в инвентаре / машине:** ПКМ по рации → `Настроить на 98.4 MHz (Канал ИИ-Диспетчера)`.
  3. **Через обычный чат в мультиплеере:** начните сообщение с `@` или `!ai` (например: `@Орёл-1, у нас заканчивается бензин под Малдро!`).
* **Живая телеметрия (`get_game_state`)**: координаты, ближайший ориентир Кентукки, здоровье, заражение/укусы/кровотечение, голод/паника/усталость, топливо и состояние машины, погода и непрочитанные сообщения игроков.
* **16 MCP-инструментов режиссёра**:
  * `send_radio_transmission` — передача сообщений в эфир (`radio_and_hud` или `strict_radio`).
  * `give_starter_radios` — выдача настроенных военных раций `98.4 MHz`.
  * `spawn_supply_drop` — сброс ящиков с дымовой шашкой, лут на землю или прямо в инвентарь.
  * `spawn_story_note` — создание читаемых блокнотов (`Base.Notebook`) с многостраничным текстом на русском или английском.
  * `spawn_zombie_horde` — спавн орд и засад вокруг точки или игрока.
  * `trigger_sound_or_alarm` — далёкий вертолёт, выстрелы, крики, сирены.
  * `set_weather` — управление погодой (шторм, ливень, густой туман, ясно).
  * `spawn_vehicle` — спавн транспорта (`good`, `wrecked`, `random`) с ключом.
  * `trigger_world_effect` — огонь, дым или взрыв по координатам.
  * `modify_player_status` — `heal_full`, `cure_infection` (адаптировано под Build 42), `give_xp`, `calm_panic`, `induce_panic`.
  * `schedule_zone_trigger` / `remove_zone_trigger` — отложенные сюжетные сцены в дальних непрогруженных городах (срабатывают при приближении игроков).
  * `get_kentucky_landmarks` и `search_game_catalog` — поиск реальных ID предметов и машин по установленной игре и модам Workshop.
  * `sync_mod_to_zomboid` — принудительная синхронизация мода в `~/Zomboid/mods/ZomboidAIDirector`.

## Быстрый старт

### 1. Установка мода (Build 42)
* **Через Steam Workshop**: подпишитесь на **Project Zomboid AI Director (MCP Bridge)** (ID `3840209384`) и включите `ZomboidAIDirector` в списке модов / конфиге сервера.
* **Или локально из репозитория**: при первом запуске `uv run server.py` мод автоматически скопируется в `~/Zomboid/mods/ZomboidAIDirector`.

### 2. Запуск MCP-сервера
Требуется Python 3.12+ и [`uv`](https://docs.astral.sh/uv/):

```bash
cd pz-ai-director
uv sync
uv run server.py
```

### 3. Подключение к ИИ-клиенту
Готовые шаблоны лежат в [`examples/mcp_configs/`](examples/mcp_configs/):
* [`antigravity_mcp_config.json`](examples/mcp_configs/antigravity_mcp_config.json)
* [`claude_desktop_config.json`](examples/mcp_configs/claude_desktop_config.json)
* [`cursor_mcp.json`](examples/mcp_configs/cursor_mcp.json)

### Переменные окружения (опционально)
* `PZ_ZOMBOID_DIR` — путь к папке данных Zomboid (по умолчанию `~/Zomboid`).
* `PZ_GAME_DIR` — путь к установленной игре Project Zomboid для `search_game_catalog`.

## Запуск тестов

```bash
cd pz-ai-director
uv run python -m unittest discover -s tests -v
```

## Лицензия

MIT — см. [LICENSE](LICENSE).
