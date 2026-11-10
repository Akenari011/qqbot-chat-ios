import os
import time
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
import main

class FakeResponse:
    def __init__(self, payload, status=200):
        self._payload = payload
        self.status_code = status
        self.is_error = status >= 400
        self.content = b"{}"
    def json(self): return self._payload

class FakeAsyncClient:
    calls = []
    responses = []
    def __init__(self, *args, **kwargs): pass
    async def __aenter__(self): return self
    async def __aexit__(self, *args): return False
    async def post(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return self.responses.pop(0)

class GatewayApiTests(unittest.TestCase):
    user_headers = {"Authorization": "Basic dGVzdGVyOnRlc3QtcGFzc3dvcmQ="}

    def setUp(self):
        self.client = TestClient(main.app)
        self.env = patch.dict(os.environ, {"QQBOT_GATEWAY_KEY": "test-gateway-key", "QQBOT_CHAT_USERNAME": "tester", "QQBOT_CHAT_PASSWORD": "test-password", "QQBOT_APP_ID": "test-app", "QQBOT_CLIENT_SECRET": "test-secret", "QQBOT_CHAT_SCENE": "c2c", "QQBOT_CHAT_TARGET_ID": "openid-1", "QQBOT_DB_PATH": "/tmp/qqbot-api-test.sqlite3"})
        self.env.start(); self.addCleanup(self.env.stop)
        self.user_headers = {"Authorization": "Bearer " + main.sign_session("tester", int(time.time()) + 3600, os.environ["QQBOT_GATEWAY_KEY"])}
        main._token = ""; main._token_expires = 0
        main.init_db()
        with main.sqlite3.connect(main.db_path()) as db: db.execute("DELETE FROM messages")
        FakeAsyncClient.calls = []
        FakeAsyncClient.responses = [FakeResponse({"access_token": "test-token", "expires_in": 7200}), FakeResponse({"id": "msg-123"})]

    def test_send_uses_fixed_target_and_bot_token(self):
        with patch.object(main.httpx, "AsyncClient", FakeAsyncClient):
            response = self.client.post("/api/qqbot/messages", headers=self.user_headers, json={"text": "hello"})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["messageID"], "msg-123")
        self.assertEqual(FakeAsyncClient.calls[0][0], "https://api.bot.qq.com/app/getAppAccessToken")
        self.assertEqual(FakeAsyncClient.calls[1][0], "https://api.bot.qq.com/v2/users/openid-1/messages")
        self.assertEqual(FakeAsyncClient.calls[1][1]["headers"]["Authorization"], "QQBot test-token")
        self.assertEqual(FakeAsyncClient.calls[1][1]["json"], {"content": "hello", "msg_type": 0})
        with main.sqlite3.connect(main.db_path()) as db: row = db.execute("SELECT from_bot, author_name, content FROM messages WHERE message_id='msg-123'").fetchone()
        self.assertEqual(row, (1, "QQ 机器人", "hello"))

    def test_fixed_group_and_channel_endpoints(self):
        for scene, target, expected in (("group", "group-openid", "/v2/groups/group-openid/messages"), ("channel", "channel-id", "/channels/channel-id/messages")):
            with self.subTest(scene=scene):
                with patch.dict(os.environ, {"QQBOT_CHAT_SCENE": scene, "QQBOT_CHAT_TARGET_ID": target}):
                    main._token = "cached-token"; main._token_expires = 9999999999
                    FakeAsyncClient.calls = []; FakeAsyncClient.responses = [FakeResponse({"id": "msg-456"})]
                    with patch.object(main.httpx, "AsyncClient", FakeAsyncClient): response = self.client.post("/api/qqbot/messages", headers=self.user_headers, json={"text": "hello"})
                self.assertEqual(response.status_code, 200, response.text)
                self.assertTrue(FakeAsyncClient.calls[0][0].endswith(expected))

    def test_business_error_is_not_reported_as_sent(self):
        main._token = "cached-token"
        main._token_expires = 9999999999
        FakeAsyncClient.responses = [FakeResponse({"err_code": 40034005})]
        with patch.object(main.httpx, "AsyncClient", FakeAsyncClient):
            response = self.client.post("/api/qqbot/messages", headers=self.user_headers, json={"text": "hello"})
        self.assertEqual(response.status_code, 502)

    def test_rejects_missing_gateway_auth(self):
        with patch.object(main.httpx, "AsyncClient", FakeAsyncClient): response = self.client.post("/api/qqbot/messages", json={"text": "hello"})
        self.assertEqual(response.status_code, 401); self.assertEqual(FakeAsyncClient.calls, [])

if __name__ == "__main__": unittest.main()
