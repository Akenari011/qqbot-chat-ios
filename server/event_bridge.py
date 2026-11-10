import os
import asyncio
import httpx
import botpy
from botpy.message import C2CMessage, GroupMessage, Message

class EventBridge(botpy.Client):
    def __init__(self):
        intents = botpy.Intents(direct_message=True, public_guild_messages=True, public_messages=True)
        super().__init__(intents=intents)
        self.gateway_url = os.environ["QQBOT_INTERNAL_INGEST_URL"]
        self.gateway_key = os.environ["QQBOT_GATEWAY_KEY"]
        self.chat_scene = os.environ["QQBOT_CHAT_SCENE"]
        self.chat_target_id = os.environ["QQBOT_CHAT_TARGET_ID"]
        self.bot_id = ""

    async def on_ready(self):
        self.bot_id = str(self.robot.id)

    async def persist(self, scene, target_id, message_id, author_id, author_name, content, timestamp):
        if not target_id or not message_id:
            return
        if str(author_id or "") == self.bot_id:
            return
        if scene != self.chat_scene or str(target_id) != self.chat_target_id:
            return
        event = {
            "scene": scene, "target_id": str(target_id), "message_id": str(message_id),
            "author_id": str(author_id or "unknown"), "author_name": str(author_name or ""),
            "content": str(content or ""), "timestamp": str(timestamp or ""),
            "from_bot": str(author_id or "") == self.bot_id,
        }
        async with httpx.AsyncClient(timeout=10) as client:
            response = await client.post(self.gateway_url, headers={"Authorization": f"Bearer {self.gateway_key}"}, json={"messages": [event]})
            response.raise_for_status()

    async def on_c2c_message_create(self, message: C2CMessage):
        await self.persist("c2c", message.author.user_openid, message.id, message.author.user_openid, "", message.content, message.timestamp)

    async def on_group_at_message_create(self, message: GroupMessage):
        await self.persist("group", message.group_openid, message.id, message.author.member_openid, "", message.content, message.timestamp)

    async def on_group_message_create(self, message: GroupMessage):
        await self.persist("group", message.group_openid, message.id, message.author.member_openid, "", message.content, message.timestamp)

    async def on_at_message_create(self, message: Message):
        await self.persist("channel", message.channel_id, message.id, str(getattr(message.author, "id", "unknown")), str(getattr(message.author, "username", "")), message.content, message.timestamp)

async def run():
    app_id = os.environ.get("QQBOT_APP_ID")
    secret = os.environ.get("QQBOT_CLIENT_SECRET")
    required = (app_id, secret, os.environ.get("QQBOT_GATEWAY_KEY"), os.environ.get("QQBOT_INTERNAL_INGEST_URL"), os.environ.get("QQBOT_CHAT_SCENE"), os.environ.get("QQBOT_CHAT_TARGET_ID"))
    if not all(required):
        raise RuntimeError("QQBOT_APP_ID, QQBOT_CLIENT_SECRET, QQBOT_GATEWAY_KEY, QQBOT_INTERNAL_INGEST_URL, QQBOT_CHAT_SCENE and QQBOT_CHAT_TARGET_ID are required")
    async with EventBridge() as client:
        await client.start(appid=app_id, secret=secret)

def main():
    asyncio.run(run())

if __name__ == "__main__":
    main()