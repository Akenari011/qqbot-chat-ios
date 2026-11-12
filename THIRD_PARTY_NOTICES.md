# 第三方声明与致谢

本文件说明 QQBot Chat 的许可、所参考的开源项目与第三方组件的归属。

## 本项目许可

本仓库中的原创代码（`QQBotChatApp.swift`、`QQBotChat.xcodeproj`、GitHub Actions 工作流、
`server/` 下的自研网关与测试、文档、图标资源）采用 **MIT License**，见 [LICENSE](</LICENSE>)。

## QQ 表情目录与在线图片

QQ 表情 ID、名称和资源路径来自 [Koishi QFace](https://koishi.js.org/QFace/) 的 [v2 索引](https://koishi.js.org/QFace/assets/qq_emoji/_index.v2.json)，快照时间 2026-11-12；当前筛选 336 项带 PNG 资源且未标记 removed 的条目，不保证官方线上全量。图片在线加载，不随应用打包。

[QFace 来源说明](https://github.com/koishijs/QFace) 明确：表情资源版权归腾讯，仅供学习交流、请勿商用；仓库代码的 MIT 许可不等于腾讯图片授权。本项目不主张这些图片的版权，也不授予额外使用权。

## 界面设计参考

本项目的界面布局、交互与部分尺寸常量参考了
[TelegramMessenger/Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS) 的公开实现，
用于对齐聊天类 App 的视觉层级（气泡圆角、内边距、会话行尺寸、输入栏结构、菜单顺序等）。

- 本项目**不包含、未复制、未链接** Telegram-iOS 的任何源代码、资源文件或二进制产物。
- 所有实现均为使用 SwiftUI / UIKit 系统 API 的独立重写。
- Telegram-iOS 仓库自身由多个模块组成，各部分许可不同（其 README 要求逐项遵守组件许可）。
  使用或再分发本项目的界面设计参考时，请自行查阅上游仓库的许可要求。
- Telegram 名称、标志与品牌归 Telegram FZ-LLC 所有。本项目与 Telegram 无任何关联，
  不是 Telegram 官方或衍生客户端，也不使用其名称与标志作为产品标识。

## QQ 机器人平台

- 本项目通过 **QQ 官方机器人开放平台** 的公开 HTTP / WebSocket 接口收发消息。
- QQ、QQ 机器人及相关商标归腾讯科技（深圳）有限公司所有。本项目是第三方独立客户端，
  与腾讯无关联、未经其认可或背书。
- 使用本 App 需自备机器人 AppID 与 AppSecret，并遵守
  [QQ 机器人官方文档](https://bot.q.qq.com/wiki/) 及平台服务条款。
- `server/` 下可选网关以 [腾讯 BotPy SDK](https://github.com/tencent-connect/botpy)
  作为协议参考；该 SDK 采用 **MIT License**（Copyright (c) 2021 Tencent）。
  本仓库不包含该 SDK 的源码副本，仅在 `.venv` / 构建环境中按需安装。

## 可选服务端依赖（仅 `server/`，App 本身不依赖）

| 组件 | 许可 |
| --- | --- |
| FastAPI | MIT |
| Starlette | BSD-3-Clause |
| Pydantic | MIT |
| Uvicorn | BSD-3-Clause |
| HTTPX | BSD-3-Clause |
| aiohttp | Apache-2.0 |
| APScheduler | MIT |
| PyYAML | MIT |
| pytest | MIT |

各依赖的完整许可文本随安装包提供（见对应 `*.dist-info/licenses/`）。

## 系统框架与工具

- SwiftUI、UIKit、PhotosUI、AVFoundation、Foundation、Network 等为 Apple 随 Xcode / iOS 提供的
  系统框架，不是本仓库分发的开源组件；使用受 Apple 开发者条款约束。
- `Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` 为本项目自行绘制生成，
  未使用任何第三方图标素材。生成过程中使用的 Pillow 采用 HPND 风格许可，
  其代码不进入本仓库。

## 免责声明

本项目按「现状」提供，不保证 QQ 平台接口变动后的持续可用性。无签名 IPA 仅供个人自测，
不用于公开发布。作者不对使用本项目产生的账号、数据或合规问题承担责任。
