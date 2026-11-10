import SwiftUI
import Observation
import Security
import PhotosUI
import Network
import UIKit

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

    init(id: String, text: String, timestamp: String, fromBot: Bool, authorName: String, imageURL: String? = nil, localImage: String? = nil) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.fromBot = fromBot
        self.authorName = authorName
        self.imageURL = imageURL
        self.localImage = localImage
    }

    var isImage: Bool { imageURL != nil || localImage != nil }
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
                        try await packet(["op": 2, "d": ["token": "QQBot " + token, "intents": (1 << 25) | (1 << 30), "shard": [0, 1], "properties": [:]]])
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
        let remote = attachments.first?["url"] as? String
        let timestamp = payload["timestamp"] as? String ?? ISO8601DateFormatter().string(from: .now)
        let message = ChatMessage(id: id, text: content, timestamp: timestamp, fromBot: false, authorName: name, imageURL: remote)
        append(message, target: target, scene: isGroup ? "group" : "c2c", name: name, markUnread: activeConversationID != target, replyID: id)
        if let remote { downloadImage(remote, target: target, messageID: id) }
    }

    private func append(_ message: ChatMessage, target: String, scene: String, name: String, markUnread: Bool, replyID: String?) {
        if let index = conversations.firstIndex(where: { $0.id == target }) {
            if conversations[index].messages.contains(where: { $0.id == message.id }) { return }
            conversations[index].messages.append(message)
            conversations[index].lastText = message.isImage ? "[图片]" : message.text
            conversations[index].lastTimestamp = message.timestamp
            conversations[index].name = name
            if let replyID { conversations[index].replyID = replyID }
            if markUnread { conversations[index].unread += 1 }
            let updated = conversations.remove(at: index)
            conversations.insert(updated, at: 0)
        } else {
            let conversation = Conversation(id: target, scene: scene, name: name, lastText: message.isImage ? "[图片]" : message.text, lastTimestamp: message.timestamp, unread: markUnread ? 1 : 0, messages: [message], replyID: replyID ?? "", replySeq: 0)
            conversations.insert(conversation, at: 0)
        }
        saveConversations()
    }

    func markRead(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }), conversations[index].unread != 0 else { return }
        conversations[index].unread = 0
        saveConversations()
    }

    // MARK: - Images

    private func downloadImage(_ urlString: String, target: String, messageID: String) {
        Task {
            guard let url = URL(string: urlString) else { return }
            var request = URLRequest(url: url)
            if !self.token.isEmpty { request.setValue("QQBot " + self.token, forHTTPHeaderField: "Authorization") }
            guard let (data, _) = try? await URLSession.shared.data(for: request), !data.isEmpty,
                  let name = self.saveImage(data) else { return }
            self.attachLocalImage(name, target: target, messageID: messageID)
        }
    }

    private func attachLocalImage(_ name: String, target: String, messageID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == target }),
              let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == messageID }) else { return }
        conversations[index].messages[messageIndex].localImage = name
        conversations[index].messages[messageIndex].imageURL = nil
        saveConversations()
    }

    func saveImage(_ data: Data) -> String? {
        let name = UUID().uuidString + ".jpg"
        do {
            try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
            try data.write(to: imagesURL.appendingPathComponent(name), options: .atomic)
            return name
        } catch { return nil }
    }

    func image(named name: String?) -> UIImage? {
        guard let name else { return nil }
        return UIImage(contentsOfFile: imagesURL.appendingPathComponent(name).path)
    }

    // MARK: - Sending

    func sendText(_ text: String, to id: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await send(to: id, text: trimmed, imageFile: nil)
    }

    func sendImage(_ data: Data, to id: String) async {
        guard let image = UIImage(data: data) else { error = "无法读取所选图片。"; return }
        let resized = image.scaled(maxDimension: 1600)
        guard let jpeg = resized.jpegData(compressionQuality: 0.82) else { error = "图片压缩失败。"; return }
        guard let name = saveImage(jpeg) else { error = "图片保存失败。"; return }
        await send(to: id, text: "", imageFile: name)
    }

    private func send(to id: String, text: String, imageFile: String?) async {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        guard !conversations[index].replyID.isEmpty else { error = "请先从 QQ 给机器人发送一条消息，再回复。"; return }
        guard sendingConversationID == nil else { return }
        sendingConversationID = id
        defer { sendingConversationID = nil; error = nil }
        let conversation = conversations[index]
        var body: [String: Any] = ["msg_id": conversation.replyID, "msg_seq": conversation.replySeq + 1]
        if let imageFile {
            guard let data = try? Data(contentsOf: imagesURL.appendingPathComponent(imageFile)) else { error = "图片读取失败。"; return }
            do {
                let info = try await uploadImage(data, target: id, scene: conversation.scene)
                body["msg_type"] = 7
                body["content"] = ""
                body["media"] = ["file_info": info]
            } catch {
                self.error = "图片上传失败，请确认图片小于 10MB 且机器人有富媒体权限。"
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
            if let current = conversations.firstIndex(where: { $0.id == id }) {
                let message = ChatMessage(id: messageID, text: text, timestamp: ISO8601DateFormatter().string(from: .now), fromBot: true, authorName: "QQ 机器人", localImage: imageFile)
                conversations[current].messages.append(message)
                conversations[current].lastText = imageFile == nil ? text : "[图片]"
                conversations[current].lastTimestamp = message.timestamp
                conversations[current].replySeq += 1
                saveConversations()
            }
        } catch {
            self.error = "发送失败，请检查回复时限、机器人权限和连接。"
        }
    }

    private func uploadImage(_ data: Data, target: String, scene: String) async throws -> String {
        let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target
        let path = scene == "c2c" ? "/v2/users/" : "/v2/groups/"
        let result = try await api(path + encoded + "/files", body: [
            "file_type": 1,
            "file_data": data.base64EncodedString(),
            "file_name": "image.jpg",
            "srv_send_msg": false
        ])
        guard let info = result["file_info"] as? String, !info.isEmpty else { throw URLError(.badServerResponse) }
        return info
    }

    // MARK: - Persistence

    private func loadConversations() {
        guard let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode([Conversation].self, from: data) else { return }
        conversations = saved.sorted { $0.lastDate > $1.lastDate }
    }

    private func saveConversations() {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        try? data.write(to: stateURL, options: .atomic)
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
        .preferredColorScheme(.light)
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
    private let blue = Color(red: 0.20, green: 0.55, blue: 0.88)

    var body: some View {
        NavigationStack {
            Group {
                if store.conversations.isEmpty {
                    ContentUnavailableView {
                        Label("还没有会话", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("从 QQ 给机器人发送一条消息后，会话会出现在这里。")
                    }
                } else {
                    List {
                        ForEach(store.conversations) { conversation in
                            NavigationLink(value: conversation.id) {
                                ConversationRow(conversation: conversation)
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("QQ 机器人")
            .navigationBarTitleDisplayMode(.inline)
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: conversation.isGroup ? "person.2.fill" : "person.fill")
                .font(.system(size: 18)).foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(conversation.isGroup ? Color.orange.gradient : blue.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
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
                            ForEach(conversation.messages) { message in
                                MessageRow(store: store, message: message).id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 12)
                }
                .background(Color(uiColor: .secondarySystemBackground))
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
        }
        .onDisappear { store.activeConversationID = nil }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await store.sendImage(data, to: conversationID)
                }
                pickerItem = nil
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Image(systemName: "photo.on.rectangle").font(.system(size: 20)).foregroundStyle(blue)
            }
            .accessibilityLabel("发送图片")
            TextField("消息", text: $draft, axis: .vertical).lineLimit(1...5)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
            Button {
                let text = draft
                draft = ""
                Task { await store.sendText(text, to: conversationID) }
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
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .top) { Divider() }
    }
}

struct MessageRow: View {
    let store: ChatStore
    let message: ChatMessage
    private let blue = Color(red: 0.20, green: 0.55, blue: 0.88)

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.fromBot { Spacer(minLength: 48) }
            VStack(alignment: message.fromBot ? .trailing : .leading, spacing: 4) {
                if !message.fromBot {
                    Text(message.authorName).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                content
                Text(message.date, format: .dateTime.hour().minute())
                    .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 4)
            }
            if !message.fromBot { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: message.fromBot ? .trailing : .leading)
    }

    @ViewBuilder
    private var content: some View {
        if let name = message.localImage, let image = store.image(named: name) {
            Image(uiImage: image).resizable().scaledToFit()
                .frame(maxWidth: 220, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        } else if message.imageURL != nil {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .tertiarySystemBackground))
                ProgressView()
            }
            .frame(width: 160, height: 160)
        } else {
            Text(message.text.isEmpty ? "[空消息]" : message.text)
                .font(.system(size: 16))
                .foregroundStyle(message.fromBot ? Color.white : Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(message.fromBot ? blue : Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))
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
