import os
import time
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
        self.env = patch.dict(os.environ, {"QQBOT_DB_PATH": self.db_file.name, "QQBOT_GATEWAY_KEY": "test-key", "QQBOT_CHAT_USERNAME": "tester", "QQBOT_CHAT_PASSWORD": "test-password", "QQBOT_CHAT_SCENE": "c2c", "QQBOT_CHAT_TARGET_ID": "user-openid"})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.addCleanup(lambda: os.unlink(self.db_file.name))
        main.init_db()
        self.internal_headers = {"Authorization": "Bearer test-key"}
        self.user_headers = {"Authorization": "Bearer " + main.sign_session("tester", int(time.time()) + 3600, os.environ["QQBOT_GATEWAY_KEY"])}

    def test_store_and_read_inbound_message_deduplicated(self):
        item = {"scene": "c2c", "target_id": "user-openid", "message_id": "m-1", "author_id": "u-1", "author_name": "Alice", "content": "Hi bot", "timestamp": "2026-11-10T09:00:00Z", "from_bot": False}
        for _ in range(2):
            saved = self.client.post("/internal/qqbot/incoming", headers=self.internal_headers, json={"messages": [item]})
            self.assertEqual(saved.status_code, 200, saved.text)
        response = self.client.get("/api/qqbot/messages", headers=self.user_headers)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(len(response.json()["messages"]), 1)
        self.assertEqual(response.json()["messages"][0]["author_name"], "Alice")

    def test_internal_ingest_requires_gateway_auth(self):
        response = self.client.post("/internal/qqbot/incoming", json={"messages": []})
        self.assertEqual(response.status_code, 401)

    def test_chat_routes_require_user_auth(self):
        sent = self.client.post("/api/qqbot/messages", headers=self.internal_headers, json={"text": "hello"})
        history = self.client.get("/api/qqbot/messages", headers=self.internal_headers)
        login = self.client.post("/api/qqbot/login", json={"username": "tester", "password": "incorrect-password"})
        self.assertEqual(sent.status_code, 401)
        self.assertEqual(history.status_code, 401)
        self.assertEqual(login.status_code, 401)

if __name__ == "__main__":
    unittest.main()
