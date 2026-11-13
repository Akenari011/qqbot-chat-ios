# QQBot Chat iOS（QQ 机器人聊天客户端）

一个直接连接 QQ 官方机器人 API 的 iOS 聊天客户端。输入机器人 AppID 与 AppSecret，通过 WebSocket 接收消息、官方接口发送消息，无需部署自建服务器。

> ⚠️ **尝鲜版 / 半成品，存在已知和未知问题。**
> 功能清单表示已实现的代码路径，不代表全部经过真机验证。文件实际送达、滚动与键盘动画、部分频道操作仍需验证，不建议用于重要沟通。长期自动维护计划已暂停，后续按反馈做定点修复。

## 下载与安装

当前版本：[v0.1.0-preview](https://github.com/Akenari011/qqbot-chat-ios/releases/tag/v0.1.0-preview)。2026-11-13 已替换为提交 `1198cac` 的最新发布构建，版本号不变。

- [下载无签名 IPA](https://github.com/Akenari011/qqbot-chat-ios/releases/download/v0.1.0-preview/QQBotChat-unsigned.ipa)
- [下载 SHA-256 校验文件](https://github.com/Akenari011/qqbot-chat-ios/releases/download/v0.1.0-preview/QQBotChat-unsigned.ipa.sha256)
- [对应成功构建](https://github.com/Akenari011/qqbot-chat-ios/actions/runs/43313024976)

要求 **iOS 26+、arm64**。IPA 未签名，需要使用侧载工具自行重签，不能直接点击安装。

1. 下载 IPA，核对校验文件，重签并安装。
2. 打开 App，输入机器人 AppID 与 AppSecret，等待“已连接”。凭证保存在本机 Keychain。
3. 从 QQ 给机器人发一条消息，会话自动出现在首页；随后在 App 内回复。单聊和群聊受 QQ 回复时限、权限及频率限制。

录音需要麦克风权限；保存图片或视频需要相册添加权限。照片和文件通过系统选择器导入。

## 当前功能

| 功能 | 实现情况与边界 |
| --- | --- |
| 消息收发 | 单聊、群聊、频道文本与媒体发送路径；实际可用性受机器人权限、媒体格式及平台限制影响 |
| 文件发送 | 单聊/群聊通过官方接口直接发送，当前最多 5MB；显示“平台已受理，送达待确认”，不代表对方已收到。频道文件入口未开放 |
| 会话管理 | 搜索、置顶、归档、静音、未读、本地删除；首页编辑可删除会话，右侧进入设置 |
| 消息操作 | 复制、引用、文本转发、失败重发、机器人消息撤回；频道另有编辑、回应、置顶、公告、日程入口，部分仍待验证 |
| 消息分组 | 同成员连续消息组首显示单行姓名、组尾显示头像；气泡保持独立圆角 |
| 成员头像 | 长按有成员 ID 的消息，可设置或恢复本机头像；按会话和成员 ID 保存，不修改 QQ 资料 |
| 图片、视频、语音 | 图片预览、视频有声全屏播放器；录音支持取消，取消后不发送；媒体格式与设备播放效果仍需验证 |
| 表情与表情包 | 系统 emoji、本地图片/GIF 收藏库；336 项 QQ 表情目录支持名称/ID 搜索，QQ 表情按图片发送 |
| 转发聊天记录 | 对已识别的文本转录显示摘要卡片，详情按条展示；可按需加载链接仍有效的图片/GIF及视频附件，不等于 QQ 原生合并转发解析 |
| 连接与外观 | 心跳、退避重连、Resume、前台恢复；深浅主题、字体、聊天背景、原生玻璃控件 |
| 其他 | 会话备注与头像、日志导出、凭证 Keychain 存储 |

## 已知限制与待验证项

- **群内真正的 @ 提醒尚未支持。** 当前只插入普通 `@姓名`；成员列表来自本机已收到的消息，不是完整群成员名单。
- **文件实际送达仍需验证。** 平台返回消息 ID 不等于 QQ 客户端已接收，暂无送达或已读回执。未接入大文件分片上传。
- 单聊/群聊没有官方历史拉取接口，断线期间依赖 Resume 补发；频道可拉取最近 50 条。
- iOS 锁屏或长时间后台会暂停 WebSocket，没有 APNs 推送。
- 单聊/群聊通常依赖被动回复上下文；频道不要求同样的回复 ID，但仍受权限和限频约束。
- “删除”“清空”仅影响本机记录；撤回调用官方接口，时限与权限以服务端结果为准。
- 按钮消息在 App 中仅展示预览，需在 QQ 中操作；频道管理（角色、权限、禁言等）未接入。
- 进入会话、弹出键盘、快速滚动仍可能卡顿；现有优化未经过真机帧率采样，不能视为已完全解决。
- GIF 收藏保留原文件，但 QQ 端动画效果未全面验证；转录附件链接可能过期，视频附件缺少完整样例验证。
- QQ 表情目录来自 [QFace](https://koishi.js.org/QFace/)，当前快照含历史条目，不保证 QQ 线上全量；图片在线加载，版权归腾讯，使用限制见第三方声明。
- 不支持语音/视频通话，也不能保证获取真实群头像或所有成员头像。

## 构建与验证

GitHub Actions 提供 iOS Simulator 编译，以及 iPhone arm64 Release 编译、无签名 IPA 打包与 SHA-256 校验；仓库另保留 Python 网关测试及容器冒烟检查。构建成功仅证明编译和打包通过，不等同于真机交互或 QQ 消息端到端验证。

也可从 [Actions](https://github.com/Akenari011/qqbot-chat-ios/actions) 下载 `QQBotChat-unsigned-IPA` 构建产物。Release 由维护者手动更新，不保证与每次源码提交同步。

## 开源许可与声明

原创代码采用 **MIT License**，见 [LICENSE](LICENSE)。界面布局与尺寸参考 Telegram-iOS 的公开实现，未复制其源码或资源。本项目为第三方独立客户端，与 Telegram、腾讯均无关联。QQ 接口、商标及表情资源归各自权利人所有；本项目代码许可不授予腾讯图片资源的额外使用权。

详见 [第三方声明](THIRD_PARTY_NOTICES.md)、[API 能力记录](API_MATRIX.md) 和 [维护交接记录](HANDOFF.md)。

## 官方资料

- [QQ 消息收发概述](https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/overview.html)
- [QQ access_token](https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/access-token.html)
- [群聊文件上传与发送](https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_groups_group_openid_files.post.html)
- [腾讯 BotPy SDK](https://github.com/tencent-connect/botpy)
