"""Exercise a running test container without contacting QQ."""
import json
import os
import time
import urllib.error
import urllib.request

BASE = 'http://127.0.0.1:8080'

def call(path, body=None, token=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode() if body is not None else None, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=3) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)

for attempt in range(30):
    try:
        status, _ = call('/api/qqbot/config')
        assert status == 401
        break
    except (OSError, AssertionError):
        if attempt == 29:
            raise
        time.sleep(1)

status, result = call('/api/qqbot/login', {'username': 'container-user', 'password': os.environ['SMOKE_PASSWORD']})
assert status == 200, status
token = result['access_token']
assert call('/api/qqbot/config', token=token)[0] == 200
assert call('/internal/qqbot/incoming', {'messages': []}, token=token)[0] == 401
status, _ = call('/internal/qqbot/incoming', {'messages': [{
    'scene': 'c2c', 'target_id': 'container-openid', 'message_id': 'smoke-1',
    'author_id': 'test-user', 'author_name': 'Test user', 'content': 'container smoke test',
    'timestamp': '2026-01-01T00:00:00Z', 'from_bot': False,
}]}, token='container-internal-key')
assert status == 200
status, result = call('/api/qqbot/messages', token=token)
assert status == 200 and result['messages'][0]['message_id'] == 'smoke-1'
print('Container login, authentication isolation and persistence smoke checks passed')
