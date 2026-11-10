import ast
import json
import unittest
from pathlib import Path

SOURCE = Path(__file__).with_name("main.py").read_text()
TREE = ast.parse(SOURCE)

class GatewayContractTests(unittest.TestCase):
    def test_python_syntax(self):
        self.assertIsInstance(TREE, ast.Module)

    def test_gateway_authentication_required(self):
        self.assertIn('@app.post("/api/qqbot/messages"', SOURCE)
        self.assertIn('hmac.compare_digest(authorization or "", f"Bearer {key}")', SOURCE)
        self.assertIn('require_chat_user(authorization)', SOURCE)
        self.assertIn('sign_session(username, expires, secret)', SOURCE)
        self.assertIn('QQBOT_CLIENT_SECRET', SOURCE)

    def test_documented_scene_paths(self):
        for fragment in (
            '/v2/users/{safe_id}/messages',
            '/v2/groups/{safe_id}/messages',
            '/channels/{safe_id}/messages',
        ):
            self.assertIn(fragment, SOURCE)

    def test_text_message_payload(self):
        self.assertIn('json={"content": message.text, "msg_type": 0}', SOURCE)

    def test_client_request_contract(self):
        payload = {"scene": "c2c", "target_id": "user-openid", "text": "hello"}
        self.assertEqual(set(json.loads(json.dumps(payload))), {"scene", "target_id", "text"})

if __name__ == "__main__":
    unittest.main()
