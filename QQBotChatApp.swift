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
    var buttons: [String]?
    var status: String?

    init(id: String, text: String, timestamp: String, fromBot: Bool, authorName: String, imageURL: String? = nil, localImage: String? = nil, videoURL: String? = nil, videoFile: String? = nil, audioURL: String? = nil, audioFile: String? = nil, fileLocal: String? = nil, fileName: String? = nil, quotedText: String? = nil, buttons: [String]? = nil, status: String? = nil) {
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
    var lastDate: Date { ISO8601DateFormatter().date(from: lastTimestamp) ?? .now }
    var isGroup: Bool { scene == "group" }
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
    var appearance: String = UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance") }
    }

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
    private var networkMonitor: NWPathMonitor?

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
        do {
            try await refreshToken(force: true)
            try await openSocket(resume: false)
            isLoggedIn = true
            error = nil
            if let data = try? JSONEncoder().encode(LoginInput(username: username, password: password)), let text = String(data: data, encoding: .utf8) {
                CredentialStore.save(text)
            }
            startNetworkMonitor()
        } catch {
            isLoggedIn = false
            self.error = "QQ 登录失败，请检查机器人凭证和网络。"
            stop()
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

    private func packet(_ value: [String: Any]) async throws {
        guard let socket else { throw URLError(.networkConnectionLost) }
        try await socket.send(.data(JSONSerialization.data(withJSONObject: value)))
    }

    private func refreshToken(force: Bool = false) async throws {
        if !force, !token.isEmpty, Date() < tokenExpires { return }
        let auth = try await api("/app/getAppAccessToken", body: ["appId": username, "clientSecret": password], authorized: false)
        guard let access = auth["access_token"] as? String else { throw URLError(.userAuthenticationRequired) }
        token = access
        let raw = auth["expires_in"]
        let seconds = (raw as? String).flatMap(Double.init) ?? (raw as? Double) ?? (raw as? Int).map(Double.init) ?? 7200
        tokenExpires = Date().addingTimeInterval(max(60, seconds - 300))
    }

    private func openSocket(resume: Bool) async throws {
        try await refreshToken()
        let gateway = try await api("/gateway/bot")
        guard let address = gateway["url"] as? String, let url = URL(string: address), url.scheme == "wss" else { throw URLError(.badURL) }
        let ws = URLSession.shared.webSocketTask(with: url)
        socket = ws
        ws.resume()
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
                } else if kind == "RESUMED" {
                    reconnectAttempt = 0
                    status = "已连接"
                } else if ["C2C_MESSAGE_CREATE", "GROUP_AT_MESSAGE_CREATE", "GROUP_MESSAGE_CREATE"].contains(kind) {
                    handleIncoming(kind: kind, payload: payload)
                } else if kind == "INTERACTION_CREATE" {
                    handleInteraction(payload)
                }
            }
        } catch {
            guard shouldRun, !Task.isCancelled else { return }
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

    private func handleIncoming(kind: String, payload: [String: Any]) {
        let author = payload["author"] as? [String: Any] ?? [:]
        let isGroup = kind != "C2C_MESSAGE_CREATE"
        let target = (isGroup ? payload["group_openid"] as? String : author["user_openid"] as? String) ?? ""
        guard !target.isEmpty, let id = payload["id"] as? String else { return }
        let name = isGroup ? "群聊 " + String(target.suffix(6)) : (author["username"] as? String ?? "QQ 用户")
        let content = payload["content"] as? String ?? ""
        let attachments = payload["attachments"] as? [[String: Any]] ?? []
        let attachment = attachments.first
        let remote = attachment?["url"] as? String
        let contentType = (attachment?["content_type"] as? String ?? "").lowercased()
        let fileName = (attachment?["filename"] as? String ?? "").lowercased()
        let isVideo = contentType.hasPrefix("video") || fileName.hasSuffix(".mp4") || fileName.hasSuffix(".mov")
        let isAudio = contentType.hasPrefix("audio") || fileName.hasSuffix(".silk") || fileName.hasSuffix(".amr") || fileName.hasSuffix(".mp3")
        let timestamp = payload["timestamp"] as? String ?? ISO8601DateFormatter().string(from: .now)
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
        let message = ChatMessage(
            id: id, text: content, timestamp: timestamp, fromBot: false, authorName: name,
            imageURL: (!isVideo && !isAudio) ? remote : nil,
            videoURL: isVideo ? remote : nil,
            audioURL: isAudio ? remote : nil,
            buttons: buttonLabels.isEmpty ? nil : buttonLabels
        )
        append(message, target: target, scene: isGroup ? "group" : "c2c", name: name, markUnread: activeConversationID != target, replyID: id)
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
        let isGroup = groupTarget != nil
        let target = groupTarget ?? userTarget ?? ""
        guard !target.isEmpty else { return }
        let eventID = payload["id"] as? String ?? UUID().uuidString
        let message = ChatMessage(
            id: "interaction-" + eventID,
            text: "点击了按钮：" + label,
            timestamp: ISO8601DateFormatter().string(from: .now),
            fromBot: false,
            authorName: "按钮交互"
        )
        append(message, target: target, scene: isGroup ? "group" : "c2c", name: isGroup ? "群聊 " + String(target.suffix(6)) : "QQ 用户", markUnread: activeConversationID != target, replyID: nil)
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
            let conversation = Conversation(id: target, scene: scene, name: name, lastText: message.summary, lastTimestamp: message.timestamp, unread: markUnread ? 1 : 0, messages: [message], replyID: replyID ?? "", replySeq: 0, pinned: nil)
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

    func togglePin(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].pinned = !(conversations[index].pinned ?? false)
        sortConversations()
        saveConversations()
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
        return UIImage(contentsOfFile: imagesURL.appendingPathComponent(name).path)
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

    func sendAudio(_ data: Data, to id: String, quote: ChatMessage? = nil) async {
        guard data.count <= 10 * 1024 * 1024 else { error = "语音文件过大。"; return }
        guard let name = saveMedia(data, ext: "m4a") else { error = "语音保存失败。"; return }
        await send(to: id, text: "", mediaFile: name, mediaType: "audio", quote: quote)
    }

    func sendFile(_ data: Data, name: String, to id: String) async {
        guard data.count <= 20 * 1024 * 1024 else { error = "文件不能超过 20MB。"; return }
        let ext = (name as NSString).pathExtension
        guard let saved = saveMedia(data, ext: ext.isEmpty ? "bin" : ext) else { error = "文件保存失败。"; return }
        await send(to: id, text: "", mediaFile: saved, mediaType: "file", quote: nil, displayName: name)
    }

    private func send(to id: String, text: String, mediaFile: String?, mediaType: String?, quote: ChatMessage?, displayName: String? = nil) async {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        guard !conversations[index].replyID.isEmpty else { error = "请先从 QQ 给机器人发送一条消息，再回复。"; return }
        guard sendingConversationID == nil else { return }
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
            quotedText: quote?.summary, status: "sending"
        )
        conversations[index].messages.append(pending)
        conversations[index].lastText = pending.summary
        conversations[index].lastTimestamp = pending.timestamp
        saveConversations()
        var body: [String: Any] = ["msg_id": conversation.replyID, "msg_seq": conversation.replySeq + 1]
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
            let path = conversation.scene == "c2c" ? "/v2/users/" : "/v2/groups/"
            let result = try await api(path + encoded + "/messages", body: body)
            guard let messageID = result["id"] as? String else { throw URLError(.badServerResponse) }
            if let current = conversations.firstIndex(where: { $0.id == id }),
               let mi = conversations[current].messages.firstIndex(where: { $0.id == tempID }) {
                let old = conversations[current].messages[mi]
                conversations[current].messages[mi] = ChatMessage(
                    id: messageID, text: old.text, timestamp: old.timestamp, fromBot: true,
                    authorName: old.authorName, localImage: old.localImage, videoFile: old.videoFile,
                    audioFile: old.audioFile, fileLocal: old.fileLocal, fileName: old.fileName,
                    quotedText: old.quotedText, buttons: old.buttons, status: "sent"
                )
                conversations[current].replySeq += 1
                saveConversations()
            }
        } catch {
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
        let path = scene == "c2c" ? "/v2/users/" : "/v2/groups/"
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

    var body: some View {
        Group {
            if store.isLoggedIn {
                ConversationListView(store: store)
            } else {
                LoginView(store: store)
            }
        }
        .preferredColorScheme(store.appearance == "light" ? .light : (store.appearance == "dark" ? .dark : nil))
        .animation(.easeInOut(duration: 0.25), value: store.isLoggedIn)
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
    @State private var query = ""
    private let blue = Color(red: 0.20, green: 0.55, blue: 0.88)

    private var filtered: [Conversation] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return store.conversations }
        let needle = query.trimmingCharacters(in: .whitespaces)
        return store.conversations.filter {
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
                    HStack(spacing: 6) {
                        Circle().fill(store.status == "已连接" ? Color.green : Color.orange).frame(width: 8, height: 8)
                        Text(store.status).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("设置")
                }
            }
            .navigationDestination(for: String.self) { id in
                ChatView(store: store, conversationID: id)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(store: store)
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: conversation.isGroup ? "person.2.fill" : "person.fill")
                .font(.system(size: 18)).foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(LinearGradient(colors: avatarColors, startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(conversation.name)
                        .font(.system(size: 16, weight: conversation.unread > 0 ? .bold : .semibold)).lineLimit(1)
                    if conversation.pinned == true {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(conversation.lastDate, format: .dateTime.hour().minute())
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    Text(conversation.lastText.isEmpty ? " " : conversation.lastText)
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if conversation.unread > 0 {
                        Text("\(conversation.unread)")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(blue, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct ChatView: View {
    let store: ChatStore
    let conversationID: String
    @State private var draft = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var quoting: ChatMessage?
    @State private var recorder: AVAudioRecorder?
    @State private var recording = false
    @State private var showEmoji = false
    @State private var showFileImporter = false
    private let emojis = ["😀","😂","🥰","😎","🤔","😭","👍","👎","❤️","🎉","🔥","🌹","🍀","☀️","🌙","⭐️","✅","❌","🤝","🙏","😴","🤣","😅","🥳","😇","🤩","😋","🤗"]
    private let blue = Color(red: 0.20, green: 0.55, blue: 0.88)

    private var conversation: Conversation? { store.conversation(conversationID) }

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.red.opacity(0.06))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if let conversation {
                            ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                                if index == 0 || !Calendar.current.isDate(message.date, inSameDayAs: conversation.messages[index - 1].date) {
                                    Text(message.date, format: .dateTime.year().month().day())
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                        .padding(.vertical, 6)
                                }
                                MessageRow(store: store, conversationID: conversationID, message: message, onQuote: { quoting = $0 }).id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 12)
                }
                .background(
                    LinearGradient(
                        colors: [Color(uiColor: .systemBackground), Color(uiColor: .secondarySystemBackground)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .animation(.easeOut(duration: 0.2), value: conversation?.messages.count)
                .onChange(of: conversation?.messages.count) { _, _ in
                    if let last = conversation?.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onAppear {
                    if let last = conversation?.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            composer
        }
        .navigationTitle(conversation?.name ?? "聊天")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(conversation?.name ?? "聊天").font(.system(size: 16, weight: .semibold))
                    Text(store.status).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            store.activeConversationID = conversationID
            store.markRead(conversationID)
            draft = store.drafts[conversationID] ?? ""
        }
        .onDisappear {
            store.activeConversationID = nil
            store.drafts[conversationID] = draft
            UserDefaults.standard.set(store.drafts, forKey: "drafts")
            if recording { recorder?.stop(); recorder = nil; recording = false }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await store.sendImage(data, to: conversationID)
                }
                pickerItem = nil
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
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        Task { await store.sendAudio(data, to: conversationID) }
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
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 20)).foregroundStyle(blue)
                }
                .accessibilityLabel("发送图片")
                PhotosPicker(selection: $videoItem, matching: .videos, photoLibrary: .shared()) {
                    Image(systemName: "video").font(.system(size: 20)).foregroundStyle(blue)
                }
                .accessibilityLabel("发送视频")
                Button { showEmoji.toggle() } label: {
                    Image(systemName: showEmoji ? "face.smiling.fill" : "face.smiling")
                        .font(.system(size: 20)).foregroundStyle(blue)
                }
                .accessibilityLabel("表情")
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
                TextField("消息", text: $draft, axis: .vertical).lineLimit(1...5)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                Button {
                    let text = draft
                    let quote = quoting
                    draft = ""
                    quoting = nil
                    store.drafts[conversationID] = ""
                    UserDefaults.standard.set(store.drafts, forKey: "drafts")
                    Task { await store.sendText(text, to: conversationID, quote: quote) }
                } label: {
                    if store.sendingConversationID == conversationID {
                        ProgressView().frame(width: 34, height: 34)
                    } else {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 34, height: 34).background(blue, in: Circle())
                    }
                }
                .disabled(store.sendingConversationID != nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("发送消息")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            if showEmoji {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(emojis, id: \.self) { emoji in
                            Button { draft += emoji } label: { Text(emoji).font(.system(size: 26)) }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .background(Color(uiColor: .secondarySystemBackground))
            }
        }
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .top) { Divider() }
    }
}

struct MessageRow: View {
    let store: ChatStore
    let conversationID: String
    let message: ChatMessage
    let onQuote: (ChatMessage) -> Void
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playingAudio = false
    @State private var previewImage: UIImage?
    @State private var showPreview = false
    private let blue = Color(red: 0.20, green: 0.55, blue: 0.88)

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.fromBot { Spacer(minLength: 48) }
            VStack(alignment: message.fromBot ? .trailing : .leading, spacing: 4) {
                if !message.fromBot {
                    Text(message.authorName).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                if let quoted = message.quotedText {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5).fill(blue.opacity(0.7)).frame(width: 3)
                        Text(quoted).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
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
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                        statusIcon
                    }.padding(.horizontal, 4)
                }
            }
            if !message.fromBot { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: message.fromBot ? .trailing : .leading)
        .contextMenu {
            if !message.text.isEmpty {
                Button { UIPasteboard.general.string = message.text } label: { Label("复制", systemImage: "doc.on.doc") }
            }
            Button { onQuote(message) } label: { Label("引用", systemImage: "arrowshape.turn.up.left") }
            Button(role: .destructive) {
                store.deleteMessage(conversationID: conversationID, messageID: message.id)
            } label: { Label("删除", systemImage: "trash") }
        }
        .fullScreenCover(isPresented: $showPreview) {
            ZStack {
                Color.black.ignoresSafeArea()
                if let previewImage {
                    Image(uiImage: previewImage).resizable().scaledToFit()
                }
                VStack {
                    HStack {
                        Spacer()
                        Button { showPreview = false } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 28)).foregroundStyle(.white.opacity(0.9))
                        }.padding()
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let name = message.localImage, let image = store.image(named: name) {
            Image(uiImage: image).resizable().scaledToFit()
                .frame(maxWidth: 220, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .onTapGesture { previewImage = image; showPreview = true }
        } else if let name = message.videoFile, let url = store.mediaURL(named: name) {
            VideoPlayer(player: AVPlayer(url: url))
                .frame(width: 240, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        } else if let name = message.audioFile, let url = store.mediaURL(named: name) {
            Button { toggleAudio(url) } label: {
                HStack(spacing: 8) {
                    Image(systemName: playingAudio ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 22))
                    Image(systemName: "waveform").font(.system(size: 16))
                    Text(playingAudio ? "播放中" : "语音消息").font(.system(size: 14))
                }
                .foregroundStyle(message.fromBot ? Color.white : Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(message.fromBot ? blue : Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))
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
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
        } else if message.imageURL != nil || message.videoURL != nil || message.audioURL != nil {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .tertiarySystemBackground))
                VStack(spacing: 6) {
                    ProgressView()
                    Text(message.isVideo ? "视频" : (message.isAudio ? "语音" : "图片")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, height: 160)
        } else {
            VStack(alignment: .trailing, spacing: 3) {
                Text(markdownText(message.text.isEmpty ? "[空消息]" : message.text))
                    .font(.system(size: 16))
                    .foregroundStyle(message.fromBot ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 3) {
                    Text(message.date, format: .dateTime.hour().minute())
                        .font(.system(size: 10))
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

struct SettingsView: View {
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    private let blue = Color(red: 0.20, green: 0.55, blue: 0.88)

    var body: some View {
        NavigationStack {
            List {
                Section("账号") {
                    LabeledContent("AppID", value: store.username.isEmpty ? "未登录" : store.username)
                    LabeledContent("连接状态", value: store.status)
                }
                Section("外观") {
                    Picker("主题", selection: Binding(get: { store.appearance }, set: { store.appearance = $0 })) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.segmented)
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
                Section("说明") {
                    Text("本 App 直接连接 QQ 官方机器人接口。锁屏或长时间后台会暂停连接，重新打开后自动重连。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
            .confirmationDialog("清空全部聊天记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) { store.clearHistory() }
            }
        }
        .tint(blue)
    }
}
