# QQ Bot API 能力矩阵

依据：腾讯官方 `botpy` SDK `api.py` 的全量方法，以及 QQ 开放平台文档。标注“已接入”表示 App 内可直接使用；“不适用”表示该能力属于频道后台管理或语音房控制，与聊天客户端场景无关；“待接入”表示 API 可用但客户端尚未做界面。

## 消息（核心聊天）

| API | 状态 | 说明 |
| --- | --- | --- |
| post_c2c_message | 已接入 | 单聊文本/富媒体发送 |
| post_group_message | 已接入 | 群聊文本/富媒体发送 |
| post_message（频道） | 已接入 | 频道消息发送 |
| post_c2c_file | 已接入 | 单聊富媒体上传（图片/视频/语音/文件） |
| post_group_file | 已接入 | 群聊富媒体上传 |
| 频道富媒体上传 | 已接入 | `/channels/{id}/files` |
| recall_message（频道） | 已接入 | 长按频道消息撤回 |
| post_keyboard_message | 待接入 | 发送带按钮的频道消息 |
| patch_guild_message | 待接入 | 编辑频道消息 |
| get_message（频道） | 待接入 | 拉取单条频道消息 |
| create_dms / post_dms | 不适用 | 私信频道会话，需 guild 场景 |
| on_interaction_result | 待接入 | 按钮点击结果回执 |
| get_ws_url | 已接入 | 获取 WebSocket 网关 |

## 用户与频道

| API | 状态 | 说明 |
| --- | --- | --- |
| me | 已接入 | 设置页显示机器人名称 |
| me_guilds | 待接入 | 机器人加入的频道列表 |
| get_guild / get_channels / get_channel | 待接入 | 频道与子频道信息 |
| get_guild_members / get_guild_member | 待接入 | 频道成员列表 |
| get_guild_roles / create/update/delete_guild_role | 不适用 | 角色管理后台能力 |
| get_voice_members | 不适用 | 语音频道成员 |
| create/update/delete_channel | 不适用 | 频道结构管理 |
| channel user/role permissions | 不适用 | 权限覆盖 |
| create_announce / delete_announce | 待接入 | 频道公告 |
| get_permissions / post_permission_demand | 不适用 | API 权限申请 |
| get_schedules / create/update/delete_schedule | 待接入 | 频道日程 |
| get_threads / post_thread / delete_thread | 不适用 | 论坛频道 |
| put_reaction / delete_reaction / get_reaction_users | 待接入 | 频道消息表情回应 |
| put_pin / delete_pin / get_pins | 待接入 | 频道消息置顶 |
| mute_all / mute_member / mute_multi_member 等 | 不适用 | 频道禁言管理 |
| update_audio / on_microphone / off_microphone | 不适用 | 语音房麦克风控制 |

## 事件（WebSocket）

| 事件 | 状态 | 说明 |
| --- | --- | --- |
| C2C_MESSAGE_CREATE | 已接入 | 单聊消息 |
| GROUP_AT_MESSAGE_CREATE | 已接入 | 群 @机器人消息 |
| GROUP_MESSAGE_CREATE | 已接入 | 群消息（需权限） |
| AT_MESSAGE_CREATE | 已接入 | 频道 @机器人消息 |
| MESSAGE_CREATE | 已接入 | 频道消息（私域） |
| INTERACTION_CREATE | 已接入 | 按钮点击 |
| MESSAGE_REACTION_ADD/REMOVE | 待接入 | 频道表情回应事件 |
| GUILD_CREATE/UPDATE/DELETE | 不适用 | 频道结构变化 |

## 说明

- C2C 与群聊只提供消息收发、富媒体与按钮，不提供成员列表、撤回、置顶、表情回应等频道级能力。
- 频道管理类 API 需要机器人在对应频道拥有管理权限；当前客户端没有频道选择页，频道会话由收到的事件自动建立。
- 后续会优先接入 `me_guilds`、`get_guild_members`、`put_reaction`、`put_pin`、`create_announce` 这些与聊天体验直接相关的频道能力。
