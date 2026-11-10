# QQBot Chat iOS 独立测试版

当前 iOS App 已改为直接连接 QQ 官方 API 和 WebSocket，不依赖下文的可选 Python 网关。打开 App 输入自己的 AppID 和 AppSecret（保存到系统 Keychain），连接成功后先从 QQ 向机器人发消息，再在 App 回复。当前仅显示最近收到的一个会话，切换来源会清空当前内存列表；暂无本地消息持久化、自动重连或 token 刷新。锁屏和后台可能暂停连接。无签名 IPA 需使用侧载工具重签后安装，支持 iOS 17+。下文服务端方案保留作为可选历史实现。

## 产品模式

这是一个普通聊天页面：打开固定会话、输入文字并发送，收发内容在同一对话里展示。界面明确显示“QQ 机器人”。用户不需要在聊天页选择 API 场景或填写目标 ID；会话目标仅由服务端配置。

## Telegram-iOS 仓库评估

[TelegramMessenger/Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS) 不是可直接嵌入的独立聊天 UI 库。完整客户端与 Telegram 账户、MTProto、数据模型及大量内部模块耦合；仓库约 906 MB 且有多个 submodule。根目录未检测到通用 LICENSE，README 要求逐项遵守组件许可并公开派生代码。Telegram API 条款要求自有 api_id、清楚披露与 Telegram 的关系，不要将应用直接命名为 Telegram（除非 Unofficial 前缀），也不要使用官方标志。本原型只借鉴通用聊天交互，不复制 Telegram 源码或品牌素材。

## 当前架构

- iOS 客户端通过自有网关发文字 `POST /api/qqbot/messages`，并轮询 `GET /api/qqbot/messages` 显示当前会话。
- 服务端从 `QQBOT_CHAT_SCENE` 和 `QQBOT_CHAT_TARGET_ID` 读取固定会话，支持 c2c、group、channel。使用 QQ 官方 API 统一域名 `https://api.bot.qq.com` 与各场景文档路径发送。
- `server/event_bridge.py` 使用腾讯官方 BotPy SDK 连接 QQ WebSocket，接收单聊、群聊和频道消息事件，只保存配置的目标会话。SQLite 存储去重消息；机器人出站消息明确标记为机器人。
- AppID、AppSecret 与 QQ access_token 只在服务端环境。QQ 官方要求 access_token 不得用于客户端。`server/.env.example` 仅包含占位符。
- 客户端运行时填写 HTTPS 服务器地址与聊天账号密码，通过登录接口获取 12 小时签名令牌；Keychain 只保存令牌。内部事件桥独立使用 QQBOT_GATEWAY_KEY。当前只支持单一配置账号，不是多租户认证系统。

## 部署与测试

服务端变量示例见 `server/.env.example`。设置这些服务端变量后运行 FastAPI：`uvicorn main:app --app-dir server --host 127.0.0.1 --port 8080`；事件桥使用同一组机器人和目标配置，并设置 `QQBOT_INTERNAL_INGEST_URL` 指向受保护的内部收件端点，启动命令为 `python server/event_bridge.py`。部署前需为 iOS 配置网关 URL 与用户认证机制。

GitHub Actions 在 Ubuntu 执行服务端测试、在 macOS 执行无签名 iOS Simulator 编译；公开仓库已连接，登录版编译、服务端测试及容器 HTTP 冒烟测试均已通过。后续运行结果以 Actions 页面为准。

当前 19 项本地测试通过。2026-11-10 已用用户授权的凭证真实验证 QQ 鉴权、WebSocket READY、单聊事件接收及被动回复发送成功；测试凭证、消息内容和 OpenID 未写入仓库。该实测使用临时协议探针，并非手机 App 全链路验收。

## 尚未完成

1. 部署长期运行的网关和事件桥，以手机或模拟器登录并完成全链路收发验证。
2. 目前只支持一个服务端配置的会话和账号，尚无会话列表、多用户授权、附件发送。
3. 生产部署需要 HTTPS、登录限流和审计；12 小时签名令牌通过轮换会话签名密钥整体失效，尚无单个令牌撤销机制。

官方资料：[QQ 消息收发概述](https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/overview.html) · [QQ access_token](https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/access-token.html) · [BotPy SDK](https://github.com/tencent-connect/botpy) · [Telegram iOS README](https://github.com/TelegramMessenger/Telegram-iOS/blob/master/README.md) · [Telegram API Terms](https://core.telegram.org/api/terms)

## 容器部署

将 `server/.env.example` 复制为仅服务器可读的 `server/.env`，填入真实配置；不要提交该文件。执行 `docker compose up -d --build` 同时启动网关和事件桥。网关仅发布到 `127.0.0.1:8080`；使用 HTTPS 反向代理对外提供 `/api/qqbot/`，不要代理 `/internal/`。SQLite 使用独立 volume 持久化。

GitHub Actions 已成功构建容器并验证真实 HTTP 登录、用户/内部认证隔离和消息读写；实际 QQ 事件桥长期运行尚未验证。公开仓库和镜像上下文均排除本地 `.env`、数据库及日志。

## 模拟器构建产物与联调验收

在成功的 Actions 运行页面下载 `QQBotChat-Simulator`。该产物仅供 macOS 上的 iOS Simulator 使用，不是可直接安装到 iPhone 的 IPA。真机安装需要配置自己的 Bundle ID、Apple Development 签名与设备。

联调顺序：配置服务端机器人凭证及授权目标 OpenID → 启动网关和事件桥 → 将 HTTPS 反向代理指向网关 → App 输入服务器地址和聊天账号 → 从 QQ 向机器人发消息并确认左侧接收 → App 输入文字并确认 QQ 收到机器人消息和右侧发送记录 → 重启网关确认历史仍存在。尚未执行这套手机端验收，不应把独立 QQ 协议探针测试等同于 App 全链路验证。
