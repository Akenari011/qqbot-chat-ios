import os
import time
import unittest
from unittest.mock import patch
from fastapi.testclient import TestClient
import main

class LoginTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {
            'QQBOT_CHAT_USERNAME': 'tester', 'QQBOT_CHAT_PASSWORD': 'example-password',
            'QQBOT_SESSION_SECRET': 'example-session-signing-key',
            'QQBOT_CHAT_SCENE': 'c2c', 'QQBOT_CHAT_TARGET_ID': 'example-openid',
            'QQBOT_GATEWAY_KEY': 'example-internal-key',
        })
        self.env.start()
        self.addCleanup(self.env.stop)
        self.client = TestClient(main.app)

    def test_login_and_access_config(self):
        r = self.client.post('/api/qqbot/login', json={'username':'tester', 'password':'example-password'})
        self.assertEqual(r.status_code, 200)
        token = r.json()['access_token']
        self.assertEqual(r.json()['expires_in'], 43200)
        r = self.client.get('/api/qqbot/config', headers={'Authorization':'Bearer '+token})
        self.assertEqual(r.status_code, 200)

    def test_expired_tampered_and_internal_tokens_rejected(self):
        expired = main.sign_session('tester', int(time.time())-10, 'example-session-signing-key')
        good = main.sign_session('tester', int(time.time())+100, 'example-session-signing-key')
        for token in (expired, good+'changed', 'example-internal-key', 'malformed'):
            with self.subTest(token=token):
                r = self.client.get('/api/qqbot/config', headers={'Authorization':'Bearer '+token})
                self.assertEqual(r.status_code, 401)

    def test_wrong_password_rejected(self):
        r = self.client.post('/api/qqbot/login', json={'username':'tester','password':'incorrect'})
        self.assertEqual(r.status_code, 401)
