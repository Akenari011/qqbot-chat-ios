import os
import tempfile
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
import main

class InboxTests(unittest.TestCase):
    def setUp(self):
        self.db_file = tempfile.NamedTemporaryFile(suffix=".sqlite3", delete=False)
        self.db_file.close()
        self.client = TestClient(main.app)
        self.env = patch.dict(os.environ, {"QQBOT_DB_PATH": self.db_file.name, "QQBOT_GATEWAY_KEY": "test-key", "QQBOT_CHAT_SCENE": "c2c", "QQBOT_CHAT_TARGET_ID": "user-openid"})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.addCleanup(lambda: os.unlink(self.db_file.name))
        main.init_db()
        self.headers = {"Authorization": "Bearer test-key"}

    def test_store_and_read_inbound_message_deduplicated(self):
        item = {"scene": "c2c", "target_id": "user-openid", "message_id": "m-1", "author_id": "u-1", "author_name": "Alice", "content": "Hi bot", "timestamp": "2026-11-10T09:00:00Z", "from_bot": False}
        for _ in range(2):
            saved = self.client.post("/internal/qqbot/incoming", headers=self.headers, json={"messages": [item]})
            self.assertEqual(saved.status_code, 200, saved.text)
        response = self.client.get("/api/qqbot/messages", headers=self.headers, params={"scene": "c2c", "target_id": "user-openid"})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(len(response.json()["messages"]), 1)
        self.assertEqual(response.json()["messages"][0]["author_name"], "Alice")

    def test_internal_ingest_requires_gateway_auth(self):
        response = self.client.post("/internal/qqbot/incoming", json={"messages": []})
        self.assertEqual(response.status_code, 401)

if __name__ == "__main__":
    unittest.main()
