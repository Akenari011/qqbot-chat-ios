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
    var buttons: [String]?
    var status: String?

    init(id: String, text: String, timestamp: String, fromBot: Bool, authorName: String, imageURL: String? = nil, localImage: String? = nil, videoURL: String? = nil, videoFile: String? = nil, audioURL: String? = nil, audioFile: String? = nil, fileLocal: String? = nil, fileName: String? = nil, quotedText: String? = nil, quotedID: String? = nil, duration: Double? = nil, authorID: String? = nil, buttons: [String]? = nil, status: String? = nil) {
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
        guard let conversation = conversation(conversationID) else { return }
        guard conversation.scene == "channel" else {
            error = "当前仅频道消息支持撤回。"
            return
        }
        let encoded = conversationID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? conversationID
        do {
            _ = try await api("/channels/" + encoded + "/messages/" + messageID + "/recall", body: [:])
            deleteMessage(conversationID: conversationID, messageID: messageID)
            error = nil
        } catch {
            self.error = "撤回失败，可能需要频道管理权限。"
        }
    }

    func reconnectIfNeeded() {
        guard shouldRun, socket == nil, !connecting else { return }
        reconnectTask?.cancel()
        log("前台恢复，尝试重连")
        Task {
            do { try await openSocket(resume: sessionID != nil && sequence != nil) }
            catch { scheduleReconnect() }
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
                        try await packet(["op": 2, "d": ["token": "QQBot " + token, "intents": (1 << 25) | (1 << 26) | (1 << 30), "shard": [0, 1], "properties": [:]]])
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
                let emoji = faceMap[Int(idString) ?? -1] ?? "🙂"
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
            conversations[index].name = name
            if let replyID { conversations[index].replyID = replyID }
            if markUnread { conversations[index].unread += 1 }
            let updated = conversations.remove(at: index)
            conversations.insert(updated, at: 0)
        } else {
            let conversation = Conversation(id: target, scene: scene, name: name, lastText: message.summary, lastTimestamp: message.timestamp, unread: markUnread ? 1 : 0, messages: [message], replyID: replyID ?? "", replySeq: 0, pinned: nil, archived: nil, muted: nil)
            conversations.append(conversation)
        }
        sortConversations()
        saveConversations()
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
        guard !conversations[index].replyID.isEmpty else { error = "请先从 QQ 给机器人发送一条消息，再回复。"; return }
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
            guard let fileURL = mediaURL(named: mediaFile), let data = try? Data(contentsOf: fileURL) else { error = "媒体文件读取失败。"; return }
            let type: Int
            let ext: String
            switch mediaType {
            case "video": type = 2; ext = "mp4"
            case "audio": type = 3; ext = "m4a"
            case "file": type = 4; ext = (displayName as NSString?)?.pathExtension ?? "bin"
            default: type = 1; ext = "jpg"
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
        deleteMessage(conversationID: conversationID, messageID: messageID)
        await send(to: conversationID, text: message.text, mediaFile: mediaFile, mediaType: mediaType, quote: nil, displayName: message.fileName)
    }

    func deleteMessage(conversationID: String, messageID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].messages.removeAll { $0.id == messageID }
        if let last = conversations[index].messages.last {
            conversations[index].lastText = last.summary
            conversations[index].lastTimestamp = last.timestamp
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
    private let blue = Color(red: 0.20, green: 0.55, blue: 0.88)

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
    private let blue = Color(red: 0.20, green: 0.55, blue: 0.88)

    private var filtered: [Conversation] {
        let base = store.conversations.filter { store.showArchived || !($0.archived ?? false) }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return base }
        let needle = query.trimmingCharacters(in: .whitespaces)
        return base.filter {
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
                                ConversationRow(conversation: conversation)
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    store.deleteConversation(conversation.id)
                                } label: { Label("删除", systemImage: "trash") }
                                Button {
                                    store.togglePin(conversation.id)
                                } label: {
                                    Label(conversation.pinned == true ? "取消置顶" : "置顶", systemImage: "pin")
                                }
                                .tint(.orange)
                                Button {
                                    store.toggleMute(conversation.id)
                                } label: {
                                    Label(conversation.muted == true ? "取消静音" : "静音", systemImage: "bell.slash")
                                }
                                .tint(.gray)
                                Button {
                                    store.toggleArchive(conversation.id)
                                } label: {
                                    Label(conversation.archived == true ? "取消归档" : "归档", systemImage: "archivebox")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索会话和消息")
            .navigationTitle("聊天")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(editMode ? "完成" : "编辑") { editMode.toggle() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showComposeHint = true } label: { Image(systemName: "square.and.pencil") }
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
    private let blue = Color(red: 0.20, green: 0.55, blue: 0.88)

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
            Image(systemName: iconName)
                .font(.system(size: 26)).foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(LinearGradient(colors: avatarColors, startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(conversation.name)
                        .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    if conversation.pinned == true {
                        Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(conversation.lastDate, format: .dateTime.hour().minute())
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                HStack {
                    Text(conversation.lastText.isEmpty ? " " : conversation.lastText)
                        .font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if conversation.unread > 0 {
                        if conversation.muted == true {
                            Circle().fill(Color.secondary.opacity(0.6)).frame(width: 8, height: 8)
                        } else {
                            Text("\(conversation.unread)")
                                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(blue, in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
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
    @State private var scrollTick = 0
    @State private var renderLimit = 100
    @State private var showScrollButton = false
    @State private var initialUnread = 0
    @State private var showPins = false
    @State private var showKeyboardAlert = false
    @State private var keyboardText = ""
    private let blue = Color(red: 0.20, green: 0.55, blue: 0.88)

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
    private func messageCell(visible: [ChatMessage], index: Int, proxy: ScrollViewProxy) -> some View {
        let message = visible[index]
        let previous: ChatMessage? = index > 0 ? visible[index - 1] : nil
        let next: ChatMessage? = index < visible.count - 1 ? visible[index + 1] : nil
        let showDate = previous.map { !Calendar.current.isDate(message.date, inSameDayAs: $0.date) } ?? true
        let mergedTop = previous.map { isSameMessageGroup($0, message) } ?? false
        let mergedBottom = next.map { isSameMessageGroup(message, $0) } ?? false
        if showDate {
            Text(dateHeaderString(message.date))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
        MessageRow(
            store: store,
            conversationID: conversationID,
            message: message,
            mergedTop: mergedTop,
            mergedBottom: mergedBottom,
            onQuote: handleQuote,
            onJump: { target in withAnimation { proxy.scrollTo(target, anchor: .center) } },
            onPreview: handlePreview,
            onEdit: handleEdit,
            onReactionUsers: handleReactionUsers,
            onPlayVideo: handlePlayVideo,
            onLongPress: handleLongPress,
            onForward: handleForward
        )
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
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.red.opacity(0.06))
            }
            messageList
            composer
        }
        .navigationTitle(conversation?.name ?? "聊天")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(blue.gradient)
                        Text(String((conversation?.name ?? "聊").prefix(1)))
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    }
                    .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(conversation?.name ?? "聊天").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(store.status).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { showChatSearch = true } label: { Label("搜索", systemImage: "magnifyingglass") }
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
            initialUnread = conversation?.unread ?? 0
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
                Button("撤回") { Task { await store.recallMessage(conversationID: conversationID, messageID: message.id) } }
            }
            Button("删除", role: .destructive) { store.deleteMessage(conversationID: conversationID, messageID: message.id) }
            Button("取消", role: .cancel) { menuMessage = nil }
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
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
                                messageCell(visible: visibleMessages, index: index, proxy: proxy)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 12)
                }
                .background(chatBackground)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 120
                } action: { _, below in
                    showScrollButton = below
                }
                .overlay(alignment: .bottomTrailing) {
                    if showScrollButton, let last = conversation?.messages.last {
                        Button {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
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
                    if let target { withAnimation { proxy.scrollTo(target, anchor: .center) }; jumpTarget = nil }
                }
                .onChange(of: conversation?.messages.count) { _, _ in
                    if let last = conversation?.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onChange(of: scrollTick) { _, _ in
                    if let last = conversation?.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onAppear {
                    if initialUnread > 0, let conversation, conversation.messages.count >= initialUnread {
                        let target = conversation.messages[conversation.messages.count - initialUnread]
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            withAnimation { proxy.scrollTo(target.id, anchor: .top) }
                        }
                    } else if let last = conversation?.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if let quoting {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5).fill(blue).frame(width: 3, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(quoting.fromBot ? "引用自己" : quoting.authorName)
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(blue)
                        Text(quoting.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { self.quoting = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color(uiColor: .secondarySystemBackground))
            }
            HStack(spacing: 8) {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 9, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 20)).foregroundStyle(blue)
                }
                .accessibilityLabel("发送图片，最多九张")
                PhotosPicker(selection: $videoItem, matching: .videos, photoLibrary: .shared()) {
                    Image(systemName: "video").font(.system(size: 20)).foregroundStyle(blue)
                }
                .accessibilityLabel("发送视频")
                Button { showFileImporter = true } label: {
                    Image(systemName: "paperclip").font(.system(size: 20)).foregroundStyle(blue)
                }
                .accessibilityLabel("发送文件")
                Button { toggleRecording() } label: {
                    Image(systemName: recording ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(recording ? Color.red : blue)
                }
                .accessibilityLabel(recording ? "停止录音并发送" : "录制语音")
                ComposerInput(store: store, conversationID: conversationID, quoting: quoting, onSend: { text, quote in
                    quoting = nil
                    store.drafts[conversationID] = ""
                    UserDefaults.standard.set(store.drafts, forKey: "drafts")
                    Task { await store.sendText(text, to: conversationID, quote: quote) }
                }, onFocus: { scrollTick += 1 })
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .background(.clear)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }
}

struct ComposerInput: View {
    let store: ChatStore
    let conversationID: String
    let quoting: ChatMessage?
    let onSend: (String, ChatMessage?) -> Void
    let onFocus: () -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool
    @State private var showEmoji = false
    @State private var showMentions = false
    private let emojis = ["😀","😂","🥰","😎","🤔","😭","👍","👎","❤️","🎉","🔥","🌹","🍀","☀️","🌙","⭐️","✅","❌","🤝","🙏","😴","🤣","😅","🥳","😇","🤩","😋","🤗"]
    private let blue = Color(red: 0.20, green: 0.55, blue: 0.88)

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
            HStack(spacing: 6) {
                Button { showEmoji.toggle() } label: {
                    Image(systemName: showEmoji ? "face.smiling.fill" : "face.smiling")
                        .font(.system(size: 20)).foregroundStyle(blue)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("表情")
                if store.conversation(conversationID)?.scene == "group" {
                    Button { showMentions = true } label: {
                        Image(systemName: "at").font(.system(size: 20)).foregroundStyle(blue)
                            .frame(width: 40, height: 40)
                    }
                    .accessibilityLabel("提及成员")
                }
                TextField("消息", text: $text, axis: .vertical).lineLimit(1...5)
                .focused($isFocused)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .glassEffect(.regular, in: Capsule())
            Button {
                let value = text
                let quote = quoting
                text = ""
                onSend(value, quote)
            } label: {
                if store.sendingConversationID == conversationID {
                    ProgressView().frame(width: 40, height: 40)
                } else {
                    Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(blue, in: Circle())
                }
            }
            .disabled(store.sendingConversationID != nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("发送消息")
            }
            if showEmoji {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(emojis, id: \.self) { emoji in
                            Button { text += emoji } label: { Text(emoji).font(.system(size: 26)) }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .background(Color(uiColor: .secondarySystemBackground))
            }
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
        .onChange(of: isFocused) { _, value in
            if value { onFocus() }
        }
        .onAppear { text = store.drafts[conversationID] ?? "" }
        .onDisappear {
            store.drafts[conversationID] = text
            UserDefaults.standard.set(store.drafts, forKey: "drafts")
        }
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
    a.fromBot == b.fromBot && a.authorName == b.authorName && abs(a.date.timeIntervalSince(b.date)) < 300
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
    var mergedTop = false
    var mergedBottom = false
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playingAudio = false
    @State private var loadedImage: UIImage?
    @State private var videoThumbnail: UIImage?
    private let blue = Color(red: 0.20, green: 0.55, blue: 0.88)

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
        Text(avatarLetter)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(LinearGradient(colors: avatarColors, startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
    }

    private var botAvatar: some View {
        Image(systemName: "bubble.left.and.bubble.right.fill")
            .font(.system(size: 12)).foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(blue.gradient, in: Circle())
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.fromBot { Spacer(minLength: 48) } else { avatar }
            VStack(alignment: message.fromBot ? .trailing : .leading, spacing: 4) {
                if !message.fromBot {
                    Text(message.authorName).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
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
                if message.isImage || message.isVideo || message.isAudio {
                    HStack(spacing: 3) {
                        Text(message.date, format: .dateTime.hour().minute())
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                        statusIcon
                    }.padding(.horizontal, 4)
                }
            }
            if !message.fromBot { Spacer(minLength: 48) } else { botAvatar }
        }
        .frame(maxWidth: .infinity, alignment: message.fromBot ? .trailing : .leading)
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
                    Button { Task { await store.recallMessage(conversationID: conversationID, messageID: message.id) } } label: { Label("撤回", systemImage: "arrow.uturn.backward") }
                }
            }
            Button(role: .destructive) { store.deleteMessage(conversationID: conversationID, messageID: message.id) } label: { Label("删除", systemImage: "trash") }
        }
        .task(id: message.videoFile) {
            guard let name = message.videoFile, let url = store.mediaURL(named: name), videoThumbnail == nil else { return }
            let thumbnail = await Task.detached(priority: .utility) { () -> UIImage? in
                let asset = AVAsset(url: url)
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
                    message.fromBot ? blue : Color(uiColor: .systemBackground),
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: mergedTop ? 8 : 16,
                        bottomLeadingRadius: mergedBottom ? 8 : 16,
                        bottomTrailingRadius: mergedBottom ? 8 : 16,
                        topTrailingRadius: mergedTop ? 8 : 16
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
                .padding(12)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 15))
            }
        } else if message.imageURL != nil || message.videoURL != nil || message.audioURL != nil {
            ZStack {
                RoundedRectangle(cornerRadius: 15).fill(Color(uiColor: .tertiarySystemBackground))
                VStack(spacing: 6) {
                    ProgressView()
                    Text(message.isVideo ? "视频" : (message.isAudio ? "语音" : "图片")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, height: 160)
        } else {
            VStack(alignment: .trailing, spacing: 3) {
                Text(markdownText(message.text.isEmpty ? "[空消息]" : message.text))
                    .font(.system(size: 17 * store.fontScale))
                    .foregroundStyle(message.fromBot ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 3) {
                    Text(message.date, format: .dateTime.hour().minute())
                        .font(.system(size: 11))
                        .foregroundStyle(message.fromBot ? Color.white.opacity(0.75) : Color.secondary)
                    statusIcon
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(
                UnevenRoundedRectangle(
                    cornerRadii: RectangleCornerRadii(
                        topLeading: 16,
                        bottomLeading: message.fromBot ? 16 : 4,
                        bottomTrailing: message.fromBot ? 4 : 16,
                        topTrailing: 16
                    )
                )
                .fill(message.fromBot ? blue : Color(uiColor: .systemBackground))
            )
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if message.fromBot, let status = message.status {
            Image(systemName: status == "sending" ? "clock" : (status == "failed" ? "exclamationmark.circle" : "checkmark"))
                .font(.system(size: 9))
                .foregroundStyle(status == "failed" ? Color.red : (message.fromBot ? Color.white.opacity(0.8) : Color.secondary))
        }
    }

    private func markdownText(_ text: String) -> AttributedString {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(text)
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
    private let blue = Color(red: 0.20, green: 0.55, blue: 0.88)

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
