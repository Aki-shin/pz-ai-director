AIDirectorConfig = AIDirectorConfig or {}

AIDirectorConfig.VERSION = "1.0.0"
AIDirectorConfig.MOD_ID = "ZomboidAIDirector"
AIDirectorConfig.NET_MODULE = "AIDirector"

-- Directory inside C:\Users\<User>\Zomboid\Lua\
AIDirectorConfig.DATA_DIR = "AIDirector"
AIDirectorConfig.STATE_FILE = "AIDirector/state.json"
AIDirectorConfig.CURSOR_FILE = "AIDirector/cursor.txt"
AIDirectorConfig.CMD_INDEX_FILE = "AIDirector/cmd_index.txt"
AIDirectorConfig.EVENTS_FILE = "AIDirector/events.jsonl"

-- Default AI Emergency/Military Extraction Radio Channel (98.4 MHz)
AIDirectorConfig.RADIO_FREQ = 98400
AIDirectorConfig.RADIO_UUID = "AIDIR-984000"
AIDirectorConfig.RADIO_NAME = "Extraction Command [98.4 MHz]"
AIDirectorConfig.RADIO_CATEGORY = "Emergency"

-- Polling intervals in wall-clock milliseconds
AIDirectorConfig.CMD_POLL_MS = 1000
AIDirectorConfig.STATE_WRITE_MS = 2000
AIDirectorConfig.TRIGGER_CHECK_MS = 1500

-- Ring buffer limits
AIDirectorConfig.MAX_INBOX = 40
AIDirectorConfig.MAX_ACKS = 40

return AIDirectorConfig
