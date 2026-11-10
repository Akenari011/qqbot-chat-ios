# QQBot Chat iOS 交接文档

## 产品方向

单机 iOS App，直接连接 QQ 官方机器人 API 与 WebSocket，不依赖自建后端。AppID/AppSecret 由用户在 App 内输入，保存在系统 Keychain。界面参考 Telegram iOS 的信息层级与交互，不复用其源码。

## 安装与使用

1. 从 GitHub Actions 下载 `QQBotChat-unsigned-IPA` 产物，解压后得到 IPA。
2. 用侧载/重签工具安装。最低 iOS 17，arm64；无签名 IPA 不能由标准 iOS 直接安装。
3. 打开 App，输入机器人 AppID 与 AppSecret，等待状态变为“已连接”。
4. 先在 QQ 给机器人发消息，建立会话与被动回复上下文，再在 App 内回复。
5. 支持文本、图片、视频、语音、文件、Markdown、引用、按钮消息、表情。

## 功能矩阵

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 多会话列表 | 完成 | 未读数、置顶、滑动删除、搜索 |
| 文本消息 | 完成 | 支持 Markdown 渲染、引用、长按复制/引用/删除 |
| 图片消息 | 完成 | 发送压缩到 1600px，接收缓存，全屏查看 |
| 视频消息 | 完成 | 选择视频，20MB 限制，内嵌播放 |
| 语音消息 | 完成 | AAC/m4a 录音、发送、接收播放已真机验证可用 |
| 文件消息 | 完成 | `file_type 4` 实测可用，支持选择、发送、分享 |
| 按钮消息 | 完成 | 渲染 keyboard 按钮标签，接收 INTERACTION_CREATE 点击 |
| 表情 | 完成 | 常用 emoji 面板 |
| 会话搜索 | 完成 | 会话名、最后消息、全部历史内容 |
| 深色模式 | 完成 | 跟随系统/浅色/深色 |
| 发送状态 | 完成 | 发送中、成功、失败三态 |
| 草稿 | 完成 | 按会话保存 |
| 断线重连 | 完成 | 心跳 ACK、指数退避、Resume、网络恢复重连 |
| 本地历史 | 完成 | 每会话持久化，最多保留全部消息 |
| 频道消息 | 未实现 | 当前只处理 C2C 与群聊事件 |
| 实时语音通话 | 不支持 | QQ Bot API 无此能力 |

## 实现位置

- `QQBotChatApp.swift`：全部客户端代码（模型、网络、WebSocket、页面）。
- `QQBotChat.xcodeproj`：iOS 工程与共享 scheme。
- `.github/workflows/ipa.yml`：真机 Release 无签名编译、arm64 校验、IPA 打包、SHA-256。
- `.github/workflows/ci.yml`：模拟器编译、服务端测试、容器冒烟。
- `server/`、`compose.yaml`：可选历史服务端实现，当前 App 不使用。
- `ROADMAP.md`：长期路线。

## 验证证据

- 真机编译、arm64 架构校验、IPA 打包与 Info.plist 校验均通过（每次推送触发）。
- 当前产物：`deliverables/QQBotChat-unsigned.ipa`，SHA-256 e837885fd419f5767c62605c6d548eda12513c05794b8c5b80d94da8bbec6f1a，289,504 字节。
- 真实 QQ 协议层（Python 探针）已验证：access_token 鉴权、WebSocket READY、单聊事件接收、文本回复、图片 base64 上传、文件上传。
- 用户真机验证：语音消息发送与接收均可正常使用（AAC/m4a 由 QQ 服务端处理，无需 silk 客户端编码）。
- 未验证：App 内 Swift WebSocket 的真实收发、语音 m4a 是否被 QQ 接受、真机 Keychain 与权限弹窗。

## 已知限制

- iOS 后台/锁屏会暂停 WebSocket，无 APNs，后台消息不能保证实时。
- 当前只处理单聊与群聊事件，频道消息未接入。
- 语音已验证可用；若后续 QQ 调整转码策略，可能需要重新评估 silk。
- 消息删除只删本地，不会撤回 QQ 侧消息。
- 单一机器人账号，无多账号切换。
- 每次发送必须处于 QQ 被动回复窗口内（由用户最近一条消息触发）。

## 凭证与安全

- 不要把 AppSecret、access token、GitHub Token 或用户 OpenID 写入源码、文档、提交或日志。
- 用户已在聊天中暴露过凭证，提醒其自行轮换。
- 无签名 IPA 仅用于自测，不要公开发布。
