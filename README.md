# QQBot Chat iOS（QQ 机器人聊天客户端）

一个直接连接 QQ 官方机器人 API 的 iOS 聊天客户端。App 内输入机器人 AppID 与 AppSecret，通过 QQ WebSocket 接收消息，不依赖自建服务器。

## 功能

- 多会话列表：未读角标、置顶、归档、静音、滑动删除、搜索
- 文本消息：Markdown 渲染、引用回复、长按复制/引用/删除
- 图片消息：最多九张连发、接收缓存、全屏查看、保存相册
- 视频消息：选择上传、内嵌播放、保存相册
- 语音消息：录音、发送、接收播放、时长显示
- 文件消息：选择任意文件发送与分享
- 按钮消息：渲染键盘按钮、接收点击交互
- 表情面板、QQ 表情标记解析、自定义聊天背景
- 会话与技术细节：底部标签栏、Liquid Glass 输入栏、日期分组、发送状态、草稿、深色模式、字体大小、图片缩放、历史分页
- 断线重连：心跳 ACK 检测、指数退避、Gateway Resume、网络恢复重连

## 安装

1. 从 GitHub Actions 下载 `QQBotChat-unsigned-IPA` 产物，解压得到 IPA。
2. 使用侧载工具重签安装，要求 **iOS 26+**、arm64。无签名 IPA 不能由标准 iOS 直接安装。
3. 打开 App，输入机器人 AppID 与 AppSecret，等待状态显示“已连接”。
4. 先在 QQ 给机器人发一条消息建立会话，再在 App 内回复。

请求权限：麦克风（语音消息）、相册写入（保存图片/视频）。

## 构建

GitHub Actions 在每次推送时执行：

- Ubuntu：Python 网关测试、容器登录冒烟测试
- macOS：iOS Simulator 编译、真机 arm64 Release 编译、无签名 IPA 打包与 SHA-256

产物：`QQBotChat-unsigned.ipa` 与校验文件。

## 当前限制

- 单聊、群聊、频道消息均支持，但频道管理类 API（角色、权限、禁言、论坛、语音房）未接入。
- 单聊/群聊没有官方历史消息接口，断线期间依赖 Resume 补发；频道可手动拉取最近 50 条历史。
- iOS 锁屏或长时间后台会暂停 WebSocket，没有 APNs 推送。
- 消息删除仅删除本地记录，不会撤回 QQ 侧消息。
- 发送依赖 QQ 被动回复窗口（由用户最近一条消息触发）。

## 官方资料

- [QQ 消息收发概述](https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/overview.html)
- [QQ access_token](https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/access-token.html)
- [腾讯 BotPy SDK](https://github.com/tencent-connect/botpy)