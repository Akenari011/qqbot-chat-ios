import SwiftUI
import Observation
import Security
import PhotosUI
import Network
import UIKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers

@main
struct QQBotChatApp: App {
    var body: some Scene { WindowGroup { RootView() } }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: String
    var text: String
    var timestamp: String
    let fromBot: Bool
    var authorName: String
    var imageURL: String?
    var localImage: String?
    var videoURL: String?
    var videoFile: String?
    var audioURL: String?
    var audioFile: String?
    var fileLocal: String?
    var fileName: String?
    var quotedText: String?
    var quotedID: String?
    var duration: Double?
    var authorID: String?
    var authorAvatarURL: String? = nil
    var reactions: [String: Int]? = nil
    var buttons: [String]?
    var status: String?

    init(id: String, text: String, timestamp: String, fromBot: Bool, authorName: String, imageURL: String? = nil, localImage: String? = nil, videoURL: String? = nil, videoFile: String? = nil, audioURL: String? = nil, audioFile: String? = nil, fileLocal: String? = nil, fileName: String? = nil, quotedText: String? = nil, quotedID: String? = nil, duration: Double? = nil, authorID: String? = nil, authorAvatarURL: String? = nil, reactions: [String: Int]? = nil, buttons: [String]? = nil, status: String? = nil) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.fromBot = fromBot
        self.authorName = authorName
        self.imageURL = imageURL
        self.localImage = localImage
        self.videoURL = videoURL
        self.videoFile = videoFile
        self.audioURL = audioURL
        self.audioFile = audioFile
        self.fileLocal = fileLocal
        self.fileName = fileName
        self.quotedText = quotedText
        self.quotedID = quotedID
        self.duration = duration
        self.authorID = authorID
        self.authorAvatarURL = authorAvatarURL
        self.reactions = reactions
        self.buttons = buttons
        self.status = status
    }

    var isImage: Bool { imageURL != nil || localImage != nil }
    var isVideo: Bool { videoURL != nil || videoFile != nil }
    var isAudio: Bool { audioURL != nil || audioFile != nil }
    var isFile: Bool { fileLocal != nil }
    var summary: String {
        if isImage { return "[图片]" }
        if isVideo { return "[视频]" }
        if isAudio { return "[语音]" }
        if isFile { return "[文件] " + (fileName ?? "") }
        return text
    }
    var date: Date { ISO8601DateFormatter().date(from: timestamp) ?? .now }
}

struct GuildInfo: Identifiable {
    let id: String
    let name: String
}

struct Conversation: Identifiable, Codable {
    var id: String
    var scene: String
    var name: String
    var lastText: String
    var lastTimestamp: String
    var unread: Int
    var messages: [ChatMessage]
    var replyID: String
    var replySeq: Int
    var pinned: Bool?
    var archived: Bool?
    var muted: Bool?
    var remark: String? = nil
    var avatarPath: String? = nil
    var autoAvatarURL: String? = nil
    var lastDate: Date { ISO8601DateFormatter().date(from: lastTimestamp) ?? .now }
    var isGroup: Bool { scene == "group" }
    var isChannel: Bool { scene == "channel" }
}

private struct LoginInput: Codable { let username: String; let password: String }

private enum CredentialStore {
    static let service = "org.example.qqbotchat.bot-credentials"
    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
    static func clear() { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
}

@MainActor @Observable
final class ChatStore {
    var conversations: [Conversation] = []
    var isLoggedIn = false
    var loggingIn = false
    var status = "未连接"
    var error: String?
    var username = ""
    var password = ""
    var activeConversationID: String?
    var sendingConversationID: String?
    var drafts: [String: String] = UserDefaults.standard.dictionary(forKey: "drafts") as? [String: String] ?? [:]
    var botName = ""
    var botID = ""
    var guilds: [GuildInfo] = []
    var guildMembers: [String: [String]] = [:]
    var guildChannels: [String: [String]] = [:]
    var schedules: [String] = []
    var pins: [String] = []
    var reactionUsers: [String] = []
    var logs: [String] = []

    var logText: String { logs.joined(separator: "\n") }

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        logs.append("[" + formatter.string(from: Date()) + "] " + message)
        if logs.count > 2000 { logs.removeFirst(logs.count - 2000) }
    }
    var appearance: String = UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance") }
    }
    var showArchived: Bool = UserDefaults.standard.bool(forKey: "showArchived") {
        didSet { UserDefaults.standard.set(showArchived, forKey: "showArchived") }
    }
    var fontScale: Double = UserDefaults.standard.double(forKey: "fontScale") == 0 ? 1.0 : UserDefaults.standard.double(forKey: "fontScale") {
        didSet { UserDefaults.standard.set(fontScale, forKey: "fontScale") }
    }
    var chatBackground: String = UserDefaults.standard.string(forKey: "chatBackground") ?? "default" {
        didSet { UserDefaults.standard.set(chatBackground, forKey: "chatBackground") }
    }
    var mentionSyntax: Bool = (UserDefaults.standard.object(forKey: "mentionSyntax") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(mentionSyntax, forKey: "mentionSyntax") }
    }
    var chatBackgroundImage: String? = UserDefaults.standard.string(forKey: "chatBackgroundImage")

    private var token = ""
    private var tokenExpires = Date.distantPast
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var sequence: Int?
    private var sessionID: String?
    private var lastAck = Date()
    private var shouldRun = false
    private var reconnectAttempt = 0
    private var connecting = false
    private var sendChain: Task<Void, Never>?
    private var networkMonitor: NWPathMonitor?

    var stickers: [String] = []
    private var stickersURL: URL { documents.appendingPathComponent("stickers", isDirectory: true) }
    private var stickerIndexURL: URL { stickersURL.appendingPathComponent("index.json") }

    private let imageCache = NSCache<NSString, UIImage>()
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var stateURL: URL { documents.appendingPathComponent("conversations.json") }
    private var imagesURL: URL { documents.appendingPathComponent("images", isDirectory: true) }

    init() {
        if let saved = CredentialStore.load(), let data = saved.data(using: .utf8), let pair = try? JSONDecoder().decode(LoginInput.self, from: data) {
            username = pair.username
            password = pair.password
        }
        loadConversations()
        try? FileManager.default.createDirectory(at: stickersURL, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: stickerIndexURL),
           let names = try? JSONDecoder().decode([String].self, from: data) {
            stickers = names.filter { $0 == ($0 as NSString).lastPathComponent && FileManager.default.fileExists(atPath: stickersURL.appendingPathComponent($0).path) }
        }
        try? FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    }

    // MARK: - Lifecycle

    func start() {
        startNetworkMonitor()
        guard !isLoggedIn, !shouldRun, !username.isEmpty, !password.isEmpty else { return }
        Task { await login() }
    }

    func stop() {
        shouldRun = false
        reconnectTask?.cancel()
        receiver?.cancel()
        heartbeat?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        networkMonitor?.cancel()
        networkMonitor = nil
    }

    func login() async {
        guard !username.isEmpty, !password.isEmpty else { error = "请输入 AppID 和 AppSecret"; return }
        stop()
        loggingIn = true
        defer { loggingIn = false }
        shouldRun = true
        log("登录开始 appId=" + username)
        do {
            try await openSocket(resume: false)
            isLoggedIn = true
            error = nil
            log("登录成功")
            if let data = try? JSONEncoder().encode(LoginInput(username: username, password: password)), let text = String(data: data, encoding: .utf8) {
                CredentialStore.save(text)
            }
            startNetworkMonitor()
            await loadProfile()
        } catch {
            isLoggedIn = false
            self.error = "QQ 登录失败，请检查机器人凭证和网络。"
            log("登录失败 " + String(describing: error))
            stop()
        }
    }

    func loadGuilds() async {
        do {
            let raw = try await apiAny("/users/@me/guilds")
            guard let list = raw as? [[String: Any]] else { return }
            guilds = list.compactMap { item in
                guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                return GuildInfo(id: id, name: name)
            }
        } catch {
            self.error = "频道列表获取失败，机器人可能未加入任何频道。"
        }
    }

    func loadChannels(guildID: String) async {
        do {
            let raw = try await apiAny("/guilds/" + guildID + "/channels")
            guard let list = raw as? [[String: Any]] else { return }
            guildChannels[guildID] = list.compactMap { item in
                guard let name = item["name"] as? String else { return nil }
                return name
            }
        } catch {
            self.error = "子频道获取失败，可能需要频道权限。"
        }
    }

    func loadMembers(guildID: String) async {
        do {
            let encoded = guildID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? guildID
            let raw = try await apiAny("/guilds/" + encoded + "/members?limit=100")
            guard let list = raw as? [[String: Any]] else { return }
            guildMembers[guildID] = list.compactMap { item in
                (item["username"] as? String) ?? (item["nick"] as? String)
            }
        } catch {
            self.error = "成员列表获取失败，需要频道成员查看权限。"
        }
    }

    func react(conversationID: String, messageID: String, emojiID: String = "128077") async {
        guard conversation(conversationID)?.scene == "channel" else {
            error = "表情回应仅支持频道消息。"
            return
        }
        let cid = conversationID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? conversationID
        do {
            _ = try await apiAny("/channels/" + cid + "/messages/" + messageID + "/reactions/1/" + emojiID, method: "PUT")
            error = nil
        } catch {
            self.error = "表情回应失败，可能需要频道权限。"
        }
    }

    func editMessage(conversationID: String, messageID: String, newText: String) async {
        guard conversation(conversationID)?.scene == "channel" else {
            error = "当前仅频道消息支持编辑。"
            return
        }
        let cid = conversationID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? conversationID
        var request = URLRequest(url: URL(string: "https://api.bot.qq.com/channels/" + cid + "/messages/" + messageID)!)
        request.httpMethod = "PATCH"
        request.setValue("QQBot " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["content": newText])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            if let index = conversations.firstIndex(where: { $0.id == conversationID }),
               let mi = conversations[index].messages.firstIndex(where: { $0.id == messageID }) {
                conversations[index].messages[mi].text = newText
                if let last = conversations[index].messages.last, last.id == messageID {
                    conversations[index].lastText = last.summary
                }
                saveConversations()
            }
            error = nil
        } catch {
            self.error = "编辑失败，可能需要频道权限。"
        }
    }

    func publishAnnounce(conversationID: String, messageID: String) async {
        guard conversation(conversationID)?.scene == "channel" else {
            error = "公告仅支持频道消息。"
            return
        }
        do {
            if guilds.isEmpty { await loadGuilds() }
            for guild in guilds {
                let raw = try await apiAny("/guilds/" + guild.id + "/channels")
                if let list = raw as? [[String: Any]], list.contains(where: { ($0["id"] as? String) == conversationID }) {
                    _ = try await apiAny("/guilds/" + guild.id + "/announces", method: "POST", body: ["channel_id": conversationID, "message_id": messageID])
                    error = "已发布为频道公告。"
                    return
                }
            }
            error = "未找到该频道所属服务器。"
        } catch {
            self.error = "公告发布失败，可能需要频道权限。"
        }
    }

    func deleteAnnounce(conversationID: String, messageID: String) async {
        guard conversation(conversationID)?.scene == "channel" else {
            error = "公告仅支持频道。"
            return
        }
        do {
            if guilds.isEmpty { await loadGuilds() }
            for guild in guilds {
                let raw = try await apiAny("/guilds/" + guild.id + "/channels")
                if let list = raw as? [[String: Any]], list.contains(where: { ($0["id"] as? String) == conversationID }) {
                    _ = try await apiAny("/guilds/" + guild.id + "/announces/" + messageID, method: "DELETE")
                    error = "已取消公告。"
                    return
                }
            }
            error = "未找到该频道所属服务器。"
        } catch {
            self.error = "取消公告失败，可能需要频道权限。"
        }
    }

    func loadReactionUsers(conversationID: String, messageID: String) async {
        guard conversation(conversationID)?.scene == "channel" else { return }
        let cid = conversationID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? conversationID
        do {
            let raw = try await apiAny("/channels/" + cid + "/messages/" + messageID + "/reactions/1/128077?limit=20")
            if let dict = raw as? [String: Any], let users = dict["users"] as? [[String: Any]] {
                reactionUsers = users.compactMap { $0["username"] as? String }
            }
        } catch {
            self.error = "点赞用户获取失败。"
        }
    }

    func sendKeyboardMessage(_ text: String, to conversationID: String) async {
        guard conversation(conversationID)?.scene == "channel" else {
            error = "按钮消息仅支持频道。"
            return
        }
        let keyboard: [String: Any] = [
            "content": [
                "rows": [[
                    "buttons": [[
                        "id": "1",
                        "render_data": ["label": "确认", "visited_label": "已确认", "style": 1],
                        "action": ["type": 2, "permission": ["type": 2], "data": "confirm", "unsupported_tip": "当前客户端不支持"]
                    ]]
                ]]
            ]
        ]
        let body: [String: Any] = ["content": text, "keyboard": keyboard]
        let cid = conversationID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? conversationID
        do {
            let result = try await apiAny("/channels/" + cid + "/messages", method: "POST", body: body)
            if let dict = result as? [String: Any], let messageID = dict["id"] as? String,
               let index = conversations.firstIndex(where: { $0.id == conversationID }) {
                let message = ChatMessage(id: messageID, text: text, timestamp: ISO8601DateFormatter().string(from: .now), fromBot: true, authorName: "QQ 机器人", buttons: ["确认"], status: "sent")
                conversations[index].messages.append(message)
                conversations[index].lastText = text
                conversations[index].lastTimestamp = message.timestamp
                saveConversations()
            }
            error = nil
        } catch {
            self.error = "按钮消息发送失败，可能需要频道权限。"
        }
    }

    func removeReaction(conversationID: String, messageID: String, emojiID: String = "128077") async {
        guard conversation(conversationID)?.scene == "channel" else {
            error = "表情回应仅支持频道消息。"
            return
        }
        let cid = conversationID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? conversationID
        do {
            _ = try await apiAny("/channels/" + cid + "/messages/" + messageID + "/reactions/1/" + emojiID, method: "DELETE")
            error = "已取消表情回应。"
        } catch {
            self.error = "取消回应失败，可能需要频道权限。"
        }
    }

    func unpinMessage(conversationID: String, messageID: String) async {
        guard conversation(conversationID)?.scene == "channel" else {
            error = "置顶仅支持频道消息。"
            return
        }
        let cid = conversationID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? conversationID
        do {
            _ = try await apiAny("/channels/" + cid + "/pins/" + messageID, method: "DELETE")
            error = "已取消置顶。"
        } catch {
            self.error = "取消置顶失败，可能需要频道权限。"
        }
    }

    func loadPins(conversationID: String) async {
        guard conversation(conversationID)?.scene == "channel" else { return }
        let cid = conversationID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? conversationID
        do {
            let raw = try await apiAny("/channels/" + cid + "/pins")
            if let dict = raw as? [String: Any], let list = dict["message_ids"] as? [String] {
                pins = list
            } else if let list = raw as? [String] {
                pins = list
            }
        } catch {
            self.error = "置顶列表获取失败。"
        }
    }

    func fetchHistory(conversationID: String) async {
        guard let conversation = conversation(conversationID) else { return }
        guard conversation.scene == "channel" else {
            error = "QQ 官方未开放单聊/群聊历史消息接口，断线期间只能依赖 Resume 补发。"
            return
        }
        let cid = conversationID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? conversationID
        do {
            let raw = try await apiAny("/channels/" + cid + "/messages?limit=50")
            guard let list = raw as? [[String: Any]] else { return }
            var fetched: [ChatMessage] = []
            for item in list {
                guard let id = item["id"] as? String else { continue }
                let author = item["author"] as? [String: Any] ?? [:]
                let text = item["content"] as? String ?? ""
                let timestamp = item["timestamp"] as? String ?? ""
                let name = author["username"] as? String ?? "频道成员"
                fetched.append(ChatMessage(id: id, text: text, timestamp: timestamp, fromBot: false, authorName: name))
            }
            guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
            let existing = Set(conversations[index].messages.map { $0.id })
            let merged = conversations[index].messages + fetched.filter { !existing.contains($0.id) }
            conversations[index].messages = merged.sorted { $0.date < $1.date }
            if let last = conversations[index].messages.last {
                conversations[index].lastText = last.summary
                conversations[index].lastTimestamp = last.timestamp
            }
            saveConversations()
            error = "已拉取 \(fetched.count) 条历史消息。"
        } catch {
            self.error = "历史消息拉取失败，可能需要频道权限。"
        }
    }

    func loadSchedules(channelID: String) async {
        let cid = channelID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? channelID
        do {
            let raw = try await apiAny("/channels/" + cid + "/schedules")
            guard let list = raw as? [[String: Any]] else { return }
            schedules = list.compactMap { item in
                guard let name = item["name"] as? String else { return nil }
                let start = (item["start_timestamp"] as? String) ?? (item["start_time"] as? String) ?? ""
                return name + (start.isEmpty ? "" : "  " + start)
            }
        } catch {
            self.error = "日程获取失败，可能需要频道权限。"
        }
    }

    func pinMessage(conversationID: String, messageID: String) async {
        guard conversation(conversationID)?.scene == "channel" else {
            error = "置顶仅支持频道消息。"
            return
        }
        let cid = conversationID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? conversationID
        do {
            _ = try await apiAny("/channels/" + cid + "/pins/" + messageID, method: "PUT")
            error = "已置顶该消息。"
        } catch {
            self.error = "置顶失败，可能需要频道权限。"
        }
    }

    func loadProfile() async {
        do {
            let me = try await api("/users/@me")
            botName = me["username"] as? String ?? ""
            botID = me["id"] as? String ?? ""
        } catch {
            // Profile is optional; keep the chat usable.
        }
    }

    func recallMessage(conversationID: String, messageID: String) async {
        guard let conversation = conversation(conversationID),
              let message = conversation.messages.first(where: { $0.id == messageID }) else { return }
        guard message.fromBot, message.status == "sent" else {
            error = "仅能撤回 QQ 接口已确认发送成功的机器人消息。"
            return
        }
        let encoded = conversationID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? conversationID
        let path: String
        switch conversation.scene {
        case "c2c":
            path = "/v2/users/" + encoded + "/messages/" + messageID
        case "group":
            path = "/v2/groups/" + encoded + "/messages/" + messageID
        case "channel":
            path = "/channels/" + encoded + "/messages/" + messageID + "?hidetip=false"
        default:
            path = "/dms/" + encoded + "/messages/" + messageID + "?hidetip=false"
        }
        log("撤回消息 " + conversation.scene + " " + String(messageID.suffix(8)))
        do {
            try await apiVoid(path, method: "DELETE")
            deleteMessage(conversationID: conversationID, messageID: messageID)
            error = nil
            log("撤回成功")
        } catch {
            self.error = "撤回失败：仅能撤回 2 分钟内、机器人自己发送的消息。"
        }
    }

    func reconnectIfNeeded() {
        guard shouldRun, !connecting else { return }
        let stale = Date().timeIntervalSince(lastAck) > 45 || status != "已连接"
        if socket == nil || stale {
            log("前台恢复，重连（ACK 间隔 " + String(Int(Date().timeIntervalSince(lastAck))) + "s）")
            reconnect()
        }
        // QQ 单聊/群聊无官方历史接口，只有频道能补拉。
        Task {
            for conversation in conversations where conversation.scene == "channel" {
                await fetchHistory(conversationID: conversation.id)
            }
        }
    }

    func reconnect() {
        guard shouldRun else { return }
        reconnectTask?.cancel()
        receiver?.cancel()
        heartbeat?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        status = "正在重新连接"
        Task {
            do { try await openSocket(resume: sessionID != nil && sequence != nil) }
            catch { scheduleReconnect() }
        }
    }

    func logout() {
        stop()
        isLoggedIn = false
        token = ""
        sessionID = nil
        sequence = nil
        conversations = []
        activeConversationID = nil
    }

    // MARK: - Networking

    private func api(_ path: String, body: [String: Any]? = nil, authorized: Bool = true) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.bot.qq.com" + path)!)
        request.httpMethod = body == nil ? "GET" : "POST"
        if authorized { request.setValue("QQBot " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (result["code"] as? Int ?? result["err_code"] as? Int ?? 0) == 0 else {
            throw URLError(.badServerResponse)
        }
        return result
    }

    private func apiVoid(_ path: String, method: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.bot.qq.com" + path)!)
        request.httpMethod = method
        request.setValue("QQBot " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data.prefix(200), encoding: .utf8) ?? ""
            log("HTTP " + String((response as? HTTPURLResponse)?.statusCode ?? 0) + " " + method + " " + path + " " + detail)
            throw URLError(.badServerResponse)
        }
    }

    private func apiAny(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
        var request = URLRequest(url: URL(string: "https://api.bot.qq.com" + path)!)
        request.httpMethod = method
        request.setValue("QQBot " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func packet(_ value: [String: Any]) async throws {
        guard let socket else { throw URLError(.networkConnectionLost) }
        try await socket.send(.data(JSONSerialization.data(withJSONObject: value)))
    }

    private func refreshToken(force: Bool = false) async throws {
        if !force, !token.isEmpty, Date() < tokenExpires { return }
        let auth = try await api("/app/getAppAccessToken", body: ["appId": username, "clientSecret": password], authorized: false)
        guard let access = auth["access_token"] as? String else { throw URLError(.userAuthenticationRequired) }
        token = access
        log("access_token 已刷新")
        let raw = auth["expires_in"]
        let seconds = (raw as? String).flatMap(Double.init) ?? (raw as? Double) ?? (raw as? Int).map(Double.init) ?? 7200
        tokenExpires = Date().addingTimeInterval(max(60, seconds - 300))
    }

    private func openSocket(resume: Bool) async throws {
        guard !connecting else { return }
        connecting = true
        defer { connecting = false }
        try await refreshToken()
        let gateway = try await api("/gateway/bot")
        guard let address = gateway["url"] as? String, let url = URL(string: address), url.scheme == "wss" else { throw URLError(.badURL) }
        let ws = URLSession.shared.webSocketTask(with: url)
        socket = ws
        ws.resume()
        log(resume ? "WebSocket 重连（Resume）" : "WebSocket 连接")
        status = resume ? "正在恢复会话" : "连接中"
        receiver = Task { await receive(resume: resume) }
    }

    private func receive(resume: Bool) async {
        do {
            while !Task.isCancelled, let socket {
                let raw = try await socket.receive()
                let data: Data
                switch raw {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: continue
                }
                guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let seq = event["s"] as? Int { sequence = seq }
                let op = event["op"] as? Int ?? -1
                let payload = event["d"] as? [String: Any] ?? [:]

                if op == 10 {
                    lastAck = Date()
                    let interval = (payload["heartbeat_interval"] as? Double ?? 30000) / 1000
                    if resume, let sid = sessionID, let seq = sequence {
                        try await packet(["op": 6, "d": ["token": "QQBot " + token, "session_id": sid, "seq": seq]])
                    } else {
                        try await packet(["op": 2, "d": ["token": "QQBot " + token, "intents": (1 << 10) | (1 << 25) | (1 << 26) | (1 << 30), "shard": [0, 1], "properties": [:]]])
                    }
                    startHeartbeat(interval: interval)
                } else if op == 11 {
                    lastAck = Date()
                } else if op == 9 {
                    sessionID = nil
                    sequence = nil
                    throw URLError(.networkConnectionLost)
                } else if op == 7 {
                    throw URLError(.networkConnectionLost)
                }

                guard let kind = event["t"] as? String else { continue }
                if kind == "READY" {
                    sessionID = payload["session_id"] as? String
                    reconnectAttempt = 0
                    status = "已连接"
                    log("READY session=" + String((sessionID ?? "").suffix(8)))
                    retryFirstFailedMessage()
                } else if kind == "RESUMED" {
                    reconnectAttempt = 0
                    status = "已连接"
                    log("RESUMED 会话已恢复")
                } else if ["C2C_MESSAGE_CREATE", "GROUP_AT_MESSAGE_CREATE", "GROUP_MESSAGE_CREATE", "AT_MESSAGE_CREATE", "MESSAGE_CREATE"].contains(kind) {
                    handleIncoming(kind: kind, payload: payload)
                } else if kind == "INTERACTION_CREATE" {
                    handleInteraction(payload)
                } else if kind == "MESSAGE_REACTION_ADD" || kind == "MESSAGE_REACTION_REMOVE" {
                    handleReactionEvent(kind: kind, payload: payload)
                }
            }
        } catch {
            guard shouldRun, !Task.isCancelled else { return }
            log("WebSocket 断开 " + String(describing: error))
            scheduleReconnect()
        }
    }

    private func startHeartbeat(interval: Double) {
        heartbeat?.cancel()
        lastAck = Date()
        heartbeat = Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(interval))
                    if Date().timeIntervalSince(self.lastAck) > interval * 2.5 { throw URLError(.timedOut) }
                    try await self.packet(["op": 1, "d": self.sequence.map { $0 as Any } ?? NSNull()])
                }
            } catch {
                if !Task.isCancelled { self.socket?.cancel(with: .goingAway, reason: nil) }
            }
        }
    }

    private func scheduleReconnect() {
        guard shouldRun else { return }
        heartbeat?.cancel()
        receiver?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        reconnectAttempt += 1
        let delay = min(30, pow(2, Double(reconnectAttempt)))
        log("计划重连 attempt=" + String(reconnectAttempt) + " delay=" + String(Int(delay)))
        status = "连接断开，\(Int(delay)) 秒后重连"
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard self.shouldRun, self.socket == nil else { return }
            do {
                try await self.openSocket(resume: self.sessionID != nil && self.sequence != nil)
            } catch {
                self.scheduleReconnect()
            }
        }
    }

    private func startNetworkMonitor() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, self.shouldRun, self.socket == nil else { return }
                self.reconnectTask?.cancel()
                do { try await self.openSocket(resume: self.sessionID != nil && self.sequence != nil) }
                catch { self.scheduleReconnect() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "qqbot.network"))
        networkMonitor = monitor
    }

    // MARK: - Incoming messages

    private func cleanedContent(_ raw: String, payload: [String: Any]) -> String {
        var map: [String: String] = [:]
        if let mentions = payload["mentions"] as? [[String: Any]] {
            for mention in mentions {
                if let id = (mention["id"] as? String) ?? (mention["user_openid"] as? String),
                   let name = (mention["username"] as? String) ?? (mention["nick"] as? String) {
                    map[id] = name
                }
            }
        }
        let pattern = "<@!?([A-Za-z0-9_-]+)>"
        var result = raw
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = raw as NSString
            for match in regex.matches(in: raw, range: NSRange(location: 0, length: ns.length)).reversed() {
                let id = ns.substring(with: match.range(at: 1))
                let name = map[id] ?? "成员 " + String(id.suffix(6))
                result = result.replacingOccurrences(of: ns.substring(with: match.range), with: "@" + name)
            }
        }
        let facePattern = "<faceType=[0-9]+,faceId=\"?([0-9]+)\"?[^>]*>"
        if let faceRegex = try? NSRegularExpression(pattern: facePattern) {
            let ns = result as NSString
            for match in faceRegex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                let idString = ns.substring(with: match.range(at: 1))
                let emoji = QQFaceCatalog.label(Int(idString) ?? -1)
                result = result.replacingOccurrences(of: ns.substring(with: match.range), with: emoji)
            }
        }
        return result
    }

    private var faceMap: [Int: String] {
        [
            0: "🙂", 1: "😕", 2: "😍", 3: "😳", 4: "😎", 5: "😢", 6: "😊", 7: "🤐",
            8: "😴", 9: "😭", 10: "😅", 11: "😡", 12: "😜", 13: "😁", 14: "😲",
            15: "😞", 16: "😎", 17: "😰", 18: "😫", 19: "🤢", 20: "😏", 21: "😊",
            22: "😒", 23: "😤", 24: "😋", 25: "😪", 26: "😱", 27: "😓", 28: "😄",
            29: "😌", 30: "😤", 31: "🤬", 32: "😕", 33: "🤫", 34: "😵", 35: "😖",
            36: "😞", 37: "☠️", 38: "🔨", 39: "👋", 40: "😅", 41: "😏", 42: "👏",
            43: "😳", 44: "😏", 45: "😤", 46: "😤", 47: "😪", 48: "😒", 49: "🥺",
            50: "🥺", 51: "😏", 52: "😘", 53: "😱", 54: "🥺", 55: "🔪", 56: "🍉",
            57: "🍺", 58: "🏀", 59: "🏓", 60: "☕", 61: "🍚", 62: "🐷", 63: "🌹",
            64: "🥀", 65: "❤️", 66: "❤️", 67: "💔", 68: "🎂", 69: "⚡", 70: "💣",
            71: "🔪", 72: "⚽", 73: "🐞", 74: "💩", 75: "🌙", 76: "☀️", 77: "🎁",
            78: "🤗", 79: "👍", 80: "👎", 81: "🤝", 82: "✌️", 83: "🙏", 84: "😏",
            85: "👊", 86: "👎", 87: "😘", 88: "❌", 89: "👌", 90: "❤️", 91: "😘",
            92: "🕺", 93: "😨", 94: "😤", 95: "🌀", 96: "🙇", 97: "😳", 98: "🤸",
            99: "👋", 100: "😆", 101: "🕺", 102: "😘", 103: "☯️", 104: "☯️", 105: "🥺"
        ]
    }

    private func handleReactionEvent(kind: String, payload: [String: Any]) {
        guard let target = payload["target"] as? [String: Any],
              let messageID = target["id"] as? String,
              let channelID = payload["channel_id"] as? String else { return }
        let emoji = payload["emoji"] as? [String: Any] ?? [:]
        let emojiID = emoji["id"] as? String ?? "👍"
        let adding = kind == "MESSAGE_REACTION_ADD"
        guard let ci = conversations.firstIndex(where: { $0.id == channelID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else {
            log("收到表情回应但未找到本地消息 " + String(messageID.suffix(6)))
            return
        }
        var reactions = conversations[ci].messages[mi].reactions ?? [:]
        let current = reactions[emojiID] ?? 0
        let next = max(0, current + (adding ? 1 : -1))
        if next == 0 { reactions.removeValue(forKey: emojiID) } else { reactions[emojiID] = next }
        conversations[ci].messages[mi].reactions = reactions.isEmpty ? nil : reactions
        saveConversations()
        log((adding ? "表情回应 +" : "表情回应 -") + emojiID + " " + String(messageID.suffix(6)))
    }

    func fetchChannelNameIfNeeded(_ id: String) async {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              conversations[index].scene == "channel",
              conversations[index].remark?.isEmpty ?? true else { return }
        guard conversations[index].name.hasPrefix("频道 ") else { return }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        do {
            let raw = try await apiAny("/channels/" + encoded)
            guard let dict = raw as? [String: Any],
                  let name = dict["name"] as? String, !name.isEmpty,
                  let current = conversations.firstIndex(where: { $0.id == id }) else { return }
            conversations[current].name = name
            saveConversations()
            log("子频道名已获取 " + name)
        } catch {
            log("子频道信息获取失败，继续使用默认名称")
        }
    }

    private func handleIncoming(kind: String, payload: [String: Any]) {
        let author = payload["author"] as? [String: Any] ?? [:]
        let isChannel = kind == "AT_MESSAGE_CREATE" || kind == "MESSAGE_CREATE"
        let isGroup = kind == "GROUP_AT_MESSAGE_CREATE" || kind == "GROUP_MESSAGE_CREATE"
        let target: String
        if isChannel {
            target = payload["channel_id"] as? String ?? ""
        } else if isGroup {
            target = payload["group_openid"] as? String ?? ""
        } else {
            target = author["user_openid"] as? String ?? ""
        }
        guard !target.isEmpty, let id = payload["id"] as? String else { return }
        let conversationName: String
        if isChannel {
            conversationName = "频道 " + String(target.suffix(6))
        } else if isGroup {
            conversationName = "群聊 " + String(target.suffix(6))
        } else {
            conversationName = author["username"] as? String ?? "QQ 用户"
        }
        let memberID = author["member_openid"] as? String ?? author["id"] as? String ?? ""
        let authorName: String
        if isChannel || isGroup {
            if let username = author["username"] as? String, !username.isEmpty {
                authorName = username
            } else if !memberID.isEmpty {
                authorName = "成员 " + String(memberID.suffix(6))
            } else {
                authorName = "成员"
            }
        } else {
            authorName = conversationName
        }
        let content = cleanedContent(payload["content"] as? String ?? "", payload: payload)
        let attachments = payload["attachments"] as? [[String: Any]] ?? []
        let attachment = attachments.first
        let remote = attachment?["url"] as? String
        let contentType = (attachment?["content_type"] as? String ?? "").lowercased()
        let fileName = (attachment?["filename"] as? String ?? "").lowercased()
        let isVideo = contentType.hasPrefix("video") || fileName.hasSuffix(".mp4") || fileName.hasSuffix(".mov")
        let isAudio = contentType.hasPrefix("audio") || fileName.hasSuffix(".silk") || fileName.hasSuffix(".amr") || fileName.hasSuffix(".mp3")
        let timestamp = payload["timestamp"] as? String ?? ISO8601DateFormatter().string(from: .now)
        let reference = payload["message_reference"] as? [String: Any]
        let quotedID = reference?["message_id"] as? String
        let keyboard = payload["keyboard"] as? [String: Any]
        let keyboardContent = keyboard?["content"] as? [String: Any]
        let rows = keyboardContent?["rows"] as? [[String: Any]] ?? []
        var buttonLabels: [String] = []
        for row in rows {
            for button in row["buttons"] as? [[String: Any]] ?? [] {
                if let render = button["render_data"] as? [String: Any], let label = render["label"] as? String {
                    buttonLabels.append(label)
                }
            }
        }
        let authorID = author["id"] as? String ?? ""
        let memberOpenID = author["member_openid"] as? String ?? ""
        log("收到消息 kind=" + kind + " target=" + String(target.suffix(6)) + " authorKeys=" + author.keys.sorted().joined(separator: ",") + " id=" + String(authorID.suffix(8)) + " member=" + String(memberOpenID.suffix(8)))
        let message = ChatMessage(
            id: id, text: content, timestamp: timestamp, fromBot: false, authorName: authorName,
            imageURL: (!isVideo && !isAudio) ? remote : nil,
            videoURL: isVideo ? remote : nil,
            audioURL: isAudio ? remote : nil,
            quotedID: quotedID,
            authorID: memberID.isEmpty ? nil : memberID,
            authorAvatarURL: author["avatar"] as? String,
            buttons: buttonLabels.isEmpty ? nil : buttonLabels
        )
        append(message, target: target, scene: isChannel ? "channel" : (isGroup ? "group" : "c2c"), name: conversationName, markUnread: activeConversationID != target, replyID: id)
        if let remote {
            downloadMedia(remote, target: target, messageID: id, kind: isVideo ? "video" : (isAudio ? "audio" : "image"))
        }
    }

    private func handleInteraction(_ payload: [String: Any]) {
        let data = payload["data"] as? [String: Any] ?? [:]
        let resolved = data["resolved"] as? [String: Any] ?? [:]
        let label = resolved["button_data"] as? String ?? resolved["button_id"] as? String ?? "按钮"
        let groupTarget = payload["group_openid"] as? String
        let userTarget = payload["user_openid"] as? String
        let channelTarget = payload["channel_id"] as? String
        let isChannel = channelTarget != nil
        let isGroup = groupTarget != nil
        let target = channelTarget ?? groupTarget ?? userTarget ?? ""
        guard !target.isEmpty else { return }
        let eventID = payload["id"] as? String ?? UUID().uuidString
        let message = ChatMessage(
            id: "interaction-" + eventID,
            text: "点击了按钮：" + label,
            timestamp: ISO8601DateFormatter().string(from: .now),
            fromBot: false,
            authorName: "按钮交互"
        )
        let scene = isChannel ? "channel" : (isGroup ? "group" : "c2c")
        let name = isChannel ? "频道 " + String(target.suffix(6)) : (isGroup ? "群聊 " + String(target.suffix(6)) : "QQ 用户")
        append(message, target: target, scene: scene, name: name, markUnread: activeConversationID != target, replyID: nil)
    }

    private func append(_ message: ChatMessage, target: String, scene: String, name: String, markUnread: Bool, replyID: String?) {
        if let index = conversations.firstIndex(where: { $0.id == target }) {
            if conversations[index].messages.contains(where: { $0.id == message.id }) { return }
            conversations[index].messages.append(message)
            conversations[index].lastText = message.summary
            conversations[index].lastTimestamp = message.timestamp
            let currentName = conversations[index].name
            if currentName.hasPrefix("群聊 ") || currentName.hasPrefix("频道 ") || currentName == "QQ 用户" {
                conversations[index].name = name
            }
            if let replyID { conversations[index].replyID = replyID }
            if markUnread { conversations[index].unread += 1 }
            let updated = conversations.remove(at: index)
            conversations.insert(updated, at: 0)
        } else {
            let conversation = Conversation(id: target, scene: scene, name: name, lastText: message.summary, lastTimestamp: message.timestamp, unread: markUnread ? 1 : 0, messages: [message], replyID: replyID ?? "", replySeq: 0, pinned: nil, archived: nil, muted: nil)
            conversations.append(conversation)
            if scene == "group" {
                Task { await fetchGroupInfoIfNeeded(target) }
            } else if scene == "channel" {
                Task { await fetchChannelNameIfNeeded(target) }
            }
        }
        sortConversations()
        saveConversations()
        if let avatarURL = message.authorAvatarURL,
           let idx = conversations.firstIndex(where: { $0.id == target }),
           conversations[idx].avatarPath == nil {
            cacheAuthorAvatar(avatarURL, conversationID: target)
        }
    }

    private func sortConversations() {
        conversations.sort {
            let left = $0.pinned ?? false
            let right = $1.pinned ?? false
            if left != right { return left }
            return $0.lastDate > $1.lastDate
        }
    }

    func toggleArchive(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].archived = !(conversations[index].archived ?? false)
        saveConversations()
    }

    func toggleMute(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].muted = !(conversations[index].muted ?? false)
        saveConversations()
    }

    func togglePin(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].pinned = !(conversations[index].pinned ?? false)
        sortConversations()
        saveConversations()
    }

    func clearConversation(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].messages.removeAll()
        conversations[index].lastText = ""
        conversations[index].unread = 0
        saveConversations()
        log("已清空会话 " + String(id.suffix(6)))
    }

    func deleteConversation(_ id: String) {
        conversations.removeAll { $0.id == id }
        saveConversations()
    }

    func markRead(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }), conversations[index].unread != 0 else { return }
        conversations[index].unread = 0
        saveConversations()
    }

    // MARK: - Images

    func retryMedia(messageID: String, conversationID: String) {
        guard let conversation = conversation(conversationID),
              let message = conversation.messages.first(where: { $0.id == messageID }) else { return }
        let remote = message.imageURL ?? message.videoURL ?? message.audioURL
        guard let remote else {
            error = "该媒体没有可用的下载地址。"
            return
        }
        let kind = message.isVideo ? "video" : (message.isAudio ? "audio" : "image")
        log("重试下载媒体 " + String(messageID.suffix(6)))
        downloadMedia(remote, target: conversationID, messageID: messageID, kind: kind)
    }

    private func downloadMedia(_ urlString: String, target: String, messageID: String, kind: String) {
        Task {
            guard let url = URL(string: urlString) else { return }
            var request = URLRequest(url: url)
            if !self.token.isEmpty { request.setValue("QQBot " + self.token, forHTTPHeaderField: "Authorization") }
            guard let (data, _) = try? await URLSession.shared.data(for: request), !data.isEmpty else { return }
            let ext = kind == "video" ? "mp4" : (kind == "audio" ? "silk" : "jpg")
            guard let name = self.saveMedia(data, ext: ext) else { return }
            self.attachLocalMedia(name, kind: kind, target: target, messageID: messageID)
        }
    }

    private func attachLocalMedia(_ name: String, kind: String, target: String, messageID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == target }),
              let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == messageID }) else { return }
        switch kind {
        case "video":
            conversations[index].messages[messageIndex].videoFile = name
            conversations[index].messages[messageIndex].videoURL = nil
        case "audio":
            conversations[index].messages[messageIndex].audioFile = name
            conversations[index].messages[messageIndex].audioURL = nil
        default:
            conversations[index].messages[messageIndex].localImage = name
            conversations[index].messages[messageIndex].imageURL = nil
        }
        saveConversations()
    }

    func displayName(_ conversation: Conversation) -> String {
        let remark = conversation.remark?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return remark.isEmpty ? conversation.name : remark
    }

    func setRemark(_ id: String, _ text: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].remark = text
        saveConversations()
        log("设置备注 " + String(id.suffix(6)))
    }

    func setConversationAvatar(_ id: String, data: Data) {
        guard let image = UIImage(data: data),
              let jpeg = image.scaled(maxDimension: 400).jpegData(compressionQuality: 0.85),
              let name = saveMedia(jpeg, ext: "jpg") else { return }
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].avatarPath = name
        saveConversations()
        log("设置会话头像 " + String(id.suffix(6)))
    }

    func clearConversationAvatar(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].avatarPath = nil
        saveConversations()
    }

    func fetchGroupInfoIfNeeded(_ id: String) async {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              conversations[index].scene == "group",
              conversations[index].remark?.isEmpty ?? true else { return }
        guard conversations[index].name.hasPrefix("群聊 ") else { return }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        do {
            let result = try await apiAny("/v2/groups/" + encoded + "/info")
            guard let dict = result as? [String: Any],
                  let name = dict["group_name"] as? String, !name.isEmpty,
                  let current = conversations.firstIndex(where: { $0.id == id }) else { return }
            conversations[current].name = name
            if let avatar = dict["group_avatar"] as? String ?? dict["avatar"] as? String {
                conversations[current].autoAvatarURL = avatar
            }
            saveConversations()
            log("群名已获取 " + name)
        } catch {
            log("群信息获取失败，继续使用默认群名")
        }
    }

    func cacheAuthorAvatar(_ urlString: String, conversationID: String) {
        guard let conv = conversation(conversationID), conv.scene == "c2c" else { return }
        guard let url = URL(string: urlString) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url)),
                  let image = UIImage(data: data),
                  let jpeg = image.scaled(maxDimension: 200).jpegData(compressionQuality: 0.85),
                  let name = saveMedia(jpeg, ext: "jpg"),
                  let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
            conversations[index].autoAvatarURL = urlString
            conversations[index].avatarPath = name
            saveConversations()
        }
    }

    func setBackgroundImage(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        let resized = image.scaled(maxDimension: 1600)
        guard let jpeg = resized.jpegData(compressionQuality: 0.8), let name = saveMedia(jpeg, ext: "jpg") else { return }
        chatBackgroundImage = name
        UserDefaults.standard.set(name, forKey: "chatBackgroundImage")
        log("聊天背景图已更新")
    }

    func clearBackgroundImage() {
        chatBackgroundImage = nil
        UserDefaults.standard.removeObject(forKey: "chatBackgroundImage")
    }

    func saveMedia(_ data: Data, ext: String) -> String? {
        let name = UUID().uuidString + "." + ext
        do {
            try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
            try data.write(to: imagesURL.appendingPathComponent(name), options: .atomic)
            return name
        } catch { return nil }
    }

    func saveImage(_ data: Data) -> String? { saveMedia(data, ext: "jpg") }

    func mediaURL(named name: String?) -> URL? {
        guard let name else { return nil }
        return imagesURL.appendingPathComponent(name)
    }

    func image(named name: String?) -> UIImage? {
        guard let name else { return nil }
        if let cached = imageCache.object(forKey: name as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: imagesURL.appendingPathComponent(name).path) else { return nil }
        imageCache.setObject(image, forKey: name as NSString)
        return image
    }

    // MARK: - Sending

    func sendText(_ text: String, to id: String, quote: ChatMessage? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await send(to: id, text: trimmed, mediaFile: nil, mediaType: nil, quote: quote)
    }

    func addSticker(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= 10 * 1024 * 1024, let image = UIImage(data: data) else {
            return "无法添加：请选择 10MB 以内的图片或 GIF。"
        }
        let isGIF = data.starts(with: Data("GIF8".utf8))
        guard let payload = isGIF ? data : image.scaled(maxDimension: 1024).pngData() else { return "图片处理失败。" }
        let name = UUID().uuidString + (isGIF ? ".gif" : ".png")
        do {
            try FileManager.default.createDirectory(at: stickersURL, withIntermediateDirectories: true)
            try payload.write(to: stickersURL.appendingPathComponent(name), options: .atomic)
            let updated = stickers + [name]
            try JSONEncoder().encode(updated).write(to: stickerIndexURL, options: .atomic)
            stickers = updated
            return nil
        } catch { return "表情包保存失败，请重试。" }
    }

    func stickerImage(_ name: String) -> UIImage? {
        guard stickers.contains(name) else { return nil }
        return UIImage(contentsOfFile: stickersURL.appendingPathComponent(name).path)
    }

    func removeSticker(_ name: String) -> String? {
        let updated = stickers.filter { $0 != name }
        do {
            try JSONEncoder().encode(updated).write(to: stickerIndexURL, options: .atomic)
            stickers = updated
            try? FileManager.default.removeItem(at: stickersURL.appendingPathComponent(name))
            return nil
        } catch { return "删除表情包失败，请重试。" }
    }

    func sendSticker(_ name: String, to id: String, quote: ChatMessage?) async {
        guard stickers.contains(name),
              let data = try? Data(contentsOf: stickersURL.appendingPathComponent(name)), !data.isEmpty,
              let copy = saveMedia(data, ext: (name as NSString).pathExtension) else {
            error = "表情包已不可用，请重新添加。"
            return
        }
        // Copy into message storage: removing a favorite must not break sent messages.
        await send(to: id, text: "", mediaFile: copy, mediaType: "image", quote: quote)
    }

    func sendImage(_ data: Data, to id: String, quote: ChatMessage? = nil) async {
        guard let image = UIImage(data: data) else { error = "无法读取所选图片。"; return }
        let resized = image.scaled(maxDimension: 1600)
        guard let jpeg = resized.jpegData(compressionQuality: 0.82), let name = saveMedia(jpeg, ext: "jpg") else { error = "图片处理失败。"; return }
        await send(to: id, text: "", mediaFile: name, mediaType: "image", quote: quote)
    }

    func sendVideo(_ data: Data, to id: String, quote: ChatMessage? = nil) async {
        guard data.count <= 20 * 1024 * 1024 else { error = "视频不能超过 20MB，请先裁剪。"; return }
        guard let name = saveMedia(data, ext: "mp4") else { error = "视频保存失败。"; return }
        await send(to: id, text: "", mediaFile: name, mediaType: "video", quote: quote)
    }

    func sendAudio(_ data: Data, to id: String, quote: ChatMessage? = nil, duration: Double? = nil) async {
        guard data.count <= 10 * 1024 * 1024 else { error = "语音文件过大。"; return }
        guard let name = saveMedia(data, ext: "m4a") else { error = "语音保存失败。"; return }
        await send(to: id, text: "", mediaFile: name, mediaType: "audio", quote: quote, duration: duration)
    }

    func sendFile(_ data: Data, name: String, to id: String) async {
        guard data.count <= 20 * 1024 * 1024 else { error = "文件不能超过 20MB。"; return }
        let ext = (name as NSString).pathExtension
        guard let saved = saveMedia(data, ext: ext.isEmpty ? "bin" : ext) else { error = "文件保存失败。"; return }
        await send(to: id, text: "", mediaFile: saved, mediaType: "file", quote: nil, displayName: name)
    }

    private func send(to id: String, text: String, mediaFile: String?, mediaType: String?, quote: ChatMessage?, displayName: String? = nil, duration: Double? = nil) async {
        let previous = sendChain
        let task = Task { [weak self] in
            _ = await previous?.value
            await self?.performSend(to: id, text: text, mediaFile: mediaFile, mediaType: mediaType, quote: quote, displayName: displayName, duration: duration)
        }
        sendChain = task
        await task.value
    }

    private func performSend(to id: String, text: String, mediaFile: String?, mediaType: String?, quote: ChatMessage?, displayName: String? = nil, duration: Double? = nil) async {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        // Channel sends do not require the passive-reply context used by C2C/group messages.
        guard conversations[index].isChannel || !conversations[index].replyID.isEmpty else { error = "请先从 QQ 给机器人发送一条消息，再回复。"; return }
        sendingConversationID = id
        defer { sendingConversationID = nil }
        let conversation = conversations[index]
        let tempID = UUID().uuidString
        let pending = ChatMessage(
            id: tempID, text: text, timestamp: ISO8601DateFormatter().string(from: .now),
            fromBot: true, authorName: "QQ 机器人",
            localImage: mediaType == "image" ? mediaFile : nil,
            videoFile: mediaType == "video" ? mediaFile : nil,
            audioFile: mediaType == "audio" ? mediaFile : nil,
            fileLocal: mediaType == "file" ? mediaFile : nil,
            fileName: mediaType == "file" ? displayName : nil,
            quotedText: quote?.summary, quotedID: quote?.id, duration: duration, status: "sending"
        )
        conversations[index].messages.append(pending)
        conversations[index].lastText = pending.summary
        conversations[index].lastTimestamp = pending.timestamp
        saveConversations()
        var body: [String: Any] = [:]
        if conversation.scene != "channel" {
            body["msg_id"] = conversation.replyID
            body["msg_seq"] = conversation.replySeq + 1
        }
        if let quote { body["message_reference"] = ["message_id": quote.id] }
        if let mediaFile, let mediaType {
            guard let fileURL = mediaURL(named: mediaFile), let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
                if let current = conversations.firstIndex(where: { $0.id == id }),
                   let mi = conversations[current].messages.firstIndex(where: { $0.id == tempID }) {
                    conversations[current].messages[mi].status = "failed"
                    saveConversations()
                }
                error = "媒体文件读取失败，请重新选择文件后发送。"
                return
            }
            let type: Int
            let ext: String
            switch mediaType {
            case "video": type = 2; ext = "mp4"
            case "audio": type = 3; ext = "m4a"
            case "file": type = 4; ext = (displayName as NSString?)?.pathExtension ?? "bin"
            default: type = 1; ext = (mediaFile as NSString).pathExtension.isEmpty ? "jpg" : (mediaFile as NSString).pathExtension
            }
            let uploadName = mediaType == "file" ? (displayName ?? "file.bin") : "media." + ext
            do {
                let info = try await uploadMedia(data, fileType: type, fileName: uploadName, target: id, scene: conversation.scene)
                body["msg_type"] = 7
                body["content"] = ""
                body["media"] = ["file_info": info]
            } catch {
                switch mediaType {
                case "video": self.error = "视频上传失败，请确认小于 20MB 且机器人有富媒体权限。"
                case "audio": self.error = "语音上传失败，QQ 语音消息可能只接受 silk 编码。"
                case "file": self.error = "文件上传失败，请确认小于 20MB 且机器人有文件权限。"
                default: self.error = "图片上传失败，请确认小于 10MB 且机器人有富媒体权限。"
                }
                if let current = conversations.firstIndex(where: { $0.id == id }),
                   let mi = conversations[current].messages.firstIndex(where: { $0.id == tempID }) {
                    conversations[current].messages[mi].status = "failed"
                    saveConversations()
                }
                return
            }
        } else {
            body["msg_type"] = 0
            body["content"] = text
        }
        do {
            let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
            let path: String
            switch conversation.scene {
            case "channel": path = "/channels/"
            case "c2c": path = "/v2/users/"
            default: path = "/v2/groups/"
            }
            let result = try await api(path + encoded + "/messages", body: body)
            guard let messageID = result["id"] as? String else { throw URLError(.badServerResponse) }
            log("发送成功 type=" + (mediaType ?? "text") + " id=" + String(messageID.suffix(8)) + " content=" + String(text.prefix(40)))
            error = nil
            if let current = conversations.firstIndex(where: { $0.id == id }),
               let mi = conversations[current].messages.firstIndex(where: { $0.id == tempID }) {
                let old = conversations[current].messages[mi]
                conversations[current].messages[mi] = ChatMessage(
                    id: messageID, text: old.text, timestamp: old.timestamp, fromBot: true,
                    authorName: old.authorName, localImage: old.localImage, videoFile: old.videoFile,
                    audioFile: old.audioFile, fileLocal: old.fileLocal, fileName: old.fileName,
                    quotedText: old.quotedText, quotedID: old.quotedID, duration: old.duration,
                    buttons: old.buttons, status: "sent"
                )
                conversations[current].replySeq += 1
                saveConversations()
            }
        } catch {
            log("发送失败 " + String(describing: error))
            if let current = conversations.firstIndex(where: { $0.id == id }),
               let mi = conversations[current].messages.firstIndex(where: { $0.id == tempID }) {
                conversations[current].messages[mi].status = "failed"
                saveConversations()
            }
            self.error = "发送失败，请检查回复时限、机器人权限和连接。"
        }
    }

    private func uploadMedia(_ data: Data, fileType: Int, fileName: String, target: String, scene: String) async throws -> String {
        let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target
        let path: String
        switch scene {
        case "channel": path = "/channels/"
        case "c2c": path = "/v2/users/"
        default: path = "/v2/groups/"
        }
        let result = try await api(path + encoded + "/files", body: [
            "file_type": fileType,
            "file_data": data.base64EncodedString(),
            "file_name": fileName,
            "srv_send_msg": false
        ])
        guard let info = result["file_info"] as? String, !info.isEmpty else { throw URLError(.badServerResponse) }
        return info
    }

    // MARK: - Persistence

    private func loadConversations() {
        guard let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode([Conversation].self, from: data) else { return }
        conversations = saved
        sortConversations()
    }

    private func saveConversations() {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    private func retryFirstFailedMessage() {
        for conversation in conversations {
            if let message = conversation.messages.first(where: { $0.status == "failed" && !$0.text.contains("<@") }) {
                log("自动重试失败消息 " + String(message.id.suffix(6)))
                Task { await retryMessage(conversationID: conversation.id, messageID: message.id) }
                return
            }
        }
    }

    func retryMessage(conversationID: String, messageID: String) async {
        guard let conversation = conversation(conversationID),
              let message = conversation.messages.first(where: { $0.id == messageID }),
              message.status == "failed" else { return }
        let mediaType: String?
        let mediaFile: String?
        if let file = message.localImage { mediaType = "image"; mediaFile = file }
        else if let file = message.videoFile { mediaType = "video"; mediaFile = file }
        else if let file = message.audioFile { mediaType = "audio"; mediaFile = file }
        else if let file = message.fileLocal { mediaType = "file"; mediaFile = file }
        else { mediaType = nil; mediaFile = nil }
        // Keep the failed message if retry prerequisites are no longer available.
        guard conversation.isChannel || !conversation.replyID.isEmpty else {
            error = "请先从 QQ 给机器人发送一条消息，再重发。"
            return
        }
        if let mediaFile {
            guard let url = mediaURL(named: mediaFile),
                  let data = try? Data(contentsOf: url), !data.isEmpty else {
                error = "原媒体文件已不可用，请重新选择文件。原消息已保留。"
                return
            }
        }
        deleteMessage(conversationID: conversationID, messageID: messageID)
        await send(to: conversationID, text: message.text, mediaFile: mediaFile, mediaType: mediaType, quote: nil, displayName: message.fileName, duration: message.duration)
    }

    func deleteMessage(conversationID: String, messageID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].messages.removeAll { $0.id == messageID }
        if let last = conversations[index].messages.last {
            conversations[index].lastText = last.summary
            conversations[index].lastTimestamp = last.timestamp
        } else {
            // Keep the conversation position, but do not expose deleted message content.
            conversations[index].lastText = ""
            conversations[index].unread = 0
        }
        saveConversations()
    }

    func clearHistory() {
        conversations = []
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: imagesURL)
        try? FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    }

    func conversation(_ id: String) -> Conversation? { conversations.first(where: { $0.id == id }) }
}

extension UIImage {
    func scaled(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let ratio = maxDimension / longest
        let target = CGSize(width: size.width * ratio, height: size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}

struct RootView: View {
    @State private var store = ChatStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if store.isLoggedIn {
                TabView {
                    ConversationListView(store: store)
                        .tabItem { Label("聊天", systemImage: "bubble.left.and.bubble.right.fill") }
                    SettingsView(store: store, isTab: true)
                        .tabItem { Label("设置", systemImage: "gearshape.fill") }
                }
                .tabBarMinimizeBehavior(.onScrollDown)
            } else {
                LoginView(store: store)
            }
        }
        .preferredColorScheme(store.appearance == "light" ? .light : (store.appearance == "dark" ? .dark : nil))
        .animation(.easeInOut(duration: 0.25), value: store.isLoggedIn)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.reconnectIfNeeded() }
        }
        .task { store.start() }
    }
}

struct LoginView: View {
    let store: ChatStore
    @State private var username = ""
    @State private var password = ""
    private let blue = TGColor.accent

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 34)).foregroundStyle(.white)
                .frame(width: 74, height: 74)
                .background(blue.gradient, in: RoundedRectangle(cornerRadius: 20))
            Text("QQ 机器人").font(.system(size: 24, weight: .bold))
            Text("直接连接 QQ 官方机器人接口").font(.system(size: 13)).foregroundStyle(.secondary)
            VStack(spacing: 10) {
                TextField("机器人 AppID", text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                SecureField("机器人 AppSecret", text: $password)
                    .padding(12).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.top, 8)
            if let error = store.error {
                Text(error).font(.system(size: 13)).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Button {
                store.username = username
                store.password = password
                Task { await store.login() }
            } label: {
                if store.loggingIn { ProgressView().tint(.white) } else { Text("登录").fontWeight(.semibold) }
            }
            .frame(maxWidth: .infinity).frame(height: 48)
            .foregroundStyle(.white).background(blue, in: RoundedRectangle(cornerRadius: 12))
            .disabled(store.loggingIn)
            Text("凭证只保存在本机 Keychain，不会上传到其他服务器。")
                .font(.system(size: 11)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            Spacer()
        }
        .padding(28)
        .onAppear {
            username = store.username
            password = store.password
        }
    }
}

struct ConversationListView: View {
    let store: ChatStore
    @State private var showSettings = false
    @State private var showComposeHint = false
    @State private var editMode = false
    @State private var query = ""
    private let blue = TGColor.accent

    private var filtered: [Conversation] {
        let base = store.conversations.filter { store.showArchived || !($0.archived ?? false) }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return base }
        let needle = query.trimmingCharacters(in: .whitespaces)
        return base.filter {
            store.displayName($0).localizedCaseInsensitiveContains(needle) ||
            $0.name.localizedCaseInsensitiveContains(needle) ||
            $0.lastText.localizedCaseInsensitiveContains(needle) ||
            $0.messages.contains { $0.text.localizedCaseInsensitiveContains(needle) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.conversations.isEmpty {
                    ContentUnavailableView {
                        Label("还没有会话", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("从 QQ 给机器人发送一条消息后，会话会出现在这里。")
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List {
                        ForEach(filtered) { conversation in
                            NavigationLink(value: conversation.id) {
                                ConversationRow(conversation: conversation, store: store)
                            }
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 18))
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button { store.markRead(conversation.id) } label: { Label("已读", systemImage: "checkmark.circle") }
                                    .tint(Color(red: 0xbc / 255, green: 0xbc / 255, blue: 0xc3 / 255))
                                Button { store.togglePin(conversation.id) } label: { Label("置顶", systemImage: "pin") }
                                    .tint(Color(red: 0, green: 0xc9 / 255, blue: 0))
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button { store.toggleMute(conversation.id) } label: { Label("静音", systemImage: "bell.slash") }
                                    .tint(Color(red: 0xf0 / 255, green: 0x9a / 255, blue: 0x37 / 255))
                                Button(role: .destructive) { store.deleteConversation(conversation.id) } label: { Label("删除", systemImage: "trash") }
                                    .tint(Color(red: 0xff / 255, green: 0x38 / 255, blue: 0x24 / 255))
                                Button { store.toggleArchive(conversation.id) } label: { Label("归档", systemImage: "archivebox") }
                                    .tint(Color(red: 0xbc / 255, green: 0xbc / 255, blue: 0xc3 / 255))
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索")
            .navigationTitle("聊天")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("聊天").font(.system(size: 17, weight: .semibold)).monospacedDigit()
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(editMode ? "完成" : "编辑") { editMode.toggle() }
                        .frame(height: 44)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showComposeHint = true } label: { Image(systemName: "square.and.pencil") }
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityLabel("新建消息")
                }
            }
            .navigationDestination(for: String.self) { id in
                ChatView(store: store, conversationID: id)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(store: store)
            }
            .alert("新建会话", isPresented: $showComposeHint) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("QQ 机器人只能回复用户消息。请先在 QQ 里给机器人发一条消息，会话会自动出现在这里。")
            }
            .onAppear { store.activeConversationID = nil }
        }
        .tint(blue)
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    let store: ChatStore
    private let blue = TGColor.accent

    private var avatarColors: [Color] {
        let palettes: [[Color]] = [
            [.blue, .cyan], [.purple, .pink], [.orange, .yellow],
            [.green, .mint], [.indigo, .blue], [.pink, .orange]
        ]
        let sum = conversation.name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palettes[sum % palettes.count]
    }

    private var iconName: String {
        if conversation.isChannel { return "antenna.radiowaves.left.and.right" }
        return conversation.isGroup ? "person.2.fill" : "person.fill"
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = store.image(named: conversation.avatarPath) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Text(String(store.displayName(conversation).prefix(1)))
                        .font(.system(size: 26, weight: .regular)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(LinearGradient(colors: avatarColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(store.displayName(conversation))
                        .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(conversation.lastDate, format: .dateTime.hour().minute())
                        .font(.system(size: 14)).foregroundStyle(TGColor.secondaryText)
                }
                HStack(spacing: 6) {
                    Text(conversation.lastText.isEmpty ? " " : conversation.lastText)
                        .font(.system(size: 15)).foregroundStyle(TGColor.secondaryText).lineLimit(1)
                    Spacer()
                    if conversation.pinned == true && conversation.unread == 0 {
                        Image(systemName: "pin.fill").font(.system(size: 11))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color(red: 0xb6 / 255, green: 0xb6 / 255, blue: 0xbb / 255)))
                    }
                    if conversation.unread > 0 {
                        Text("\(conversation.unread)")
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Capsule().fill(conversation.muted == true
                                ? Color(red: 0xb6 / 255, green: 0xb6 / 255, blue: 0xbb / 255)
                                : TGColor.accent))
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .frame(height: 76)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TGColor.separator)
                .frame(height: 1.0 / UIScreen.main.scale)
                .padding(.leading, 86)
                .padding(.trailing, 16)
        }
    }
}

struct ChatView: View {
    let store: ChatStore
    let conversationID: String
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var videoItem: PhotosPickerItem?
    @State private var quoting: ChatMessage?
    @State private var recorder: AVAudioRecorder?
    @State private var recording = false
    @State private var recordingStarted: Date?
    @State private var showFileImporter = false
    @State private var showSchedules = false
    @State private var showChatSearch = false
    @State private var chatQuery = ""
    @State private var jumpTarget: String?
    @State private var previewImage: UIImage?
    @State private var showPreview = false
    @State private var editingMessage: ChatMessage?
    @State private var editText = ""
    @State private var reactionMessageID: String?
    @State private var showReactionUsers = false
    @State private var playingVideoURL: URL?
    @State private var menuMessage: ChatMessage?
    @State private var forwardMessage: ChatMessage?
    @State private var showForwardPicker = false
    @State private var showProfileEditor = false
    @State private var focusComposerTick = 0
    @State private var remarkDraft = ""
    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var scrollTick = 0
    @State private var renderLimit = 100
    @State private var showScrollButton = false
    @State private var showPins = false
    @State private var showKeyboardAlert = false
    @State private var keyboardText = ""
    private let blue = TGColor.accent

    private var conversation: Conversation? { store.conversation(conversationID) }
    private var visibleMessages: [ChatMessage] {
        guard let conversation else { return [] }
        return Array(conversation.messages.suffix(renderLimit))
    }


    private var searchResults: [ChatMessage] {
        let all = conversation?.messages ?? []
        guard !chatQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return Array(all.suffix(50)) }
        let needle = chatQuery.trimmingCharacters(in: .whitespaces)
        return all.filter { $0.text.localizedCaseInsensitiveContains(needle) }
    }

    private func handleQuote(_ target: ChatMessage) { quoting = target }
    private func handleSwipeReply(_ target: ChatMessage) {
        quoting = target
        focusComposerTick += 1
    }
    private func handlePreview(_ image: UIImage) { previewImage = image; showPreview = true }
    private func handleEdit(_ target: ChatMessage) { editingMessage = target; editText = target.text }
    private func handlePlayVideo(_ url: URL) { playingVideoURL = url }
    private func handleLongPress(_ target: ChatMessage) { menuMessage = target }
    private func handleForward(_ target: ChatMessage) { forwardMessage = target; showForwardPicker = true }
    private func handleReactionUsers(_ messageID: String) {
        reactionMessageID = messageID
        showReactionUsers = true
        Task { await store.loadReactionUsers(conversationID: conversationID, messageID: messageID) }
    }

    private func dateHeaderString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    @ViewBuilder
    private func messageCell(visible: [ChatMessage], index: Int, proxy: ScrollViewProxy, availableWidth: CGFloat) -> some View {
        let message = visible[index]
        let previous: ChatMessage? = index > 0 ? visible[index - 1] : nil
        let next: ChatMessage? = index < visible.count - 1 ? visible[index + 1] : nil
        let showDate = previous.map { !Calendar.current.isDate(message.date, inSameDayAs: $0.date) } ?? true
        let mergedTop = previous.map { isSameMessageGroup($0, message) } ?? false
        let mergedBottom = next.map { isSameMessageGroup(message, $0) } ?? false
        if showDate {
            Text(dateHeaderString(message.date))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(Color.black.opacity(0.2), in: Capsule())
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
        }
        MessageRow(
            store: store,
            conversationID: conversationID,
            message: message,
            onQuote: handleQuote,
            onJump: { target in withAnimation { proxy.scrollTo(target, anchor: .center) } },
            onPreview: handlePreview,
            onEdit: handleEdit,
            onReactionUsers: handleReactionUsers,
            onPlayVideo: handlePlayVideo,
            onLongPress: handleLongPress,
            onForward: handleForward,
            onSwipeReply: handleSwipeReply,
            availableWidth: availableWidth,
            mergedTop: mergedTop,
            mergedBottom: mergedBottom
        )
        .padding(.top, 3)
        .id(message.id)
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
    }

    @ViewBuilder
    private var chatBackground: some View {
        if let name = store.chatBackgroundImage, let image = store.image(named: name) {
            Image(uiImage: image).resizable().scaledToFill().clipped().opacity(0.35)
        } else {
            switch store.chatBackground {
        case "plain":
            Color(uiColor: .secondarySystemBackground)
        case "green":
            Color(red: 0.90, green: 0.95, blue: 0.90)
        case "blue":
                Color(red: 0.89, green: 0.94, blue: 0.98)
            default:
                LinearGradient(
                    colors: [Color(uiColor: .systemBackground), Color(uiColor: .secondarySystemBackground)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.error {
                HStack(spacing: 8) {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { store.error = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red.opacity(0.7))
                    }
                    .accessibilityLabel("关闭提示")
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.red.opacity(0.06))
                .task(id: error) {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    if store.error == error { store.error = nil }
                }
            }
            messageList
            composer
        }
        .background(
            chatBackground
                .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                .ignoresSafeArea(.all)
        )
        .navigationTitle(conversation.map { store.displayName($0) } ?? "聊天")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Group {
                        if let conv = conversation, let image = store.image(named: conv.avatarPath) {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            ZStack {
                                Circle().fill(blue.gradient)
                                Text(String((conversation.map { store.displayName($0) } ?? "聊").prefix(1)))
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            }
                        }
                    }
                    .frame(width: 34, height: 34)
                    .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 0) {
                        Text(conversation.map { store.displayName($0) } ?? "聊天")
                            .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(store.status).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { showChatSearch = true } label: { Label("搜索", systemImage: "magnifyingglass") }
                    Button { showProfileEditor = true } label: { Label("设置备注与头像", systemImage: "pencil.circle") }
                    if conversation?.scene == "group" {
                        Button { Task { await store.fetchGroupInfoIfNeeded(conversationID) } } label: { Label("重新获取群名称", systemImage: "arrow.clockwise") }
                    }
                    if conversation?.scene == "channel" {
                        Button { showSchedules = true } label: { Label("频道日程", systemImage: "calendar") }
                        Button { showPins = true; Task { await store.loadPins(conversationID: conversationID) } } label: { Label("置顶消息", systemImage: "pin") }
                        Button { keyboardText = ""; showKeyboardAlert = true } label: { Label("发送按钮消息", systemImage: "keyboard") }
                        Button { Task { await store.fetchHistory(conversationID: conversationID) } } label: { Label("拉取历史消息", systemImage: "clock.arrow.circlepath") }
                    }
                    Button(role: .destructive) { store.clearConversation(conversationID) } label: { Label("清空聊天", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("更多")
            }
        }
        .onAppear {
            store.activeConversationID = conversationID
            store.markRead(conversationID)
        }
        .onDisappear {
            store.activeConversationID = nil
            if recording { recorder?.stop(); recorder = nil; recording = false }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await store.sendImage(data, to: conversationID)
                    }
                }
                pickerItems = []
            }
        }
        .confirmationDialog("消息操作", isPresented: Binding(get: { menuMessage != nil }, set: { if !$0 { menuMessage = nil } }), titleVisibility: .visible, presenting: menuMessage) { message in
            if !message.text.isEmpty {
                Button("复制") { UIPasteboard.general.string = message.text }
            }
            Button("引用") { quoting = message }
            if !message.text.isEmpty {
                Button("转发") { forwardMessage = message; showForwardPicker = true }
            }
            if message.status == "failed" {
                Button("重发") { Task { await store.retryMessage(conversationID: conversationID, messageID: message.id) } }
            }
            if let name = message.localImage, let image = store.image(named: name) {
                Button("保存图片") {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                    store.error = "图片已保存到相册。"
                }
            }
            if let name = message.videoFile, let url = store.mediaURL(named: name) {
                Button("保存视频") {
                    UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil)
                    store.error = "视频已保存到相册。"
                }
            }
            if store.conversation(conversationID)?.scene == "channel" {
                if message.fromBot {
                    Button("编辑") { editingMessage = message; editText = message.text }
                }
                Button("点赞回应") { Task { await store.react(conversationID: conversationID, messageID: message.id) } }
                Button("取消点赞") { Task { await store.removeReaction(conversationID: conversationID, messageID: message.id) } }
                Button("置顶") { Task { await store.pinMessage(conversationID: conversationID, messageID: message.id) } }
                Button("取消置顶") { Task { await store.unpinMessage(conversationID: conversationID, messageID: message.id) } }
                Button("设为公告") { Task { await store.publishAnnounce(conversationID: conversationID, messageID: message.id) } }
                Button("取消公告") { Task { await store.deleteAnnounce(conversationID: conversationID, messageID: message.id) } }
                Button("点赞用户") {
                    reactionMessageID = message.id
                    showReactionUsers = true
                    Task { await store.loadReactionUsers(conversationID: conversationID, messageID: message.id) }
                }
                if message.fromBot && message.status == "sent" {
                    Button("撤回") { Task { await store.recallMessage(conversationID: conversationID, messageID: message.id) } }
                }
            }
            Button("删除", role: .destructive) { store.deleteMessage(conversationID: conversationID, messageID: message.id) }
            Button("取消", role: .cancel) { menuMessage = nil }
        }
        .sheet(isPresented: $showProfileEditor) {
            NavigationStack {
                Form {
                    Section("备注名称") {
                        TextField("留空则使用默认名称", text: $remarkDraft)
                        if let conv = conversation {
                            Text("默认名称：\(conv.name)")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Section("头像") {
                        PhotosPicker(selection: $avatarPickerItem, matching: .images, photoLibrary: .shared()) {
                            Text("选择头像图片")
                        }
                        if let conv = conversation, conv.avatarPath != nil {
                            Button("恢复默认头像", role: .destructive) {
                                store.clearConversationAvatar(conversationID)
                            }
                        }
                        Text("QQ 群消息事件不提供群头像，头像来自事件中的用户 avatar 字段或手动设置。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("会话资料")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("取消") { showProfileEditor = false }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("保存") {
                            store.setRemark(conversationID, remarkDraft)
                            showProfileEditor = false
                        }
                    }
                }
                .onAppear { remarkDraft = conversation?.remark ?? "" }
                .onChange(of: avatarPickerItem) { _, item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            store.setConversationAvatar(conversationID, data: data)
                        }
                        avatarPickerItem = nil
                    }
                }
            }
        }
        .sheet(isPresented: $showForwardPicker) {
            NavigationStack {
                List(store.conversations.filter { $0.id != conversationID }) { conversation in
                    Button(conversation.name) {
                        if let message = forwardMessage {
                            Task { await store.sendText(message.text, to: conversation.id) }
                        }
                        showForwardPicker = false
                        forwardMessage = nil
                    }
                }
                .navigationTitle("转发到")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("取消") { showForwardPicker = false; forwardMessage = nil } } }
            }
        }
        .sheet(isPresented: Binding(get: { playingVideoURL != nil }, set: { if !$0 { playingVideoURL = nil } })) {
            if let url = playingVideoURL {
                VideoPlayer(player: AVPlayer(url: url)).ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showReactionUsers) {
            NavigationStack {
                List(store.reactionUsers, id: \.self) { name in Text(name) }
                    .navigationTitle("点赞用户")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { showReactionUsers = false } } }
            }
        }
        .alert("编辑消息", isPresented: Binding(get: { editingMessage != nil }, set: { if !$0 { editingMessage = nil } })) {
            TextField("内容", text: $editText)
            Button("保存") {
                if let target = editingMessage {
                    Task { await store.editMessage(conversationID: conversationID, messageID: target.id, newText: editText) }
                }
                editingMessage = nil
            }
            Button("取消", role: .cancel) { editingMessage = nil }
        }
        .fullScreenCover(isPresented: $showPreview) {
            ImagePreview(image: previewImage) { showPreview = false }
        }
        .sheet(isPresented: $showChatSearch) {
            NavigationStack {
                List(searchResults, id: \.id) { message in
                    Button {
                        jumpTarget = message.id
                        showChatSearch = false
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(message.text.isEmpty ? message.summary : message.text).font(.system(size: 14)).lineLimit(2)
                            Text(message.authorName + " · " + message.timestamp).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .searchable(text: $chatQuery, prompt: "搜索本会话消息")
                .navigationTitle("搜索消息")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { showChatSearch = false } } }
            }
        }
        .alert("发送带按钮的消息", isPresented: $showKeyboardAlert) {
            TextField("消息内容", text: $keyboardText)
            Button("发送") { Task { await store.sendKeyboardMessage(keyboardText, to: conversationID) } }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showPins) {
            NavigationStack {
                List(store.pins, id: \.self) { id in Text(id).font(.system(size: 12)).lineLimit(1) }
                    .navigationTitle("置顶消息")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { showPins = false } } }
            }
        }
        .sheet(isPresented: $showSchedules) {
            NavigationStack {
                List(store.schedules, id: \.self) { item in Text(item) }
                    .navigationTitle("频道日程")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { showSchedules = false } } }
                    .task { await store.loadSchedules(channelID: conversationID) }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            Task { await store.sendFile(data, name: url.lastPathComponent, to: conversationID) }
        }
        .onChange(of: videoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await store.sendVideo(data, to: conversationID)
                }
                videoItem = nil
            }
        }
    }

    private func toggleRecording() {
        if recording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.record()
            recorder = r
            recording = true
            recordingStarted = Date()
        } catch {
            store.error = "无法开始录音，请检查麦克风权限。"
        }
    }

    private func stopRecording() {
        guard let r = recorder else { return }
        r.stop()
        recorder = nil
        recording = false
        let url = r.url
        let duration = recordingStarted.map { Date().timeIntervalSince($0) }
        recordingStarted = nil
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        Task { await store.sendAudio(data, to: conversationID, duration: duration) }
    }

    private var messageList: some View {
        GeometryReader { listGeo in
            let availableWidth = listGeo.size.width - 24
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Telegram: 0.2s easeInOut for message list changes
                        if let conversation {
                            if conversation.messages.count > renderLimit {
                                Button("加载更早消息") { renderLimit += 100 }
                                    .font(.system(size: 12)).padding(.top, 8)
                            }
                            if visibleMessages.isEmpty {
                                Text("从 QQ 给机器人发一条消息开始聊天")
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                                    .padding(.top, 40)
                            }
                            ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, _ in
                                messageCell(visible: visibleMessages, index: index, proxy: proxy, availableWidth: availableWidth)
                            }
                        }
                        Color.clear.frame(height: 1).id("chatBottom")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 12)
                    .animation(.easeInOut(duration: 0.2), value: visibleMessages.count)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(TapGesture().onEnded {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                })
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 120
                } action: { _, below in
                    showScrollButton = below
                }
                .overlay(alignment: .bottomTrailing) {
                    if showScrollButton {
                        Button {
                            showScrollButton = false
                            withAnimation(TGAnim.scrollToBottom) { proxy.scrollTo("chatBottom", anchor: .bottom) }
                        } label: {
                            Image(systemName: "arrow.down").font(.system(size: 15, weight: .semibold))
                                .frame(width: 38, height: 38)
                                .glassEffect(.regular, in: Circle())
                        }
                        .padding(.trailing, 14).padding(.bottom, 10)
                    }
                }
                .refreshable {
                    if conversation?.scene == "channel" {
                        await store.fetchHistory(conversationID: conversationID)
                    }
                }
                .onChange(of: jumpTarget) { _, target in
                    if let target { withAnimation(TGAnim.scrollToMessage) { proxy.scrollTo(target, anchor: .top) }; jumpTarget = nil }
                }
                .onChange(of: conversation?.messages.count) { oldCount, newCount in
                    // Preserve the reading position for incoming messages and history loads.
                    guard let oldCount, let newCount, newCount > oldCount else { return }
                    let ownPendingMessage = conversation?.messages.last.map { $0.fromBot && $0.status == "sending" } ?? false
                    guard !showScrollButton || ownPendingMessage else { return }
                    withAnimation(TGAnim.scrollToBottom) { proxy.scrollTo("chatBottom", anchor: .bottom) }
                }
                .onChange(of: scrollTick) { _, _ in
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("chatBottom", anchor: .bottom) }
                }
                .onAppear {
                    // Layout pass must finish before any programmatic scroll; otherwise
                    // the lazy stack can be scrolled out of view (blank screen).
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !visibleMessages.isEmpty else { return }
                        proxy.scrollTo("chatBottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            ComposerInput(
                store: store,
                conversationID: conversationID,
                quoting: quoting,
                pickerItems: $pickerItems,
                videoItem: $videoItem,
                showFileImporter: $showFileImporter,
                recording: $recording,
                onToggleRecording: { toggleRecording() },
                onSend: { text, quote in
                    quoting = nil
                    store.drafts[conversationID] = ""
                    UserDefaults.standard.set(store.drafts, forKey: "drafts")
                    Task { await store.sendText(text, to: conversationID, quote: quote) }
                },
                // Quoting an older message should not move the reader to the bottom.
                onFocus: { if !showScrollButton { scrollTick += 1 } },
                onCancelQuote: { quoting = nil },
                focusTick: focusComposerTick
            )
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .background(.clear)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }
}

struct QQFaceEntry: Identifiable {
    let id: Int
    let name: String
    let url: String
}

enum QQFaceCatalog {
    // Source: https://koishi.js.org/QFace/assets/qq_emoji/_index.v2.json
    // Snapshot: 2026-11-12T01:59:11.360Z; image copyright belongs to Tencent.
    static let entries: [QQFaceEntry] = [
        QQFaceEntry(id: 0, name: "惊讶", url: "https://koishi.js.org/QFace/assets/qq_emoji/0/png/0.png"),
        QQFaceEntry(id: 1, name: "撇嘴", url: "https://koishi.js.org/QFace/assets/qq_emoji/1/png/1.png"),
        QQFaceEntry(id: 2, name: "色", url: "https://koishi.js.org/QFace/assets/qq_emoji/2/png/2.png"),
        QQFaceEntry(id: 3, name: "发呆", url: "https://koishi.js.org/QFace/assets/qq_emoji/3/png/3.png"),
        QQFaceEntry(id: 4, name: "得意", url: "https://koishi.js.org/QFace/assets/qq_emoji/4/png/4.png"),
        QQFaceEntry(id: 5, name: "流泪", url: "https://koishi.js.org/QFace/assets/qq_emoji/5/png/5_0.png"),
        QQFaceEntry(id: 6, name: "害羞", url: "https://koishi.js.org/QFace/assets/qq_emoji/6/png/6.png"),
        QQFaceEntry(id: 7, name: "闭嘴", url: "https://koishi.js.org/QFace/assets/qq_emoji/7/png/7.png"),
        QQFaceEntry(id: 8, name: "睡", url: "https://koishi.js.org/QFace/assets/qq_emoji/8/png/8.png"),
        QQFaceEntry(id: 9, name: "大哭", url: "https://koishi.js.org/QFace/assets/qq_emoji/9/png/9.png"),
        QQFaceEntry(id: 10, name: "尴尬", url: "https://koishi.js.org/QFace/assets/qq_emoji/10/png/10.png"),
        QQFaceEntry(id: 11, name: "发怒", url: "https://koishi.js.org/QFace/assets/qq_emoji/11/png/11.png"),
        QQFaceEntry(id: 12, name: "调皮", url: "https://koishi.js.org/QFace/assets/qq_emoji/12/png/12.png"),
        QQFaceEntry(id: 13, name: "呲牙", url: "https://koishi.js.org/QFace/assets/qq_emoji/13/png/13.png"),
        QQFaceEntry(id: 14, name: "微笑", url: "https://koishi.js.org/QFace/assets/qq_emoji/14/png/14.png"),
        QQFaceEntry(id: 15, name: "难过", url: "https://koishi.js.org/QFace/assets/qq_emoji/15/png/15.png"),
        QQFaceEntry(id: 16, name: "酷", url: "https://koishi.js.org/QFace/assets/qq_emoji/16/png/16.png"),
        QQFaceEntry(id: 18, name: "抓狂", url: "https://koishi.js.org/QFace/assets/qq_emoji/18/png/18.png"),
        QQFaceEntry(id: 19, name: "吐", url: "https://koishi.js.org/QFace/assets/qq_emoji/19/png/19.png"),
        QQFaceEntry(id: 20, name: "偷笑", url: "https://koishi.js.org/QFace/assets/qq_emoji/20/png/20.png"),
        QQFaceEntry(id: 21, name: "可爱", url: "https://koishi.js.org/QFace/assets/qq_emoji/21/png/21.png"),
        QQFaceEntry(id: 22, name: "白眼", url: "https://koishi.js.org/QFace/assets/qq_emoji/22/png/22.png"),
        QQFaceEntry(id: 23, name: "傲慢", url: "https://koishi.js.org/QFace/assets/qq_emoji/23/png/23.png"),
        QQFaceEntry(id: 24, name: "饥饿", url: "https://koishi.js.org/QFace/assets/qq_emoji/24/png/24.png"),
        QQFaceEntry(id: 25, name: "困", url: "https://koishi.js.org/QFace/assets/qq_emoji/25/png/25.png"),
        QQFaceEntry(id: 26, name: "惊恐", url: "https://koishi.js.org/QFace/assets/qq_emoji/26/png/26.png"),
        QQFaceEntry(id: 27, name: "流汗", url: "https://koishi.js.org/QFace/assets/qq_emoji/27/png/27.png"),
        QQFaceEntry(id: 28, name: "憨笑", url: "https://koishi.js.org/QFace/assets/qq_emoji/28/png/28.png"),
        QQFaceEntry(id: 29, name: "悠闲", url: "https://koishi.js.org/QFace/assets/qq_emoji/29/png/29.png"),
        QQFaceEntry(id: 30, name: "奋斗", url: "https://koishi.js.org/QFace/assets/qq_emoji/30/png/30.png"),
        QQFaceEntry(id: 31, name: "咒骂", url: "https://koishi.js.org/QFace/assets/qq_emoji/31/png/31.png"),
        QQFaceEntry(id: 32, name: "疑问", url: "https://koishi.js.org/QFace/assets/qq_emoji/32/png/32.png"),
        QQFaceEntry(id: 33, name: "嘘", url: "https://koishi.js.org/QFace/assets/qq_emoji/33/png/33.png"),
        QQFaceEntry(id: 34, name: "晕", url: "https://koishi.js.org/QFace/assets/qq_emoji/34/png/34.png"),
        QQFaceEntry(id: 35, name: "折磨", url: "https://koishi.js.org/QFace/assets/qq_emoji/35/png/35.png"),
        QQFaceEntry(id: 36, name: "衰", url: "https://koishi.js.org/QFace/assets/qq_emoji/36/png/36.png"),
        QQFaceEntry(id: 37, name: "骷髅", url: "https://koishi.js.org/QFace/assets/qq_emoji/37/png/37.png"),
        QQFaceEntry(id: 38, name: "敲打", url: "https://koishi.js.org/QFace/assets/qq_emoji/38/png/38.png"),
        QQFaceEntry(id: 39, name: "再见", url: "https://koishi.js.org/QFace/assets/qq_emoji/39/png/39.png"),
        QQFaceEntry(id: 41, name: "发抖", url: "https://koishi.js.org/QFace/assets/qq_emoji/41/png/41.png"),
        QQFaceEntry(id: 42, name: "爱情", url: "https://koishi.js.org/QFace/assets/qq_emoji/42/png/42.png"),
        QQFaceEntry(id: 43, name: "跳跳", url: "https://koishi.js.org/QFace/assets/qq_emoji/43/png/43.png"),
        QQFaceEntry(id: 46, name: "猪头", url: "https://koishi.js.org/QFace/assets/qq_emoji/46/png/46.png"),
        QQFaceEntry(id: 49, name: "拥抱", url: "https://koishi.js.org/QFace/assets/qq_emoji/49/png/49.png"),
        QQFaceEntry(id: 53, name: "蛋糕", url: "https://koishi.js.org/QFace/assets/qq_emoji/53/png/53_0.png"),
        QQFaceEntry(id: 55, name: "炸弹", url: "https://koishi.js.org/QFace/assets/qq_emoji/55/png/55.png"),
        QQFaceEntry(id: 56, name: "刀", url: "https://koishi.js.org/QFace/assets/qq_emoji/56/png/56.png"),
        QQFaceEntry(id: 59, name: "便便", url: "https://koishi.js.org/QFace/assets/qq_emoji/59/png/59.png"),
        QQFaceEntry(id: 60, name: "咖啡", url: "https://koishi.js.org/QFace/assets/qq_emoji/60/png/60.png"),
        QQFaceEntry(id: 63, name: "玫瑰", url: "https://koishi.js.org/QFace/assets/qq_emoji/63/png/63.png"),
        QQFaceEntry(id: 64, name: "凋谢", url: "https://koishi.js.org/QFace/assets/qq_emoji/64/png/64.png"),
        QQFaceEntry(id: 66, name: "爱心", url: "https://koishi.js.org/QFace/assets/qq_emoji/66/png/66.png"),
        QQFaceEntry(id: 67, name: "心碎", url: "https://koishi.js.org/QFace/assets/qq_emoji/67/png/67.png"),
        QQFaceEntry(id: 74, name: "太阳", url: "https://koishi.js.org/QFace/assets/qq_emoji/74/png/74_0.png"),
        QQFaceEntry(id: 75, name: "月亮", url: "https://koishi.js.org/QFace/assets/qq_emoji/75/png/75_0.png"),
        QQFaceEntry(id: 76, name: "赞", url: "https://koishi.js.org/QFace/assets/qq_emoji/76/png/76.png"),
        QQFaceEntry(id: 77, name: "踩", url: "https://koishi.js.org/QFace/assets/qq_emoji/77/png/77.png"),
        QQFaceEntry(id: 78, name: "握手", url: "https://koishi.js.org/QFace/assets/qq_emoji/78/png/78.png"),
        QQFaceEntry(id: 79, name: "胜利", url: "https://koishi.js.org/QFace/assets/qq_emoji/79/png/79.png"),
        QQFaceEntry(id: 85, name: "飞吻", url: "https://koishi.js.org/QFace/assets/qq_emoji/85/png/85.png"),
        QQFaceEntry(id: 86, name: "怄火", url: "https://koishi.js.org/QFace/assets/qq_emoji/86/png/86.png"),
        QQFaceEntry(id: 89, name: "西瓜", url: "https://koishi.js.org/QFace/assets/qq_emoji/89/png/89.png"),
        QQFaceEntry(id: 96, name: "冷汗", url: "https://koishi.js.org/QFace/assets/qq_emoji/96/png/96.png"),
        QQFaceEntry(id: 97, name: "擦汗", url: "https://koishi.js.org/QFace/assets/qq_emoji/97/png/97.png"),
        QQFaceEntry(id: 98, name: "抠鼻", url: "https://koishi.js.org/QFace/assets/qq_emoji/98/png/98.png"),
        QQFaceEntry(id: 99, name: "鼓掌", url: "https://koishi.js.org/QFace/assets/qq_emoji/99/png/99.png"),
        QQFaceEntry(id: 100, name: "糗大了", url: "https://koishi.js.org/QFace/assets/qq_emoji/100/png/100.png"),
        QQFaceEntry(id: 101, name: "坏笑", url: "https://koishi.js.org/QFace/assets/qq_emoji/101/png/101.png"),
        QQFaceEntry(id: 102, name: "左哼哼", url: "https://koishi.js.org/QFace/assets/qq_emoji/102/png/102.png"),
        QQFaceEntry(id: 103, name: "右哼哼", url: "https://koishi.js.org/QFace/assets/qq_emoji/103/png/103.png"),
        QQFaceEntry(id: 104, name: "哈欠", url: "https://koishi.js.org/QFace/assets/qq_emoji/104/png/104.png"),
        QQFaceEntry(id: 105, name: "鄙视", url: "https://koishi.js.org/QFace/assets/qq_emoji/105/png/105.png"),
        QQFaceEntry(id: 106, name: "委屈", url: "https://koishi.js.org/QFace/assets/qq_emoji/106/png/106.png"),
        QQFaceEntry(id: 107, name: "快哭了", url: "https://koishi.js.org/QFace/assets/qq_emoji/107/png/107.png"),
        QQFaceEntry(id: 108, name: "阴险", url: "https://koishi.js.org/QFace/assets/qq_emoji/108/png/108.png"),
        QQFaceEntry(id: 109, name: "左亲亲", url: "https://koishi.js.org/QFace/assets/qq_emoji/109/png/109.png"),
        QQFaceEntry(id: 110, name: "吓", url: "https://koishi.js.org/QFace/assets/qq_emoji/110/png/110.png"),
        QQFaceEntry(id: 111, name: "可怜", url: "https://koishi.js.org/QFace/assets/qq_emoji/111/png/111.png"),
        QQFaceEntry(id: 112, name: "菜刀", url: "https://koishi.js.org/QFace/assets/qq_emoji/112/png/112.png"),
        QQFaceEntry(id: 114, name: "篮球", url: "https://koishi.js.org/QFace/assets/qq_emoji/114/png/114_0.png"),
        QQFaceEntry(id: 116, name: "示爱", url: "https://koishi.js.org/QFace/assets/qq_emoji/116/png/116.png"),
        QQFaceEntry(id: 118, name: "抱拳", url: "https://koishi.js.org/QFace/assets/qq_emoji/118/png/118.png"),
        QQFaceEntry(id: 119, name: "勾引", url: "https://koishi.js.org/QFace/assets/qq_emoji/119/png/119.png"),
        QQFaceEntry(id: 120, name: "拳头", url: "https://koishi.js.org/QFace/assets/qq_emoji/120/png/120.png"),
        QQFaceEntry(id: 121, name: "差劲", url: "https://koishi.js.org/QFace/assets/qq_emoji/121/png/121.png"),
        QQFaceEntry(id: 123, name: "NO", url: "https://koishi.js.org/QFace/assets/qq_emoji/123/png/123.png"),
        QQFaceEntry(id: 124, name: "OK", url: "https://koishi.js.org/QFace/assets/qq_emoji/124/png/124.png"),
        QQFaceEntry(id: 125, name: "转圈", url: "https://koishi.js.org/QFace/assets/qq_emoji/125/png/125.png"),
        QQFaceEntry(id: 129, name: "挥手", url: "https://koishi.js.org/QFace/assets/qq_emoji/129/png/129.png"),
        QQFaceEntry(id: 137, name: "鞭炮", url: "https://koishi.js.org/QFace/assets/qq_emoji/137/png/137_0.png"),
        QQFaceEntry(id: 144, name: "喝彩", url: "https://koishi.js.org/QFace/assets/qq_emoji/144/png/144.png"),
        QQFaceEntry(id: 146, name: "爆筋", url: "https://koishi.js.org/QFace/assets/qq_emoji/146/png/146.png"),
        QQFaceEntry(id: 147, name: "棒棒糖", url: "https://koishi.js.org/QFace/assets/qq_emoji/147/png/147.png"),
        QQFaceEntry(id: 148, name: "喝奶", url: "https://koishi.js.org/QFace/assets/qq_emoji/148/png/148.png"),
        QQFaceEntry(id: 169, name: "手枪", url: "https://koishi.js.org/QFace/assets/qq_emoji/169/png/169.png"),
        QQFaceEntry(id: 171, name: "茶", url: "https://koishi.js.org/QFace/assets/qq_emoji/171/png/171.png"),
        QQFaceEntry(id: 172, name: "眨眼睛", url: "https://koishi.js.org/QFace/assets/qq_emoji/172/png/172.png"),
        QQFaceEntry(id: 173, name: "泪奔", url: "https://koishi.js.org/QFace/assets/qq_emoji/173/png/173.png"),
        QQFaceEntry(id: 174, name: "无奈", url: "https://koishi.js.org/QFace/assets/qq_emoji/174/png/174.png"),
        QQFaceEntry(id: 175, name: "卖萌", url: "https://koishi.js.org/QFace/assets/qq_emoji/175/png/175.png"),
        QQFaceEntry(id: 176, name: "小纠结", url: "https://koishi.js.org/QFace/assets/qq_emoji/176/png/176.png"),
        QQFaceEntry(id: 177, name: "喷血", url: "https://koishi.js.org/QFace/assets/qq_emoji/177/png/177.png"),
        QQFaceEntry(id: 178, name: "斜眼笑", url: "https://koishi.js.org/QFace/assets/qq_emoji/178/png/178.png"),
        QQFaceEntry(id: 179, name: "doge", url: "https://koishi.js.org/QFace/assets/qq_emoji/179/png/179.png"),
        QQFaceEntry(id: 181, name: "戳一戳", url: "https://koishi.js.org/QFace/assets/qq_emoji/181/png/181_0.png"),
        QQFaceEntry(id: 182, name: "笑哭", url: "https://koishi.js.org/QFace/assets/qq_emoji/182/png/182.png"),
        QQFaceEntry(id: 183, name: "我最美", url: "https://koishi.js.org/QFace/assets/qq_emoji/183/png/183.png"),
        QQFaceEntry(id: 185, name: "羊驼", url: "https://koishi.js.org/QFace/assets/qq_emoji/185/png/185.png"),
        QQFaceEntry(id: 187, name: "幽灵", url: "https://koishi.js.org/QFace/assets/qq_emoji/187/png/187.png"),
        QQFaceEntry(id: 201, name: "点赞", url: "https://koishi.js.org/QFace/assets/qq_emoji/201/png/201.png"),
        QQFaceEntry(id: 212, name: "托腮", url: "https://koishi.js.org/QFace/assets/qq_emoji/212/png/212.png"),
        QQFaceEntry(id: 262, name: "脑阔疼", url: "https://koishi.js.org/QFace/assets/qq_emoji/262/png/262.png"),
        QQFaceEntry(id: 263, name: "沧桑", url: "https://koishi.js.org/QFace/assets/qq_emoji/263/png/263.png"),
        QQFaceEntry(id: 264, name: "捂脸", url: "https://koishi.js.org/QFace/assets/qq_emoji/264/png/264.png"),
        QQFaceEntry(id: 265, name: "辣眼睛", url: "https://koishi.js.org/QFace/assets/qq_emoji/265/png/265.png"),
        QQFaceEntry(id: 266, name: "哦哟", url: "https://koishi.js.org/QFace/assets/qq_emoji/266/png/266.png"),
        QQFaceEntry(id: 267, name: "头秃", url: "https://koishi.js.org/QFace/assets/qq_emoji/267/png/267.png"),
        QQFaceEntry(id: 268, name: "问号脸", url: "https://koishi.js.org/QFace/assets/qq_emoji/268/png/268.png"),
        QQFaceEntry(id: 269, name: "暗中观察", url: "https://koishi.js.org/QFace/assets/qq_emoji/269/png/269.png"),
        QQFaceEntry(id: 270, name: "emm", url: "https://koishi.js.org/QFace/assets/qq_emoji/270/png/270.png"),
        QQFaceEntry(id: 271, name: "吃瓜", url: "https://koishi.js.org/QFace/assets/qq_emoji/271/png/271.png"),
        QQFaceEntry(id: 272, name: "呵呵哒", url: "https://koishi.js.org/QFace/assets/qq_emoji/272/png/272.png"),
        QQFaceEntry(id: 273, name: "我酸了", url: "https://koishi.js.org/QFace/assets/qq_emoji/273/png/273.png"),
        QQFaceEntry(id: 277, name: "汪汪", url: "https://koishi.js.org/QFace/assets/qq_emoji/277/png/277.png"),
        QQFaceEntry(id: 281, name: "无眼笑", url: "https://koishi.js.org/QFace/assets/qq_emoji/281/png/281.png"),
        QQFaceEntry(id: 282, name: "敬礼", url: "https://koishi.js.org/QFace/assets/qq_emoji/282/png/282.png"),
        QQFaceEntry(id: 283, name: "狂笑", url: "https://koishi.js.org/QFace/assets/qq_emoji/283/png/283.png"),
        QQFaceEntry(id: 284, name: "面无表情", url: "https://koishi.js.org/QFace/assets/qq_emoji/284/png/284.png"),
        QQFaceEntry(id: 285, name: "摸鱼", url: "https://koishi.js.org/QFace/assets/qq_emoji/285/png/285.png"),
        QQFaceEntry(id: 286, name: "魔鬼笑", url: "https://koishi.js.org/QFace/assets/qq_emoji/286/png/286.png"),
        QQFaceEntry(id: 287, name: "哦", url: "https://koishi.js.org/QFace/assets/qq_emoji/287/png/287.png"),
        QQFaceEntry(id: 289, name: "睁眼", url: "https://koishi.js.org/QFace/assets/qq_emoji/289/png/289.png"),
        QQFaceEntry(id: 293, name: "摸锦鲤", url: "https://koishi.js.org/QFace/assets/qq_emoji/293/png/293.png"),
        QQFaceEntry(id: 294, name: "期待", url: "https://koishi.js.org/QFace/assets/qq_emoji/294/png/294.png"),
        QQFaceEntry(id: 295, name: "拿到红包", url: "https://koishi.js.org/QFace/assets/qq_emoji/295/png/295.png"),
        QQFaceEntry(id: 297, name: "拜谢", url: "https://koishi.js.org/QFace/assets/qq_emoji/297/png/297.png"),
        QQFaceEntry(id: 298, name: "元宝", url: "https://koishi.js.org/QFace/assets/qq_emoji/298/png/298.png"),
        QQFaceEntry(id: 299, name: "牛啊", url: "https://koishi.js.org/QFace/assets/qq_emoji/299/png/299.png"),
        QQFaceEntry(id: 300, name: "胖三斤", url: "https://koishi.js.org/QFace/assets/qq_emoji/300/png/300.png"),
        QQFaceEntry(id: 302, name: "左拜年", url: "https://koishi.js.org/QFace/assets/qq_emoji/302/png/302.png"),
        QQFaceEntry(id: 303, name: "右拜年", url: "https://koishi.js.org/QFace/assets/qq_emoji/303/png/303.png"),
        QQFaceEntry(id: 305, name: "右亲亲", url: "https://koishi.js.org/QFace/assets/qq_emoji/305/png/305.png"),
        QQFaceEntry(id: 306, name: "牛气冲天", url: "https://koishi.js.org/QFace/assets/qq_emoji/306/png/306.png"),
        QQFaceEntry(id: 307, name: "喵喵", url: "https://koishi.js.org/QFace/assets/qq_emoji/307/png/307.png"),
        QQFaceEntry(id: 311, name: "打call", url: "https://koishi.js.org/QFace/assets/qq_emoji/311/png/311_0.png"),
        QQFaceEntry(id: 312, name: "变形", url: "https://koishi.js.org/QFace/assets/qq_emoji/312/png/312_0.png"),
        QQFaceEntry(id: 314, name: "仔细分析", url: "https://koishi.js.org/QFace/assets/qq_emoji/314/png/314_0.png"),
        QQFaceEntry(id: 317, name: "菜汪", url: "https://koishi.js.org/QFace/assets/qq_emoji/317/png/317_0.png"),
        QQFaceEntry(id: 318, name: "崇拜", url: "https://koishi.js.org/QFace/assets/qq_emoji/318/png/318_0.png"),
        QQFaceEntry(id: 319, name: "比心", url: "https://koishi.js.org/QFace/assets/qq_emoji/319/png/319_0.png"),
        QQFaceEntry(id: 320, name: "庆祝", url: "https://koishi.js.org/QFace/assets/qq_emoji/320/png/320_0.png"),
        QQFaceEntry(id: 323, name: "嫌弃", url: "https://koishi.js.org/QFace/assets/qq_emoji/323/png/323.png"),
        QQFaceEntry(id: 324, name: "吃糖", url: "https://koishi.js.org/QFace/assets/qq_emoji/324/png/324_0.png"),
        QQFaceEntry(id: 325, name: "惊吓", url: "https://koishi.js.org/QFace/assets/qq_emoji/325/png/325_0.png"),
        QQFaceEntry(id: 326, name: "生气", url: "https://koishi.js.org/QFace/assets/qq_emoji/326/png/326_0.png"),
        QQFaceEntry(id: 332, name: "举牌牌", url: "https://koishi.js.org/QFace/assets/qq_emoji/332/png/332.png"),
        QQFaceEntry(id: 333, name: "烟花", url: "https://koishi.js.org/QFace/assets/qq_emoji/333/png/333_0.png"),
        QQFaceEntry(id: 334, name: "虎虎生威", url: "https://koishi.js.org/QFace/assets/qq_emoji/334/png/334.png"),
        QQFaceEntry(id: 336, name: "豹富", url: "https://koishi.js.org/QFace/assets/qq_emoji/336/png/336.png"),
        QQFaceEntry(id: 337, name: "花朵脸", url: "https://koishi.js.org/QFace/assets/qq_emoji/337/png/337_0.png"),
        QQFaceEntry(id: 338, name: "我想开了", url: "https://koishi.js.org/QFace/assets/qq_emoji/338/png/338_0.png"),
        QQFaceEntry(id: 339, name: "舔屏", url: "https://koishi.js.org/QFace/assets/qq_emoji/339/png/339_0.png"),
        QQFaceEntry(id: 341, name: "打招呼", url: "https://koishi.js.org/QFace/assets/qq_emoji/341/png/341_0.png"),
        QQFaceEntry(id: 342, name: "酸Q", url: "https://koishi.js.org/QFace/assets/qq_emoji/342/png/342_0.png"),
        QQFaceEntry(id: 343, name: "我方了", url: "https://koishi.js.org/QFace/assets/qq_emoji/343/png/343_0.png"),
        QQFaceEntry(id: 344, name: "大怨种", url: "https://koishi.js.org/QFace/assets/qq_emoji/344/png/344_0.png"),
        QQFaceEntry(id: 345, name: "红包多多", url: "https://koishi.js.org/QFace/assets/qq_emoji/345/png/345_0.png"),
        QQFaceEntry(id: 346, name: "你真棒棒", url: "https://koishi.js.org/QFace/assets/qq_emoji/346/png/346_0.png"),
        QQFaceEntry(id: 347, name: "大展宏兔", url: "https://koishi.js.org/QFace/assets/qq_emoji/347/png/347.png"),
        QQFaceEntry(id: 349, name: "坚强", url: "https://koishi.js.org/QFace/assets/qq_emoji/349/png/349_0.png"),
        QQFaceEntry(id: 350, name: "贴贴", url: "https://koishi.js.org/QFace/assets/qq_emoji/350/png/350_0.png"),
        QQFaceEntry(id: 351, name: "敲敲", url: "https://koishi.js.org/QFace/assets/qq_emoji/351/png/351_0.png"),
        QQFaceEntry(id: 352, name: "咦", url: "https://koishi.js.org/QFace/assets/qq_emoji/352/png/352.png"),
        QQFaceEntry(id: 353, name: "拜托", url: "https://koishi.js.org/QFace/assets/qq_emoji/353/png/353.png"),
        QQFaceEntry(id: 354, name: "尊嘟假嘟", url: "https://koishi.js.org/QFace/assets/qq_emoji/354/png/354.png"),
        QQFaceEntry(id: 355, name: "耶", url: "https://koishi.js.org/QFace/assets/qq_emoji/355/png/355.png"),
        QQFaceEntry(id: 356, name: "666", url: "https://koishi.js.org/QFace/assets/qq_emoji/356/png/356.png"),
        QQFaceEntry(id: 357, name: "裂开", url: "https://koishi.js.org/QFace/assets/qq_emoji/357/png/357.png"),
        QQFaceEntry(id: 358, name: "骰子", url: "https://koishi.js.org/QFace/assets/qq_emoji/358/png/358_0.png"),
        QQFaceEntry(id: 359, name: "包剪锤", url: "https://koishi.js.org/QFace/assets/qq_emoji/359/png/359_0.png"),
        QQFaceEntry(id: 360, name: "亲亲", url: "https://koishi.js.org/QFace/assets/qq_emoji/360/png/360_0.png"),
        QQFaceEntry(id: 361, name: "狗狗笑哭", url: "https://koishi.js.org/QFace/assets/qq_emoji/361/png/361_0.png"),
        QQFaceEntry(id: 362, name: "好兄弟", url: "https://koishi.js.org/QFace/assets/qq_emoji/362/png/362_0.png"),
        QQFaceEntry(id: 363, name: "狗狗可怜", url: "https://koishi.js.org/QFace/assets/qq_emoji/363/png/363_0.png"),
        QQFaceEntry(id: 364, name: "超级赞", url: "https://koishi.js.org/QFace/assets/qq_emoji/364/png/364_0.png"),
        QQFaceEntry(id: 365, name: "狗狗生气", url: "https://koishi.js.org/QFace/assets/qq_emoji/365/png/365_0.png"),
        QQFaceEntry(id: 366, name: "芒狗", url: "https://koishi.js.org/QFace/assets/qq_emoji/366/png/366_0.png"),
        QQFaceEntry(id: 367, name: "狗狗疑问", url: "https://koishi.js.org/QFace/assets/qq_emoji/367/png/367_0.png"),
        QQFaceEntry(id: 368, name: "奥特笑哭", url: "https://koishi.js.org/QFace/assets/qq_emoji/368/png/368_0.png"),
        QQFaceEntry(id: 369, name: "彩虹", url: "https://koishi.js.org/QFace/assets/qq_emoji/369/png/369_0.png"),
        QQFaceEntry(id: 370, name: "祝贺", url: "https://koishi.js.org/QFace/assets/qq_emoji/370/png/370_0.png"),
        QQFaceEntry(id: 371, name: "冒泡", url: "https://koishi.js.org/QFace/assets/qq_emoji/371/png/371_0.png"),
        QQFaceEntry(id: 372, name: "气呼呼", url: "https://koishi.js.org/QFace/assets/qq_emoji/372/png/372_0.png"),
        QQFaceEntry(id: 373, name: "忙", url: "https://koishi.js.org/QFace/assets/qq_emoji/373/png/373_0.png"),
        QQFaceEntry(id: 374, name: "波波流泪", url: "https://koishi.js.org/QFace/assets/qq_emoji/374/png/374_0.png"),
        QQFaceEntry(id: 375, name: "超级鼓掌", url: "https://koishi.js.org/QFace/assets/qq_emoji/375/png/375_0.png"),
        QQFaceEntry(id: 376, name: "跺脚", url: "https://koishi.js.org/QFace/assets/qq_emoji/376/png/376_0.png"),
        QQFaceEntry(id: 377, name: "嗨", url: "https://koishi.js.org/QFace/assets/qq_emoji/377/png/377_0.png"),
        QQFaceEntry(id: 378, name: "企鹅笑哭", url: "https://koishi.js.org/QFace/assets/qq_emoji/378/png/378_0.png"),
        QQFaceEntry(id: 379, name: "企鹅流泪", url: "https://koishi.js.org/QFace/assets/qq_emoji/379/png/379_0.png"),
        QQFaceEntry(id: 380, name: "真棒", url: "https://koishi.js.org/QFace/assets/qq_emoji/380/png/380_0.png"),
        QQFaceEntry(id: 381, name: "路过", url: "https://koishi.js.org/QFace/assets/qq_emoji/381/png/381_0.png"),
        QQFaceEntry(id: 382, name: "emo", url: "https://koishi.js.org/QFace/assets/qq_emoji/382/png/382_0.png"),
        QQFaceEntry(id: 383, name: "企鹅爱心", url: "https://koishi.js.org/QFace/assets/qq_emoji/383/png/383_0.png"),
        QQFaceEntry(id: 384, name: "晚安", url: "https://koishi.js.org/QFace/assets/qq_emoji/384/png/384_0.png"),
        QQFaceEntry(id: 385, name: "太气了", url: "https://koishi.js.org/QFace/assets/qq_emoji/385/png/385_0.png"),
        QQFaceEntry(id: 386, name: "呜呜呜", url: "https://koishi.js.org/QFace/assets/qq_emoji/386/png/386_0.png"),
        QQFaceEntry(id: 387, name: "太好笑", url: "https://koishi.js.org/QFace/assets/qq_emoji/387/png/387_0.png"),
        QQFaceEntry(id: 388, name: "太头疼", url: "https://koishi.js.org/QFace/assets/qq_emoji/388/png/388_0.png"),
        QQFaceEntry(id: 389, name: "太赞了", url: "https://koishi.js.org/QFace/assets/qq_emoji/389/png/389_0.png"),
        QQFaceEntry(id: 390, name: "太头秃", url: "https://koishi.js.org/QFace/assets/qq_emoji/390/png/390_0.png"),
        QQFaceEntry(id: 391, name: "太沧桑", url: "https://koishi.js.org/QFace/assets/qq_emoji/391/png/391_0.png"),
        QQFaceEntry(id: 392, name: "龙年快乐", url: "https://koishi.js.org/QFace/assets/qq_emoji/392/png/392_0.png"),
        QQFaceEntry(id: 393, name: "新年中龙", url: "https://koishi.js.org/QFace/assets/qq_emoji/393/png/393_0.png"),
        QQFaceEntry(id: 394, name: "新年大龙", url: "https://koishi.js.org/QFace/assets/qq_emoji/394/png/394_0.png"),
        QQFaceEntry(id: 395, name: "略略略", url: "https://koishi.js.org/QFace/assets/qq_emoji/395/png/395_0.png"),
        QQFaceEntry(id: 396, name: "狼狗", url: "https://koishi.js.org/QFace/assets/qq_emoji/396/png/396_0.png"),
        QQFaceEntry(id: 397, name: "抛媚眼", url: "https://koishi.js.org/QFace/assets/qq_emoji/397/png/397_0.png"),
        QQFaceEntry(id: 398, name: "超级ok", url: "https://koishi.js.org/QFace/assets/qq_emoji/398/png/398_0.png"),
        QQFaceEntry(id: 399, name: "tui", url: "https://koishi.js.org/QFace/assets/qq_emoji/399/png/399_0.png"),
        QQFaceEntry(id: 400, name: "快乐", url: "https://koishi.js.org/QFace/assets/qq_emoji/400/png/400_0.png"),
        QQFaceEntry(id: 401, name: "超级转圈", url: "https://koishi.js.org/QFace/assets/qq_emoji/401/png/401_0.png"),
        QQFaceEntry(id: 402, name: "别说话", url: "https://koishi.js.org/QFace/assets/qq_emoji/402/png/402_0.png"),
        QQFaceEntry(id: 403, name: "出去玩", url: "https://koishi.js.org/QFace/assets/qq_emoji/403/png/403_0.png"),
        QQFaceEntry(id: 404, name: "闪亮登场", url: "https://koishi.js.org/QFace/assets/qq_emoji/404/png/404_0.png"),
        QQFaceEntry(id: 405, name: "好运来", url: "https://koishi.js.org/QFace/assets/qq_emoji/405/png/405_0.png"),
        QQFaceEntry(id: 406, name: "姐是女王", url: "https://koishi.js.org/QFace/assets/qq_emoji/406/png/406_0.png"),
        QQFaceEntry(id: 407, name: "我听听", url: "https://koishi.js.org/QFace/assets/qq_emoji/407/png/407_0.png"),
        QQFaceEntry(id: 408, name: "臭美", url: "https://koishi.js.org/QFace/assets/qq_emoji/408/png/408_0.png"),
        QQFaceEntry(id: 409, name: "送你花花", url: "https://koishi.js.org/QFace/assets/qq_emoji/409/png/409_0.png"),
        QQFaceEntry(id: 410, name: "么么哒", url: "https://koishi.js.org/QFace/assets/qq_emoji/410/png/410_0.png"),
        QQFaceEntry(id: 411, name: "一起嗨", url: "https://koishi.js.org/QFace/assets/qq_emoji/411/png/411_0.png"),
        QQFaceEntry(id: 412, name: "开心", url: "https://koishi.js.org/QFace/assets/qq_emoji/412/png/412_0.png"),
        QQFaceEntry(id: 413, name: "摇起来", url: "https://koishi.js.org/QFace/assets/qq_emoji/413/png/413_0.png"),
        QQFaceEntry(id: 415, name: "划龙舟", url: "https://koishi.js.org/QFace/assets/qq_emoji/415/png/415_0.png"),
        QQFaceEntry(id: 416, name: "中龙舟", url: "https://koishi.js.org/QFace/assets/qq_emoji/416/png/416_0.png"),
        QQFaceEntry(id: 417, name: "大龙舟", url: "https://koishi.js.org/QFace/assets/qq_emoji/417/png/417_0.png"),
        QQFaceEntry(id: 418, name: "填罐罐", url: "https://koishi.js.org/QFace/assets/qq_emoji/418/png/418_0.png"),
        QQFaceEntry(id: 419, name: "火车", url: "https://koishi.js.org/QFace/assets/qq_emoji/419/png/419_0.png"),
        QQFaceEntry(id: 420, name: "中火车", url: "https://koishi.js.org/QFace/assets/qq_emoji/420/png/420_0.png"),
        QQFaceEntry(id: 421, name: "大火车", url: "https://koishi.js.org/QFace/assets/qq_emoji/421/png/421_0.png"),
        QQFaceEntry(id: 422, name: "粽于等到你", url: "https://koishi.js.org/QFace/assets/qq_emoji/422/png/422_0.png"),
        QQFaceEntry(id: 423, name: "复兴号", url: "https://koishi.js.org/QFace/assets/qq_emoji/423/png/423_0.png"),
        QQFaceEntry(id: 424, name: "续标识", url: "https://koishi.js.org/QFace/assets/qq_emoji/424/png/424_0.png"),
        QQFaceEntry(id: 425, name: "求放过", url: "https://koishi.js.org/QFace/assets/qq_emoji/425/png/425_0.png"),
        QQFaceEntry(id: 426, name: "玩火", url: "https://koishi.js.org/QFace/assets/qq_emoji/426/png/426_0.png"),
        QQFaceEntry(id: 427, name: "偷感", url: "https://koishi.js.org/QFace/assets/qq_emoji/427/png/427_0.png"),
        QQFaceEntry(id: 428, name: "收到", url: "https://koishi.js.org/QFace/assets/qq_emoji/428/png/428.png"),
        QQFaceEntry(id: 429, name: "蛇年快乐", url: "https://koishi.js.org/QFace/assets/qq_emoji/429/png/429_0.png"),
        QQFaceEntry(id: 430, name: "蛇身", url: "https://koishi.js.org/QFace/assets/qq_emoji/430/png/430_0.png"),
        QQFaceEntry(id: 431, name: "蛇尾", url: "https://koishi.js.org/QFace/assets/qq_emoji/431/png/431_0.png"),
        QQFaceEntry(id: 432, name: "灵蛇献瑞", url: "https://koishi.js.org/QFace/assets/qq_emoji/432/png/432_0.png"),
        QQFaceEntry(id: 433, name: "大鸽", url: "https://koishi.js.org/QFace/assets/qq_emoji/433/png/433_0.png"),
        QQFaceEntry(id: 434, name: "鸽来了", url: "https://koishi.js.org/QFace/assets/qq_emoji/434/png/434_0.png"),
        QQFaceEntry(id: 435, name: "关我鸟事", url: "https://koishi.js.org/QFace/assets/qq_emoji/435/png/435_0.png"),
        QQFaceEntry(id: 436, name: "跟鸽走", url: "https://koishi.js.org/QFace/assets/qq_emoji/436/png/436_0.png"),
        QQFaceEntry(id: 437, name: "鸽鸽生气", url: "https://koishi.js.org/QFace/assets/qq_emoji/437/png/437_0.png"),
        QQFaceEntry(id: 438, name: "可靠", url: "https://koishi.js.org/QFace/assets/qq_emoji/438/png/438_0.png"),
        QQFaceEntry(id: 439, name: "鸽瞅瞅", url: "https://koishi.js.org/QFace/assets/qq_emoji/439/png/439_0.png"),
        QQFaceEntry(id: 440, name: "鸽喜欢", url: "https://koishi.js.org/QFace/assets/qq_emoji/440/png/440_0.png"),
        QQFaceEntry(id: 441, name: "相信鸽", url: "https://koishi.js.org/QFace/assets/qq_emoji/441/png/441_0.png"),
        QQFaceEntry(id: 442, name: "鸽王", url: "https://koishi.js.org/QFace/assets/qq_emoji/442/png/442_0.png"),
        QQFaceEntry(id: 443, name: "戳一下", url: "https://koishi.js.org/QFace/assets/qq_emoji/443/png/443.png"),
        QQFaceEntry(id: 444, name: "超级6", url: "https://koishi.js.org/QFace/assets/qq_emoji/444/png/444.png"),
        QQFaceEntry(id: 445, name: "比个心", url: "https://koishi.js.org/QFace/assets/qq_emoji/445/png/445.png"),
        QQFaceEntry(id: 446, name: "超级心碎", url: "https://koishi.js.org/QFace/assets/qq_emoji/446/png/446.png"),
        QQFaceEntry(id: 447, name: "太赞了", url: "https://koishi.js.org/QFace/assets/qq_emoji/447/png/447.png"),
        QQFaceEntry(id: 448, name: "放大招", url: "https://koishi.js.org/QFace/assets/qq_emoji/448/png/448.png"),
        QQFaceEntry(id: 449, name: "+1", url: "https://koishi.js.org/QFace/assets/qq_emoji/449/png/449.png"),
        QQFaceEntry(id: 450, name: "撇嘴", url: "https://koishi.js.org/QFace/assets/qq_emoji/450/png/450_0.png"),
        QQFaceEntry(id: 451, name: "色", url: "https://koishi.js.org/QFace/assets/qq_emoji/451/png/451_0.png"),
        QQFaceEntry(id: 452, name: "微笑", url: "https://koishi.js.org/QFace/assets/qq_emoji/452/png/452_0.png"),
        QQFaceEntry(id: 453, name: "发呆", url: "https://koishi.js.org/QFace/assets/qq_emoji/453/png/453_0.png"),
        QQFaceEntry(id: 454, name: "得意", url: "https://koishi.js.org/QFace/assets/qq_emoji/454/png/454_0.png"),
        QQFaceEntry(id: 455, name: "害羞", url: "https://koishi.js.org/QFace/assets/qq_emoji/455/png/455_0.png"),
        QQFaceEntry(id: 456, name: "闭嘴", url: "https://koishi.js.org/QFace/assets/qq_emoji/456/png/456_0.png"),
        QQFaceEntry(id: 457, name: "睡", url: "https://koishi.js.org/QFace/assets/qq_emoji/457/png/457_0.png"),
        QQFaceEntry(id: 458, name: "我吗", url: "https://koishi.js.org/QFace/assets/qq_emoji/458/png/458_0.png"),
        QQFaceEntry(id: 459, name: "优雅", url: "https://koishi.js.org/QFace/assets/qq_emoji/459/png/459_0.png"),
        QQFaceEntry(id: 460, name: "硬撑", url: "https://koishi.js.org/QFace/assets/qq_emoji/460/png/460_0.png"),
        QQFaceEntry(id: 461, name: "宕机", url: "https://koishi.js.org/QFace/assets/qq_emoji/461/png/461_0.png"),
        QQFaceEntry(id: 462, name: "无语", url: "https://koishi.js.org/QFace/assets/qq_emoji/462/png/462_0.png"),
        QQFaceEntry(id: 463, name: "新年快乐", url: "https://koishi.js.org/QFace/assets/qq_emoji/463/png/463_0.png"),
        QQFaceEntry(id: 464, name: "马上到", url: "https://koishi.js.org/QFace/assets/qq_emoji/464/png/464_0.png"),
        QQFaceEntry(id: 465, name: "拆红包", url: "https://koishi.js.org/QFace/assets/qq_emoji/465/png/465_0.png"),
        QQFaceEntry(id: 466, name: "羞羞哒", url: "https://koishi.js.org/QFace/assets/qq_emoji/466/png/466_0.png"),
        QQFaceEntry(id: 467, name: "摇花手", url: "https://koishi.js.org/QFace/assets/qq_emoji/467/png/467_0.png"),
        QQFaceEntry(id: 468, name: "失眠", url: "https://koishi.js.org/QFace/assets/qq_emoji/468/png/468_0.png"),
        QQFaceEntry(id: 469, name: "坚毅", url: "https://koishi.js.org/QFace/assets/qq_emoji/469/png/469_0.png"),
        QQFaceEntry(id: 470, name: "马到成功", url: "https://koishi.js.org/QFace/assets/qq_emoji/470/png/470.png"),
        QQFaceEntry(id: 471, name: "深情", url: "https://koishi.js.org/QFace/assets/qq_emoji/471/png/471_0.png"),
        QQFaceEntry(id: 472, name: "心动", url: "https://koishi.js.org/QFace/assets/qq_emoji/472/png/472_0.png"),
        QQFaceEntry(id: 473, name: "爱意", url: "https://koishi.js.org/QFace/assets/qq_emoji/473/png/473_0.png"),
        QQFaceEntry(id: 474, name: "给你一拳", url: "https://koishi.js.org/QFace/assets/qq_emoji/474/png/474_0.png"),
        QQFaceEntry(id: 475, name: "干饭", url: "https://koishi.js.org/QFace/assets/qq_emoji/475/png/475_0.png"),
        QQFaceEntry(id: 476, name: "不是吧", url: "https://koishi.js.org/QFace/assets/qq_emoji/476/png/476_0.png"),
        QQFaceEntry(id: 477, name: "你懂的", url: "https://koishi.js.org/QFace/assets/qq_emoji/477/png/477_0.png"),
        QQFaceEntry(id: 478, name: "对的对的", url: "https://koishi.js.org/QFace/assets/qq_emoji/478/png/478_0.png"),
        QQFaceEntry(id: 479, name: "不对不对", url: "https://koishi.js.org/QFace/assets/qq_emoji/479/png/479_0.png"),
        QQFaceEntry(id: 480, name: "散味儿", url: "https://koishi.js.org/QFace/assets/qq_emoji/480/png/480_0.png"),
        QQFaceEntry(id: 481, name: "学习", url: "https://koishi.js.org/QFace/assets/qq_emoji/481/png/481_0.png"),
        QQFaceEntry(id: 482, name: "热化了", url: "https://koishi.js.org/QFace/assets/qq_emoji/482/png/482_0.png"),
        QQFaceEntry(id: 483, name: "略", url: "https://koishi.js.org/QFace/assets/qq_emoji/483/png/483_0.png"),
        QQFaceEntry(id: 484, name: "比爱心", url: "https://koishi.js.org/QFace/assets/qq_emoji/484/png/484_0.png"),
        QQFaceEntry(id: 485, name: "开学啦", url: "https://koishi.js.org/QFace/assets/qq_emoji/485/png/485_0.png"),
        QQFaceEntry(id: 486, name: "开学啦2", url: "https://koishi.js.org/QFace/assets/qq_emoji/486/png/486_0.png"),
        QQFaceEntry(id: 487, name: "开学啦3", url: "https://koishi.js.org/QFace/assets/qq_emoji/487/png/487_0.png"),
        QQFaceEntry(id: 488, name: "开学大吉", url: "https://koishi.js.org/QFace/assets/qq_emoji/488/png/488_0.png"),
        QQFaceEntry(id: 489, name: "知识增加", url: "https://koishi.js.org/QFace/assets/qq_emoji/489/png/489_0.png"),
        QQFaceEntry(id: 490, name: "能送我吗", url: "https://koishi.js.org/QFace/assets/qq_emoji/490/png/490_0.png"),
        QQFaceEntry(id: 491, name: "自信学霸", url: "https://koishi.js.org/QFace/assets/qq_emoji/491/png/491_0.png"),
        QQFaceEntry(id: 492, name: "让我细品", url: "https://koishi.js.org/QFace/assets/qq_emoji/492/png/492_0.png"),
        QQFaceEntry(id: 493, name: "又是早八", url: "https://koishi.js.org/QFace/assets/qq_emoji/493/png/493_0.png"),
        QQFaceEntry(id: 494, name: "举杯邀月", url: "https://koishi.js.org/QFace/assets/qq_emoji/494/png/494_0.png"),
        QQFaceEntry(id: 495, name: "兔来", url: "https://koishi.js.org/QFace/assets/qq_emoji/495/png/495_0.png"),
        QQFaceEntry(id: 496, name: "阴晴圆缺", url: "https://koishi.js.org/QFace/assets/qq_emoji/496/png/496_0.png"),
        QQFaceEntry(id: 497, name: "休假了", url: "https://koishi.js.org/QFace/assets/qq_emoji/497/png/497_0.png"),
        QQFaceEntry(id: 498, name: "中!", url: "https://koishi.js.org/QFace/assets/qq_emoji/498/png/498_0.png"),
        QQFaceEntry(id: 499, name: "观月C位", url: "https://koishi.js.org/QFace/assets/qq_emoji/499/png/499_0.png"),
        QQFaceEntry(id: 500, name: "秋秋赏月", url: "https://koishi.js.org/QFace/assets/qq_emoji/500/png/500_0.png"),
        QQFaceEntry(id: 501, name: "秋秋之约", url: "https://koishi.js.org/QFace/assets/qq_emoji/501/png/501_0.png"),
        QQFaceEntry(id: 502, name: "秋秋泛舟", url: "https://koishi.js.org/QFace/assets/qq_emoji/502/png/502_0.png"),
        QQFaceEntry(id: 503, name: "秋愿达成", url: "https://koishi.js.org/QFace/assets/qq_emoji/503/png/503_0.png"),
        QQFaceEntry(id: 504, name: "同你玩", url: "https://koishi.js.org/QFace/assets/qq_emoji/504/png/504_0.png"),
        QQFaceEntry(id: 505, name: "送花花", url: "https://koishi.js.org/QFace/assets/qq_emoji/505/png/505_0.png"),
        QQFaceEntry(id: 506, name: "捡到宝了", url: "https://koishi.js.org/QFace/assets/qq_emoji/506/png/506_0.png"),
        QQFaceEntry(id: 507, name: "被发现了", url: "https://koishi.js.org/QFace/assets/qq_emoji/507/png/507_0.png"),
        QQFaceEntry(id: 508, name: "马可波罗", url: "https://koishi.js.org/QFace/assets/qq_emoji/508/png/508_0.png"),
        QQFaceEntry(id: 509, name: "李白", url: "https://koishi.js.org/QFace/assets/qq_emoji/509/png/509_0.png"),
        QQFaceEntry(id: 510, name: "妲己", url: "https://koishi.js.org/QFace/assets/qq_emoji/510/png/510_0.png"),
        QQFaceEntry(id: 511, name: "朵莉亚", url: "https://koishi.js.org/QFace/assets/qq_emoji/511/png/511_0.png"),
        QQFaceEntry(id: 512, name: "王者召唤", url: "https://koishi.js.org/QFace/assets/qq_emoji/512/png/512_0.png"),
        QQFaceEntry(id: 513, name: "王者开大", url: "https://koishi.js.org/QFace/assets/qq_emoji/513/png/513_0.png"),
        QQFaceEntry(id: 514, name: "王者连招", url: "https://koishi.js.org/QFace/assets/qq_emoji/514/png/514_0.png"),
        QQFaceEntry(id: 515, name: "王者再战", url: "https://koishi.js.org/QFace/assets/qq_emoji/515/png/515_0.png"),
        QQFaceEntry(id: 524, name: "朵莉亚", url: "https://koishi.js.org/QFace/assets/qq_emoji/524/png/524_0.png"),
    ]
    static func label(_ id: Int) -> String {
        entries.first(where: { $0.id == id }).map { "[" + $0.name + "]" } ?? "[QQ表情 " + String(id) + "]"
    }
}

struct QQFaceSelectionPanel: View {
    let store: ChatStore
    let conversationID: String
    let onSelect: (QQFaceEntry) -> Void
    @State private var query = ""
    var body: some View {
        VStack {
            Text("按图片发送 QQ 表情；不是群聊原生表情标记。图片由第三方目录在线提供。")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            TextField("搜索名称或 ID", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 12) {
                    ForEach(QQFaceCatalog.entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || String($0.id).contains(query) }) { face in
                        Button { onSelect(face) } label: {
                            VStack {
                                AsyncImage(url: URL(string: face.url)) { image in
                                    image.resizable().scaledToFit()
                                } placeholder: { Text(String(face.id)).foregroundStyle(.secondary) }
                                .frame(width: 40, height: 40)
                                Text(face.name).font(.caption2).lineLimit(1)
                            }.frame(maxWidth: .infinity)
                        }.buttonStyle(.plain)
                        .accessibilityLabel("按图片发送 QQ 表情 " + face.name)
                    }
                }.padding(12)
            }
        }
    }
}

struct StickerLibraryPanel: View {
    let store: ChatStore
    let onSelect: (String) -> Void
    @State private var items: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var notice = ""
    var body: some View {
        VStack {
            PhotosPicker(selection: $items, maxSelectionCount: 20, matching: .images) {
                Label(importing ? "正在添加…" : "从相册添加表情包", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.disabled(importing)
            if !notice.isEmpty { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            if store.stickers.isEmpty {
                ContentUnavailableView("还没有表情包", systemImage: "photo.on.rectangle", description: Text("添加图片或 GIF 后点选发送。收藏仅保存在本机。"))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 12) {
                        ForEach(store.stickers, id: \.self) { name in
                            Button { onSelect(name) } label: {
                                if let image = store.stickerImage(name) {
                                    Image(uiImage: image).resizable().scaledToFit()
                                        .frame(height: 80).frame(maxWidth: .infinity)
                                }
                            }.buttonStyle(.plain)
                            .accessibilityLabel("发送收藏表情包")
                            .contextMenu {
                                Button("删除收藏", role: .destructive) { notice = store.removeSticker(name) ?? "已删除收藏" }
                            }
                        }
                    }.padding(12)
                }
            }
        }.padding(.horizontal, 12)
        .onChange(of: items) { _, selected in
            guard !selected.isEmpty, !importing else { return }
            importing = true
            Task {
                var failures = 0
                for item in selected {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { failures += 1; continue }
                        if store.addSticker(data) != nil { failures += 1 }
                    } catch { failures += 1 }
                }
                notice = failures == 0 ? "已添加，点选发送；长按可删除收藏。" : "部分图片添加失败，请选择 10MB 以内的图片或 GIF。"
                items = []
                importing = false
            }
        }
    }
}

struct EmojiSelectionPanel: View {
    @Binding var text: String
    let emojis: [String]
    let store: ChatStore
    let onSticker: (String) -> Void
    let conversationID: String
    let onQQFace: (QQFaceEntry) -> Void
    @State private var selectedTab = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("表情类型", selection: $selectedTab) {
                    Text("表情").tag(0)
                    Text("表情包").tag(1)
                    Text("QQ 表情").tag(2)
                }.pickerStyle(.segmented).padding(.horizontal, 16)
                if selectedTab == 2 {
                    QQFaceSelectionPanel(store: store, conversationID: conversationID) { face in
                        onQQFace(face)
                        dismiss()
                    }
                } else if selectedTab == 1 {
                    StickerLibraryPanel(store: store) { name in
                        onSticker(name)
                        dismiss()
                    }
                } else {
                Text(text.isEmpty ? "选择表情后插入消息" : text)
                    .font(.system(size: 18))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .accessibilityLabel("消息草稿预览")
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 48))], spacing: 12) {
                        ForEach(emojis, id: \.self) { emoji in
                            Button { text.append(contentsOf: emoji) } label: {
                                Text(emoji).font(.system(size: 30))
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("插入表情 " + emoji)
                        }
                    }
                    .padding(16)
                }
                }
            }
            .padding(.top, 12)
            .navigationTitle("表情与表情包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { if !text.isEmpty { text.removeLast() } } label: {
                        Image(systemName: "delete.left")
                    }
                    .disabled(text.isEmpty)
                    .accessibilityLabel("删除最后一个字符")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct ComposerInput: View {
    @Environment(\.colorScheme) private var colorScheme
    let store: ChatStore
    let conversationID: String
    let quoting: ChatMessage?
    @Binding var pickerItems: [PhotosPickerItem]
    @Binding var videoItem: PhotosPickerItem?
    @Binding var showFileImporter: Bool
    @Binding var recording: Bool
    let onToggleRecording: () -> Void
    let onSend: (String, ChatMessage?) -> Void
    let onFocus: () -> Void
    let onCancelQuote: () -> Void
    let focusTick: Int
    @State private var text = ""
    @FocusState private var isFocused: Bool
    @State private var showEmoji = false
    @State private var showMentions = false
    @State private var showPhotoPicker = false
    @State private var showVideoPicker = false
    private let emojis = ["😀","😂","🥰","😎","🤔","😭","👍","👎","❤️","🎉","🔥","🌹","🍀","☀️","🌙","⭐️","✅","❌","🤝","🙏","😴","🤣","😅","🥳","😇","🤩","😋","🤗"]
    private let blue = TGColor.accent

    private var mentionMembers: [(String, String)] {
        guard let conversation = store.conversation(conversationID) else { return [] }
        var seen = Set<String>()
        var result: [(String, String)] = []
        for message in conversation.messages {
            if let id = message.authorID, !seen.contains(id) {
                seen.insert(id)
                result.append((id, message.authorName))
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            if let quoting {
                HStack(alignment: .top, spacing: 0) {
                    RoundedRectangle(cornerRadius: 1).fill(blue)
                        .frame(width: 2, height: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(quoting.fromBot ? "引用自己" : quoting.authorName)
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(blue)
                            .lineLimit(1)
                        Text(quoting.summary)
                            .font(.system(size: 14)).foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .padding(.leading, 8).padding(.top, 10).padding(.trailing, 44)
                    Spacer()
                    Button(action: onCancelQuote) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("取消引用")
                }
                .frame(height: 52)
                .padding(.leading, 12).padding(.top, 8).padding(.bottom, 6)
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    Menu {
                        Button { showPhotoPicker = true } label: { Label("照片", systemImage: "photo.on.rectangle") }
                        Button { showVideoPicker = true } label: { Label("视频", systemImage: "video") }
                        Button { showFileImporter = true } label: { Label("文件", systemImage: "doc") }
                        Button { onToggleRecording() } label: {
                            Label(recording ? "停止录音" : "录制语音", systemImage: recording ? "stop.circle" : "mic")
                        }
                        if store.conversation(conversationID)?.scene == "group" {
                            Button { showMentions = true } label: { Label("提及成员", systemImage: "at") }
                        }
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 20)).foregroundStyle(blue)
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("附件")

                    ZStack(alignment: .leading) {
                        if text.isEmpty {
                            Text("消息").font(.system(size: 17))
                                .foregroundStyle(colorScheme == .dark
                                    ? Color.white.opacity(0.48) : Color.black.opacity(0.4))
                        }
                        TextField("", text: $text, axis: .vertical).lineLimit(1...5)
                            .font(.system(size: 17))
                            .focused($isFocused)
                    }
                    .padding(EdgeInsets(top: 5, leading: 12, bottom: 4, trailing: 11))
                    .frame(minHeight: 40)

                    Button {
                        isFocused = false
                        showEmoji = true
                    } label: {
                        Image(systemName: showEmoji ? "face.smiling.fill" : "face.smiling")
                            .font(.system(size: 20)).foregroundStyle(blue)
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("表情")
                }
                .padding(.leading, 4).padding(.trailing, 6)
                .glassEffect(.regular, in: Capsule())

                Button {
                    // The visible stop control must stop recording even when a draft exists.
                    if recording || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onToggleRecording()
                    } else {
                        let value = text
                        let quote = quoting
                        text = ""
                        onSend(value, quote)
                    }
                } label: {
                    let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ZStack {
                        if store.sendingConversationID == conversationID {
                            ProgressView()
                        } else if recording {
                            RoundedRectangle(cornerRadius: 3).fill(.primary)
                                .frame(width: 14, height: 14)
                                .glassEffect(.regular, in: Circle())
                                .frame(width: 40, height: 40)
                        } else {
                            Image(systemName: "mic.fill").font(.system(size: 17)).foregroundStyle(blue)
                                .frame(width: 40, height: 40)
                                .glassEffect(.regular, in: Circle())
                                .opacity(hasContent ? 0 : 1)
                                .scaleEffect(hasContent ? 0.2 : 1)
                            Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .glassEffect(.regular.tint(Color(uiColor: .systemBlue)), in: Circle())
                                .opacity(hasContent ? 1 : 0)
                                .scaleEffect(hasContent ? 1 : 0.2)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: hasContent)
                }
                .disabled(store.sendingConversationID != nil)
                .accessibilityLabel(recording ? "停止录音并发送语音" : (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "开始录音" : "发送消息"))
            }

        }
        .sheet(isPresented: $showEmoji, onDismiss: { isFocused = true }) {
            EmojiSelectionPanel(text: $text, emojis: emojis, store: store, onSticker: { name in
                let quote = quoting
                onCancelQuote()
                Task { await store.sendSticker(name, to: conversationID, quote: quote) }
            }, conversationID: conversationID, onQQFace: { face in
                let quote = quoting
                Task {
                    do {
                        guard let url = URL(string: face.url) else { return }
                        let (data, response) = try await URLSession.shared.data(from: url)
                        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 10 * 1024 * 1024, UIImage(data: data) != nil else {
                            store.error = "QQ 表情图片加载失败，请稍后再试。"
                            return
                        }
                        await store.sendImage(data, to: conversationID, quote: quote)
                    } catch { store.error = "QQ 表情图片加载失败，请检查网络。" }
                }
            })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showMentions) {
            NavigationStack {
                List(mentionMembers, id: \.0) { member in
                    Button("@" + member.1) {
                        text += store.mentionSyntax ? "<@" + member.0 + "> " : "@" + member.1 + " "
                        showMentions = false
                    }
                }
                .navigationTitle("提及成员")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { showMentions = false } } }
            }
        }
        .animation(.easeInOut(duration: 0.1), value: text)
        .onChange(of: isFocused) { _, value in
            if value { onFocus() }
        }
        .onChange(of: focusTick) { _, _ in
            isFocused = true
        }
        .onAppear { text = store.drafts[conversationID] ?? "" }
        .onDisappear {
            store.drafts[conversationID] = text
            UserDefaults.standard.set(store.drafts, forKey: "drafts")
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItems, maxSelectionCount: 9, matching: .images)
        .photosPicker(isPresented: $showVideoPicker, selection: $videoItem, matching: .videos)
    }
}

struct ImagePreview: View {
    let image: UIImage?
    let onClose: () -> Void
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in scale = max(1, min(6, lastScale * value)) }
                            .onEnded { _ in lastScale = scale }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation {
                            scale = scale > 1 ? 1 : 2
                            lastScale = scale
                        }
                    }
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 28)).foregroundStyle(.white.opacity(0.9))
                    }.padding()
                }
                Spacer()
            }
        }
    }
}

func isSameMessageGroup(_ a: ChatMessage, _ b: ChatMessage) -> Bool {
    a.fromBot == b.fromBot
        && a.authorName == b.authorName
        && abs(a.date.timeIntervalSince(b.date)) < 600
}

// TG DefaultDayPresentationTheme.swift:56 defaultDayAccentColor = 0x0088ff
enum TGColor {
    static let accent = Color(red: 0, green: 0x88 / 255, blue: 1.0)
    static let secondaryText = Color(red: 0x8e / 255, green: 0x8e / 255, blue: 0x93 / 255)
    static let separator = Color(red: 0xc8 / 255, green: 0xc7 / 255, blue: 0xcc / 255)
    static let pinnedRow = Color(red: 0xf7 / 255, green: 0xf7 / 255, blue: 0xf7 / 255)
}

// TG kCAMediaTimingFunctionSpring = CAMediaTimingFunction(0.380, 0.700, 0.125, 1.000)
// It is an overdamped bezier, NOT a bouncy spring (CAAnimationUtils.swift:186).
enum TGAnim {
    static let springCurve = Animation.timingCurve(0.380, 0.700, 0.125, 1.000, duration: 0.4)
    static let scrollToBottom = Animation.spring(duration: 1.15, bounce: 0.0)
    static let scrollToMessage = Animation.spring(duration: 0.4, bounce: 0.0)
    static let sendVertical = Animation.timingCurve(0.199, 0.011, 0.279, 0.910, duration: 0.3)
}

// TG DefaultDayPresentationTheme: outgoing gradient 0x57b2e0 -> 0x0088ff, incoming pure white.
func tgOutgoingFill() -> LinearGradient {
    LinearGradient(
        colors: [Color(red: 0x57 / 255, green: 0xb2 / 255, blue: 0xe0 / 255),
                 Color(red: 0x00 / 255, green: 0x88 / 255, blue: 1.0)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

struct TGDoubleCheck: View {
    let color: Color
    var body: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).offset(x: 6)
        }
        .foregroundStyle(color)
        .frame(width: 17, height: 11)
    }
}

func messageBubbleRadii(fromBot: Bool, mergedTop: Bool, mergedBottom: Bool) -> RectangleCornerRadii {
    // Every message is its own bubble (no merging).
    return RectangleCornerRadii(
        topLeading: 16, bottomLeading: 16,
        bottomTrailing: 16, topTrailing: 16
    )
}

struct MessageRow: View {
    let store: ChatStore
    let conversationID: String
    let message: ChatMessage
    let onQuote: (ChatMessage) -> Void
    let onJump: (String) -> Void
    let onPreview: (UIImage) -> Void
    let onEdit: (ChatMessage) -> Void
    let onReactionUsers: (String) -> Void
    let onPlayVideo: (URL) -> Void
    let onLongPress: (ChatMessage) -> Void
    let onForward: (ChatMessage) -> Void
    let onSwipeReply: (ChatMessage) -> Void
    let availableWidth: CGFloat
    var mergedTop = false
    var mergedBottom = false
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playingAudio = false
    @State private var loadedImage: UIImage?
    @State private var videoThumbnail: UIImage?
    // Reset after completion or cancellation, including interrupted scrolling.
    @GestureState(resetTransaction: Transaction(animation: .easeOut(duration: 0.3)))
    private var dragOffset: CGFloat = 0
    private let replyThreshold: CGFloat = 72
    // TG ChatMessageItemCommon.swift: width-36 (<=500pt) else width*0.85
    // Short messages should be a narrow bubble, not a full-width bar.
    private var textBubbleWidth: CGFloat {
        let plain = message.text.isEmpty ? "[空消息]" : message.text
        if plain.contains("\n") { return bubbleMaxWidth - 22 }
        let font = UIFont.systemFont(ofSize: 17 * store.fontScale)
        let measured = (plain as NSString).size(withAttributes: [.font: font]).width
        let needed = ceil(measured) + 22 + 46 + 8
        return min(needed, bubbleMaxWidth - 22)
    }

    private var bubbleMaxWidth: CGFloat {
        availableWidth <= 500 ? max(1, availableWidth - 36) : max(1, floor(availableWidth * 0.85))
    }
    private var replyProgress: CGFloat {
        min(1.0, max(0.0, -dragOffset / replyThreshold))
    }
    private let blue = TGColor.accent

    private var avatarLetter: String {
        let name = message.authorName.trimmingCharacters(in: .whitespaces)
        if let last = name.last { return String(last) }
        return "?"
    }

    private var avatarColors: [Color] {
        let palettes: [[Color]] = [
            [.blue, .cyan], [.purple, .pink], [.orange, .yellow],
            [.green, .mint], [.indigo, .blue], [.pink, .orange]
        ]
        let sum = message.authorName.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palettes[sum % palettes.count]
    }

    private var avatar: some View {
        Group {
            if let urlString = message.authorAvatarURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    default:
                        letterAvatar
                    }
                }
            } else {
                letterAvatar
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
    }

    private var letterAvatar: some View {
        Text(avatarLetter)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(LinearGradient(colors: avatarColors, startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            if message.fromBot { Spacer(minLength: 3) } else { avatar }
            VStack(alignment: message.fromBot ? .trailing : .leading, spacing: 4) {
                if message.quotedText != nil || message.quotedID != nil {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5).fill(blue.opacity(0.7)).frame(width: 3)
                        Text(message.quotedText ?? "引用消息").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { if let id = message.quotedID { onJump(id) } }
                }
                content
                    .overlay(alignment: .bottomTrailing) {
                        if message.isImage || message.isVideo || message.isAudio {
                            HStack(spacing: 3) {
                                Text(message.date, format: .dateTime.hour().minute())
                                    .font(.system(size: 11))
                                if message.fromBot { statusIcon }
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.black.opacity(0.35), in: Capsule())
                            .padding(.trailing, 6).padding(.bottom, 6)
                        }
                    }
                if let buttons = message.buttons, !buttons.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(buttons, id: \.self) { label in
                            Text(label)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(blue)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .frame(maxWidth: 220)
                }
            }
            .frame(maxWidth: bubbleMaxWidth, alignment: message.fromBot ? .trailing : .leading)
            if message.fromBot { Color.clear.frame(width: 3, height: 1) } else { Spacer(minLength: 3) }
        }
        .frame(maxWidth: .infinity, alignment: message.fromBot ? .trailing : .leading)
        .offset(x: dragOffset)
        .overlay(alignment: .trailing) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 33, height: 33)
                .background(blue, in: Circle())
                .scaleEffect(0.65 + replyProgress * 0.35)
                .opacity(replyProgress)
                .padding(.trailing, 10)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 16, coordinateSpace: .local)
                .updating($dragOffset) { value, offset, _ in
                    let w = value.translation.width
                    let h = value.translation.height
                    // Direction changes must not leave the previous negative offset behind.
                    offset = 0
                    guard abs(w) > abs(h) * 1.5, w < 0 else { return }
                    offset = max(-replyThreshold - 20, w)
                }
                .onEnded { value in
                    let w = value.translation.width
                    let h = value.translation.height
                    guard w < -replyThreshold, abs(w) > abs(h) * 1.5 else { return }
                    onSwipeReply(message)
                }
        )
        .contextMenu {
            Button { onQuote(message) } label: { Label("回复", systemImage: "arrowshape.turn.up.left") }
            if !message.text.isEmpty {
                Button { UIPasteboard.general.string = message.text } label: { Label("复制", systemImage: "doc.on.doc") }
            }
            if !message.text.isEmpty {
                Button { onForward(message) } label: { Label("转发", systemImage: "arrowshape.turn.up.right") }
            }
            if message.status == "failed" {
                Button { Task { await store.retryMessage(conversationID: conversationID, messageID: message.id) } } label: { Label("重发", systemImage: "arrow.clockwise") }
            }
            if let image = loadedImage {
                Button { UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil); store.error = "图片已保存到相册。" } label: { Label("保存图片", systemImage: "square.and.arrow.down") }
            }
            if let name = message.videoFile, let url = store.mediaURL(named: name) {
                Button { UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil); store.error = "视频已保存到相册。" } label: { Label("保存视频", systemImage: "square.and.arrow.down") }
            }
            if message.fromBot && message.status == "sent" {
                Button {
                    Task { await store.recallMessage(conversationID: conversationID, messageID: message.id) }
                } label: { Label("撤回（2 分钟内）", systemImage: "arrow.uturn.backward") }
            }
            if store.conversation(conversationID)?.scene == "channel" {
                Menu("频道操作") {
                    if message.fromBot {
                        Button { onEdit(message) } label: { Label("编辑", systemImage: "pencil") }
                    }
                    Button { Task { await store.react(conversationID: conversationID, messageID: message.id) } } label: { Label("点赞回应", systemImage: "hand.thumbsup") }
                    Button { Task { await store.removeReaction(conversationID: conversationID, messageID: message.id) } } label: { Label("取消点赞", systemImage: "hand.thumbsdown") }
                    Button { Task { await store.pinMessage(conversationID: conversationID, messageID: message.id) } } label: { Label("置顶", systemImage: "pin") }
                    Button { Task { await store.unpinMessage(conversationID: conversationID, messageID: message.id) } } label: { Label("取消置顶", systemImage: "pin.slash") }
                    Button { Task { await store.publishAnnounce(conversationID: conversationID, messageID: message.id) } } label: { Label("设为公告", systemImage: "megaphone") }
                    Button { Task { await store.deleteAnnounce(conversationID: conversationID, messageID: message.id) } } label: { Label("取消公告", systemImage: "megaphone.slash") }
                    Button { onReactionUsers(message.id) } label: { Label("点赞用户", systemImage: "person.2") }

                }
            }
            Button(role: .destructive) { store.deleteMessage(conversationID: conversationID, messageID: message.id) } label: { Label("删除", systemImage: "trash") }
        }
        .task(id: message.videoFile) {
            guard let name = message.videoFile, let url = store.mediaURL(named: name), videoThumbnail == nil else { return }
            let thumbnail = await Task.detached(priority: .utility) { () -> UIImage? in
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 480, height: 320)
                guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
                return UIImage(cgImage: cgImage)
            }.value
            videoThumbnail = thumbnail
        }
        .task(id: message.localImage) {
            guard let name = message.localImage, loadedImage == nil else { return }
            let path = store.mediaURL(named: name)?.path
            let image = await Task.detached(priority: .userInitiated) {
                path.flatMap { UIImage(contentsOfFile: $0) }
            }.value
            loadedImage = image
        }
    }

    @ViewBuilder
    private var content: some View {
        if message.localImage != nil {
            if let image = loadedImage {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                    .onTapGesture { onPreview(image) }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 15).fill(Color(uiColor: .tertiarySystemBackground))
                    ProgressView()
                }
                .frame(width: 160, height: 160)
            }
        } else if let name = message.videoFile, let url = store.mediaURL(named: name) {
            Button { onPlayVideo(url) } label: {
                ZStack {
                    if let videoThumbnail {
                        Image(uiImage: videoThumbnail).resizable().scaledToFill()
                    } else {
                        Color.black.opacity(0.78)
                    }
                    Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(.white)
                        .shadow(radius: 4)
                }
                .frame(width: 240, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 15))
            }
            .buttonStyle(.plain)
        } else if let name = message.audioFile, let url = store.mediaURL(named: name) {
            Button { toggleAudio(url) } label: {
                HStack(spacing: 8) {
                    Image(systemName: playingAudio ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 22))
                    HStack(spacing: 2) {
                        ForEach(0..<8, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 1)
                                .frame(width: 2, height: CGFloat(6 + (index * 5) % 14))
                        }
                    }
                    Text(playingAudio ? "播放中" : (message.duration.map { "语音 \(Int($0))″" } ?? "语音消息")).font(.system(size: 14))
                }
                .foregroundStyle(message.fromBot ? Color.white : Color.primary)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(
                    message.fromBot ? AnyShapeStyle(tgOutgoingFill()) : AnyShapeStyle(Color.white),
                    in: UnevenRoundedRectangle(
                        cornerRadii: messageBubbleRadii(
                            fromBot: message.fromBot,
                            mergedTop: mergedTop,
                            mergedBottom: mergedBottom
                        )
                    )
                )
            }
        } else if let name = message.fileLocal, let url = store.mediaURL(named: name) {
            ShareLink(item: url) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.fill").font(.system(size: 24)).foregroundStyle(blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.fileName ?? "文件").font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Text("点击打开或分享").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 15).padding(.leading, 9).padding(.bottom, 15).padding(.trailing, 12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
            }
        } else if message.imageURL != nil || message.videoURL != nil || message.audioURL != nil {
            Button { store.retryMedia(messageID: message.id, conversationID: conversationID) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 15).fill(Color.white)
                    VStack(spacing: 6) {
                        Image(systemName: message.isVideo ? "play.circle" : (message.isAudio ? "waveform" : "photo"))
                            .font(.system(size: 28)).foregroundStyle(.secondary)
                        Text("点击加载" + (message.isVideo ? "视频" : (message.isAudio ? "语音" : "图片")))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 160, height: 160)
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                if !message.fromBot {
                    Text(message.authorName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0, green: 0x88 / 255, blue: 1.0))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ZStack(alignment: .bottomTrailing) {
                    Text(markdownText(message.text.isEmpty ? "[空消息]" : message.text))
                        .font(.system(size: 17 * store.fontScale))
                        .foregroundStyle(message.fromBot ? Color.white : Color.primary)
                        .frame(maxWidth: textBubbleWidth - 22, alignment: .leading)
                        .padding(.trailing, 46)
                    HStack(spacing: 3) {
                        Text(message.date, format: .dateTime.hour().minute())
                            .font(.system(size: 11))
                        if message.fromBot {
                            statusIcon
                        }
                    }
                    .foregroundStyle(message.fromBot ? Color.white.opacity(0.75) : Color.secondary)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .frame(maxWidth: textBubbleWidth, alignment: .leading)
            .background(
                UnevenRoundedRectangle(
                    cornerRadii: messageBubbleRadii(
                        fromBot: message.fromBot,
                        mergedTop: mergedTop,
                        mergedBottom: mergedBottom
                    )
                )
                .fill(message.fromBot ? AnyShapeStyle(tgOutgoingFill()) : AnyShapeStyle(Color.white))
            )
            if let reactions = message.reactions, !reactions.isEmpty {
                HStack(spacing: 4) {
                    ForEach(reactions.keys.sorted(), id: \.self) { key in
                        HStack(spacing: 3) {
                            Text(reactionEmoji(key))
                                .font(.system(size: 12))
                            Text("\(reactions[key] ?? 1)")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                    }
                }
                .padding(.top, 3)
            }
        }
    }

    private func reactionEmoji(_ id: String) -> String {
        if let code = Int(id), let scalar = UnicodeScalar(code), scalar.properties.isEmoji {
            return String(Character(scalar))
        }
        return "👍"
    }

    @ViewBuilder
    private var statusIcon: some View {
        if message.fromBot {
            // QQ acknowledges API acceptance, but does not provide read receipts.
            let status = message.status
            let symbol = status == "sending" ? "clock" : (status == "failed" ? "exclamationmark.circle.fill" : (status == "sent" ? "checkmark" : "questionmark.circle"))
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(status == "failed" ? Color.red : Color.white.opacity(0.9))
                .accessibilityLabel(status == "sending" ? "发送中" : (status == "failed" ? "发送失败" : (status == "sent" ? "QQ 接口已确认发送，已读状态未知" : "发送状态未知")))
        }
    }

    private func markdownText(_ text: String) -> AttributedString {
        var attributed: AttributedString
        if let parsed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            attributed = parsed
        } else {
            attributed = AttributedString(text)
        }
        // TG: entities rendered with linkTextColor (incoming 0x004bad, outgoing white).
        let linkColor: Color = message.fromBot ? .white : Color(red: 0, green: 0x4b / 255, blue: 0xad / 255)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let ns = text as NSString
        for match in detector?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
            guard let range = Range(match.range, in: attributed), let url = match.url else { continue }
            attributed[range].link = url
            attributed[range].foregroundColor = linkColor
        }
        return attributed
    }

    private func toggleAudio(_ url: URL) {
        if playingAudio {
            audioPlayer?.stop()
            playingAudio = false
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
            playingAudio = true
        } catch {
            playingAudio = false
            store.error = "该语音格式暂不支持播放（QQ 可能返回 silk 编码）。"
        }
    }
}

struct GuildListView: View {
    let store: ChatStore

    var body: some View {
        List {
            if store.guilds.isEmpty {
                Text("机器人未加入频道，或没有频道列表权限。").foregroundStyle(.secondary)
            }
            ForEach(store.guilds) { guild in
                Section(guild.name) {
                    if let channels = store.guildChannels[guild.id] {
                        ForEach(channels, id: \.self) { name in
                            Label(name, systemImage: "bubble.left.and.bubble.right")
                        }
                    } else {
                        Button("加载子频道") {
                            Task { await store.loadChannels(guildID: guild.id) }
                        }
                    }
                    if let members = store.guildMembers[guild.id] {
                        if members.isEmpty {
                            Text("没有可显示的成员").foregroundStyle(.secondary)
                        } else {
                            ForEach(members, id: \.self) { name in Text(name) }
                        }
                    } else {
                        Button("加载成员列表") {
                            Task { await store.loadMembers(guildID: guild.id) }
                        }
                    }
                }
            }
        }
        .navigationTitle("频道")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadGuilds() }
    }
}

struct SettingsView: View {
    let store: ChatStore
    var isTab = false
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    @State private var bgItem: PhotosPickerItem?
    private let blue = TGColor.accent

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(blue.gradient)
                            Text(String((store.botName.isEmpty ? "机" : store.botName).prefix(1)))
                                .font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                        }
                        .frame(width: 60, height: 60)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.botName.isEmpty ? "QQ 机器人" : store.botName)
                                .font(.system(size: 18, weight: .semibold))
                            Text(store.username.isEmpty ? "未登录" : "AppID " + store.username)
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle().fill(store.status == "已连接" ? Color.green : Color.orange).frame(width: 10, height: 10)
                    }
                    .padding(.vertical, 6)
                }
                Section("账号") {
                    LabeledContent("连接状态", value: store.status)
                    Button("重新连接") { store.reconnect() }
                }
                Section("外观") {
                    Picker("主题", selection: Binding(get: { store.appearance }, set: { store.appearance = $0 })) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                Section("会话") {
                    Toggle("显示归档会话", isOn: Binding(get: { store.showArchived }, set: { store.showArchived = $0 }))
                }
                Section("聊天外观") {
                    Picker("字体大小", selection: Binding(get: { store.fontScale }, set: { store.fontScale = $0 })) {
                        Text("小").tag(0.9)
                        Text("标准").tag(1.0)
                        Text("大").tag(1.15)
                    }
                    .pickerStyle(.segmented)
                    Picker("聊天背景", selection: Binding(get: { store.chatBackground }, set: { store.chatBackground = $0 })) {
                        Text("默认").tag("default")
                        Text("纯色").tag("plain")
                        Text("绿色").tag("green")
                        Text("蓝色").tag("blue")
                    }
                    Toggle("实验性 @ 标记（QQ 群不解析，默认关闭）", isOn: Binding(get: { store.mentionSyntax }, set: { store.mentionSyntax = $0 }))
                    PhotosPicker(selection: $bgItem, matching: .images, photoLibrary: .shared()) {
                        Text("选择聊天背景图")
                    }
                    if store.chatBackgroundImage != nil {
                        Button("恢复默认背景", role: .destructive) { store.clearBackgroundImage() }
                    }
                }
                Section("频道") {
                    NavigationLink("频道列表") { GuildListView(store: store) }
                }
                Section("数据") {
                    Button("清空全部聊天记录", role: .destructive) { confirmClear = true }
                }
                Section {
                    Button("退出登录", role: .destructive) {
                        CredentialStore.clear()
                        store.logout()
                        dismiss()
                    }
                } footer: {
                    Text("退出后需重新输入 AppID 与 AppSecret。")
                }
                Section("诊断") {
                    ShareLink(item: store.logText) { Label("导出日志", systemImage: "square.and.arrow.up") }
                    Button("清空日志") { store.logs.removeAll() }
                    LabeledContent("日志条数", value: "\(store.logs.count)")
                }
                Section("关于") {
                    LabeledContent("版本", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-") + ")")
                    LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "-")
                }
                Section("说明") {
                    Text("本 App 直接连接 QQ 官方机器人接口。锁屏或长时间后台会暂停连接，重新打开后自动重连。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isTab {
                    ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
                }
            }
            .confirmationDialog("清空全部聊天记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) { store.clearHistory() }
            }
            .onChange(of: bgItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        store.setBackgroundImage(data)
                    }
                    bgItem = nil
                }
            }
        }
        .tint(blue)
    }
}
