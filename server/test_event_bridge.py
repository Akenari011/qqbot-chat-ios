import asyncio
import os
import unittest
from unittest.mock import patch

from event_bridge import EventBridge

class MessageEvent:
    id = "event-1"
    content = "hello"
    timestamp = "2026-11-10T10:00:00Z"
    class author:
        user_openid = "user-1"

class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {"QQBOT_INTERNAL_INGEST_URL": "https://gateway.test/internal/qqbot/incoming", "QQBOT_GATEWAY_KEY": "bridge-test-key", "QQBOT_CHAT_SCENE": "c2c", "QQBOT_CHAT_TARGET_ID": "user-1"})
        self.env.start(); self.addCleanup(self.env.stop)
        self.loop = asyncio.new_event_loop(); asyncio.set_event_loop(self.loop)
        self.addCleanup(self.loop.close)
        self.addCleanup(asyncio.set_event_loop, None)

    def test_c2c_handler_posts_event(self):
        bridge = EventBridge(); bridge.bot_id = "bot-id"
        posts = []
        class Response:
            def raise_for_status(self): pass
        class Client:
            def __init__(self, *args, **kwargs): pass
            async def __aenter__(self): return self
            async def __aexit__(self, *args): return False
            async def post(self, url, **kwargs): posts.append((url, kwargs)); return Response()
        with patch("event_bridge.httpx.AsyncClient", Client):
            self.loop.run_until_complete(bridge.on_c2c_message_create(MessageEvent()))
        self.assertEqual(posts[0][0], "https://gateway.test/internal/qqbot/incoming")
        event = posts[0][1]["json"]["messages"][0]
        self.assertEqual(event["scene"], "c2c"); self.assertEqual(event["target_id"], "user-1")
        self.assertFalse(event["from_bot"])

    def test_bot_event_is_not_duplicated(self):
        bridge = EventBridge(); bridge.bot_id = "bot-id"; captured = []
        message = MessageEvent(); message.author = type("Author", (), {"user_openid": "bot-id"})()
        self.loop.run_until_complete(bridge.on_c2c_message_create(message))
        self.assertEqual(captured, [])

class LifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def test_run_closes_sdk_context(self):
        from event_bridge import run
        calls = []
        class FakeBridge:
            async def __aenter__(self):
                calls.append('enter')
                return self
            async def __aexit__(self, *args):
                calls.append('exit')
            async def start(self, **kwargs):
                calls.append('start')
        env = {'QQBOT_APP_ID':'example', 'QQBOT_CLIENT_SECRET':'example',
               'QQBOT_GATEWAY_KEY':'example', 'QQBOT_INTERNAL_INGEST_URL':'http://localhost/internal',
               'QQBOT_CHAT_SCENE':'c2c', 'QQBOT_CHAT_TARGET_ID':'example'}
        with patch.dict(os.environ, env), patch('event_bridge.EventBridge', FakeBridge):
            await run()
        self.assertEqual(calls, ['enter', 'start', 'exit'])

if __name__ == "__main__": unittest.main()
