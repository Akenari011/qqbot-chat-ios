import base64
import hashlib
import hmac
import os
import sqlite3
import time
from pathlib import Path
from typing import Literal
from urllib.parse import quote

import httpx
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

app = FastAPI(title="QQBot Chat Gateway")
API = "https://api.bot.qq.com"

class LoginInput(BaseModel):
    username: str = Field(min_length=1, max_length=128)
    password: str = Field(min_length=1, max_length=1024)

class LoginOutput(BaseModel):
    access_token: str
    token_type: str = "Bearer"
    expires_in: int

class MessageIn(BaseModel):
    text: str = Field(min_length=1, max_length=2000)

class ChatConfig(BaseModel):
    scene: Literal["c2c", "group", "channel"]
    target_id: str = Field(min_length=1, max_length=128)

class MessageOut(BaseModel):
    messageID: str

class IncomingMessage(BaseModel):
    scene: Literal["c2c", "group", "channel"]
    target_id: str = Field(min_length=1, max_length=128)
    message_id: str = Field(min_length=1, max_length=256)
    author_id: str = Field(min_length=1, max_length=128)
    author_name: str = Field(default="", max_length=128)
    content: str = Field(default="", max_length=4000)
    timestamp: str = Field(default="", max_length=64)
    from_bot: bool = False

class IncomingList(BaseModel):
    messages: list[IncomingMessage]

def chat_config() -> ChatConfig:
    try:
        return ChatConfig(scene=os.environ["QQBOT_CHAT_SCENE"], target_id=os.environ["QQBOT_CHAT_TARGET_ID"])
    except (KeyError, ValueError):
        raise HTTPException(503, "QQBOT_CHAT_SCENE and QQBOT_CHAT_TARGET_ID must be configured")

def db_path() -> str:
    return os.environ.get("QQBOT_DB_PATH", "qqbot_messages.sqlite3")

def init_db() -> None:
    Path(db_path()).parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(db_path()) as db:
        db.execute("CREATE TABLE IF NOT EXISTS messages (message_id TEXT PRIMARY KEY, scene TEXT NOT NULL, target_id TEXT NOT NULL, author_id TEXT NOT NULL, author_name TEXT NOT NULL, content TEXT NOT NULL, timestamp TEXT NOT NULL, from_bot INTEGER NOT NULL)")
        db.commit()

@app.on_event("startup")
def startup() -> None:
    init_db()

_token = ""
_token_expires = 0.0

async def access_token(client: httpx.AsyncClient) -> str:
    global _token, _token_expires
    if _token and time.time() < _token_expires - 60:
        return _token
    app_id = os.environ.get("QQBOT_APP_ID")
    secret = os.environ.get("QQBOT_CLIENT_SECRET")
    if not app_id or not secret:
        raise HTTPException(503, "QQ bot credentials are not configured")
    try:
        response = await client.post("https://api.bot.qq.com/app/getAppAccessToken", json={"appId": app_id, "clientSecret": secret})
        payload = response.json()
    except (httpx.HTTPError, ValueError):
        raise HTTPException(502, "QQ access token request failed")
    if response.is_error or not payload.get("access_token"):
        raise HTTPException(502, "QQ access token request failed")
    _token = payload["access_token"]
    _token_expires = time.time() + int(payload.get("expires_in", 7200))
    return _token

def gateway_key() -> str:
    key = os.environ.get("QQBOT_GATEWAY_KEY")
    if not key:
        raise HTTPException(503, "Gateway authentication is not configured")
    return key

def require_gateway(authorization: str | None) -> None:
    key = gateway_key()
    if not hmac.compare_digest(authorization or "", f"Bearer {key}"):
        raise HTTPException(401, "Unauthorized")

def sign_session(username: str, expires: int, secret: str) -> str:
    payload = base64.urlsafe_b64encode(f"{username}:{expires}".encode()).decode().rstrip("=")
    signature = hmac.new(secret.encode(), payload.encode(), hashlib.sha256).hexdigest()
    return f"{payload}.{signature}"

def require_chat_user(authorization: str | None) -> None:
    username = os.environ.get("QQBOT_CHAT_USERNAME")
    secret = os.environ.get("QQBOT_SESSION_SECRET") or os.environ.get("QQBOT_GATEWAY_KEY")
    if not username or not secret:
        raise HTTPException(503, "Chat user authentication is not configured")
    try:
        scheme, token = (authorization or "").split(" ", 1)
        payload, signature = token.split(".", 1)
        decoded = base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)).decode()
        token_user, token_expires = decoded.rsplit(":", 1)
        expected = hmac.new(secret.encode(), payload.encode(), hashlib.sha256).hexdigest()
        valid = scheme.lower() == "bearer" and hmac.compare_digest(signature, expected) and hmac.compare_digest(token_user, username) and int(token_expires) >= int(time.time())
    except (ValueError, UnicodeDecodeError):
        valid = False
    if not valid:
        raise HTTPException(401, "Unauthorized")

def insert_message(message: IncomingMessage) -> None:
    init_db()
    with sqlite3.connect(db_path()) as db:
        db.execute("INSERT OR IGNORE INTO messages VALUES (?, ?, ?, ?, ?, ?, ?, ?)", (message.message_id, message.scene, message.target_id, message.author_id, message.author_name, message.content, message.timestamp, int(message.from_bot)))
        db.commit()

@app.post("/api/qqbot/login", response_model=LoginOutput)
def login(credentials: LoginInput):
    username = os.environ.get("QQBOT_CHAT_USERNAME")
    password = os.environ.get("QQBOT_CHAT_PASSWORD")
    secret = os.environ.get("QQBOT_SESSION_SECRET") or os.environ.get("QQBOT_GATEWAY_KEY")
    if not username or not password or not secret:
        raise HTTPException(503, "Chat user authentication is not configured")
    if not hmac.compare_digest(credentials.username.encode(), username.encode()) or not hmac.compare_digest(credentials.password.encode(), password.encode()):
        raise HTTPException(401, "Unauthorized")
    expires = int(time.time()) + 12 * 60 * 60
    return LoginOutput(access_token=sign_session(username, expires, secret), expires_in=12 * 60 * 60)

@app.get("/api/qqbot/config", response_model=ChatConfig)
def get_config(authorization: str | None = Header(default=None)):
    require_chat_user(authorization)
    return chat_config()

@app.post("/api/qqbot/messages", response_model=MessageOut)
async def send_message(message: MessageIn, authorization: str | None = Header(default=None)):
    require_chat_user(authorization)
    config = chat_config()
    safe_id = quote(config.target_id, safe="")
    if config.scene == "c2c":
        path = f"/v2/users/{safe_id}/messages"
    elif config.scene == "group":
        path = f"/v2/groups/{safe_id}/messages"
    else:
        path = f"/channels/{safe_id}/messages"
    async with httpx.AsyncClient(timeout=15) as client:
        token = await access_token(client)
        headers = {"Authorization": f"QQBot {token}", "Content-Type": "application/json"}
        try:
            response = await client.post(API + path, headers=headers, json={"content": message.text, "msg_type": 0})
            payload = response.json() if response.content else {}
        except (httpx.HTTPError, ValueError):
            raise HTTPException(502, "QQ message send failed")
        if response.is_error or payload.get("err_code", payload.get("code", 0)) or not payload.get("id", payload.get("message_id")):
            raise HTTPException(502, "QQ message send failed")
        message_id = str(payload.get("id", payload.get("message_id", "")))
        if message_id:
            insert_message(IncomingMessage(scene=config.scene, target_id=config.target_id, message_id=message_id, author_id="bot", author_name="QQ 机器人", content=message.text, timestamp=str(payload.get("timestamp", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))), from_bot=True))
        return MessageOut(messageID=message_id or "accepted")

@app.post("/internal/qqbot/incoming")
def store_incoming(messages: IncomingList, authorization: str | None = Header(default=None)):
    require_gateway(authorization)
    if any(message.from_bot for message in messages.messages):
        raise HTTPException(400, "Only inbound user messages may be stored here")
    for message in messages.messages:
        insert_message(message)
    return {"stored": len(messages.messages)}

@app.get("/api/qqbot/messages", response_model=IncomingList)
def list_messages(authorization: str | None = Header(default=None)):
    require_chat_user(authorization)
    config = chat_config()
    init_db()
    with sqlite3.connect(db_path()) as db:
        rows = db.execute("SELECT message_id, scene, target_id, author_id, author_name, content, timestamp, from_bot FROM messages WHERE scene=? AND target_id=? ORDER BY rowid DESC LIMIT 500", (config.scene, config.target_id)).fetchall()
    rows.reverse()
    return {"messages": [{"message_id": r[0], "scene": r[1], "target_id": r[2], "author_id": r[3], "author_name": r[4], "content": r[5], "timestamp": r[6], "from_bot": bool(r[7])} for r in rows]}
