# QQBot Chat iOS 原型

## 产品模式

这是一个普通聊天页面：打开固定会话、输入文字并发送，收发内容在同一对话里展示。界面明确显示“QQ 机器人”。用户不需要在聊天页选择 API 场景或填写目标 ID；会话目标仅由服务端配置。

## Telegram-iOS 仓库评估

[TelegramMessenger/Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS) 不是可直接嵌入的独立聊天 UI 库。完整客户端与 Telegram 账户、MTProto、数据模型及大量内部模块耦合；仓库约 906 MB 且有多个 submodule。根目录未检测到通用 LICENSE，README 要求逐项遵守组件许可并公开派生代码。Telegram API 条款要求自有 api_id、清楚披露与 Telegram 的关系，不要将应用直接命名为 Telegram（除非 Unofficial 前缀），也不要使用官方标志。本原型只借鉴通用聊天交互，不复制 Telegram 源码或品牌素材。

## 当前架构

- iOS 客户端通过自有网关发文字 `POST /api/qqbot/messages`，并轮询 `GET /api/qqbot/messages` 显示当前会话。
- 服务端从 `QQBOT_CHAT_SCENE` 和 `QQBOT_CHAT_TARGET_ID` 读取固定会话，支持 c2c、group、channel。使用 QQ 官方 API 统一域名 `https://api.bot.qq.com` 与各场景文档路径发送。
- `server/event_bridge.py` 使用腾讯官方 BotPy SDK 连接 QQ WebSocket，接收单聊、群聊和频道消息事件，只保存配置的目标会话。SQLite 存储去重消息；机器人出站消息明确标记为机器人。
- AppID、AppSecret 与 QQ access_token 只在服务端环境。QQ 官方要求 access_token 不得用于客户端。`server/.env.example` 仅包含占位符。
- 当前网关 Bearer key 仅适合私有开发原型；公开发布前需改为用户会话认证，不能静态嵌进 App。内网收件端点应只允许事件桥访问。

## 部署与测试

服务端变量示例见 `server/.env.example`。设置这些服务端变量后运行 FastAPI：`uvicorn main:app --app-dir server --host 127.0.0.1 --port 8080`；事件桥使用同一组机器人和目标配置，并设置 `QQBOT_INTERNAL_INGEST_URL` 指向受保护的内部收件端点，启动命令为 `python server/event_bridge.py`。部署前需为 iOS 配置网关 URL 与用户认证机制。

GitHub Actions 配置在 `.github/workflows/ci.yml`：Ubuntu runner 安装依赖并执行网关/事件桥测试；macOS runner 解析 Swift 源码。此目录尚未连接 GitHub remote，Actions 未触发；已加入最小 Xcode 工程与共享 scheme；macOS GitHub Actions 将执行无签名 iOS Simulator 编译。本地无 Swift/Xcode，且目录没有 Git remote，因此 CI 构建结果待 push 后验证。

本地 `python -m pytest -q server`：12 项测试通过，覆盖固定会话路由、鉴权、Token、消息存储去重与 SDK 事件映射。全部使用模拟网络响应，未真实调用 QQ API。

## 尚未完成

1. 需要用获授权 QQ 机器人配置验证 WebSocket 登录、事件权限及真实收发。
2. 当前环境无 Swift/Xcode，也没有 Xcode 工程，无法构建或运行 iOS 模拟器。
3. 上线前需完成每用户认证、目标授权、HTTPS、限流和审计。

官方资料：[QQ 消息收发概述](https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/overview.html) · [QQ access_token](https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/access-token.html) · [BotPy SDK](https://github.com/tencent-connect/botpy) · [Telegram iOS README](https://github.com/TelegramMessenger/Telegram-iOS/blob/master/README.md) · [Telegram API Terms](https://core.telegram.org/api/terms)
