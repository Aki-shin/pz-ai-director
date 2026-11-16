from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import server


class PzAiDirectorTests(unittest.TestCase):
    def test_make_solid_png_header(self) -> None:
        png = server._make_solid_png(16, 16, (28, 58, 36))
        self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertGreater(len(png), 32)

    def test_compass_bearing(self) -> None:
        self.assertEqual(server._compass_bearing(0, -10), "N")
        self.assertEqual(server._compass_bearing(10, 0), "E")
        self.assertEqual(server._compass_bearing(0, 10), "S")
        self.assertEqual(server._compass_bearing(-10, 0), "W")

    def test_get_kentucky_landmarks_non_empty(self) -> None:
        landmarks = server.get_kentucky_landmarks()
        self.assertGreaterEqual(len(landmarks), 10)
        for lm in landmarks:
            self.assertIn("name", lm)
            self.assertIn("x", lm)
            self.assertIn("y", lm)

    def test_read_state_and_mark_messages_read(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ipc = Path(tmp) / "Lua" / "AIDirector"
            ipc.mkdir(parents=True, exist_ok=True)
            state_file = ipc / "state.json"
            seen_file = ipc / "mcp_seen_inbox.json"

            sample_state = {
                "world_time": {"year": 1993, "month": 7, "day": 9, "hour": 12, "minutes": 0},
                "players": [
                    {"username": "Tester", "x": 8115, "y": 11640, "z": 0, "health": 100}
                ],
                "inbox": [
                    {"msg_id": "m1", "player": "Tester", "text": "Hello base!", "x": 8115, "y": 11640}
                ],
                "acks": [],
                "triggers": [],
            }
            state_file.write_text(json.dumps(sample_state) + "\n__EOF__", encoding="utf-8")

            with (
                mock.patch.object(server, "IPC_DIR", ipc),
                mock.patch.object(server, "STATE_FILE", state_file),
                mock.patch.object(server, "SEEN_INBOX_FILE", seen_file),
            ):
                first = server.get_game_state(mark_messages_read=True)
                self.assertTrue(first["game_connected"])
                self.assertEqual(len(first["unread_radio_messages"]), 1)
                self.assertEqual(first["unread_radio_messages"][0]["text"], "Hello base!")

                second = server.get_game_state(mark_messages_read=True)
                self.assertEqual(len(second["unread_radio_messages"]), 0)

    def test_mod_lua_uses_safe_b42_cure_infection(self) -> None:
        lua_path = server.MOD_SOURCE_DIR / "42" / "media" / "lua" / "server" / "AIDirectorServer.lua"
        content = lua_path.read_text(encoding="utf-8")
        self.assertIn("if bd.setInfectionLevel then pcall", content)
        self.assertIn("bd:RestoreToFullHealth()", content)


if __name__ == "__main__":
    unittest.main()
