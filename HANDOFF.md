# QQBot Chat iOS 交接

## 当前产品方向

用户要求全部集成到一个 iPhone App，不部署服务器。当前 SwiftUI App 直接调用 QQ 官方 API 获取 token，通过 URLSessionWebSocketTask 接收事件并回复文字。Python 网关、事件桥和容器配置保留为可选历史方案，当前 App 不使用它们。

## 使用方法

1. 下载 QQBotChat-unsigned-IPA 构建产物，解压外层 GitHub artifact ZIP，取得其中的 IPA。
2. 使用自己的侧载/重签工具安装。无签名 IPA 无法直接由标准 iOS 安装；最低 iOS 17，真机 arm64。
3. App 输入 QQ 机器人 AppID、AppSecret，点击登录；凭证存入系统 Keychain，没有硬编码用户密钥。
4. 保持 App 前台并等待 QQ 连接就绪，从 QQ 私聊机器人（群聊需对应权限/事件）。
5. 收到消息后在 App 输入文字回复；使用事件 message ID 和递增 msg_seq 作为被动回复上下文。

## 实现位置

- QQBotChatApp.swift：独立 App、Keychain、QQ token/API、WebSocket Identify/heartbeat、消息气泡。
- QQBotChat.xcodeproj：iOS 工程，共享 scheme QQBotChat。
- .github/workflows/ipa.yml：真机 Release 无签名编译、arm64 验证、Payload ZIP 打包及 SHA-256。
- .github/workflows/ci.yml：模拟器编译、历史服务端测试和容器冒烟检查。
- server/、compose.yaml：可选历史服务端实现，不是当前 App 的必需服务。

## 已建立的验证证据

- 用户授权凭证的真实 QQ 鉴权成功；临时 Python 协议探针收到单聊事件并发送回复，QQ 返回 HTTP 200 和消息 ID。
- 这不是手机 App 实际验收，Swift URLSession 实现尚未在手机上验证收发。
- 历史网关版模拟器构建及容器冒烟 CI 通过；Python 19 项测试通过（这些测试不覆盖独立 App 协议实现）。
- 首次 IPA 的 arm64 编译成功，但 lipo 参数顺序错误导致打包失败；已修复。
- 独立版首轮 Swift catch 属性遮蔽编译错误已修复，提交 85c0394；最终独立版真机编译、arm64 验证、IPA 打包与上传全部通过，运行 https://github.com/Lbcheng1145/qqbot-chat-ios/actions/runs/42810570200 。产物 QQBotChat-unsigned.ipa，SHA-256：411288f8e55efeee61e33f69d63a096fbb02bfeba2f4513b4659720975cc2904。已下载并验证 SHA-256 和 Payload 包结构。

## 已知限制及后续优先项

- 当前只显示最近收到的一个会话；来源切换清空内存消息列表，无完整会话列表和本地历史持久化。
- 无自动重连、Resume、token 到期刷新及 heartbeat ACK 超时检测；断线需退出并重新登录。
- iOS 后台/锁屏可能暂停 WebSocket；没有 APNs 推送，不能保证后台消息接收。
- 目前只处理单聊及群文字事件，不提供频道 UI、附件显示/上传。
- QQ 被动回复时限、次数、审核和权限受平台限制；发送失败仅给通用提示。
- 需要真机确认 Keychain、登录、前台接收/回复、断网恢复体验及侧载签名兼容性。
- 不应宣称产品已正式上线或全链路验收完成。

## 凭证处理

用户已表示测试后自行轮换。不要将 AppSecret、GitHub Token、QQ access token 或测试用户 OpenID 写入源码、文档、提交或日志。GitHub 推送使用用户授权的临时凭证；若旧系统 Git 凭证助手覆盖凭证，单次命令使用 git -c credential.helper= 和临时 askpass。不要保存实际 Token 到 Git remote。
