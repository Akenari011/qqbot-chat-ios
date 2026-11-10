import SwiftUI
import Observation
import Security
import Foundation

@main
struct QQBotChatApp: App {
    var body: some Scene { WindowGroup { ConversationView() } }
}

struct ChatMessage: Identifiable, Codable {
    let id: String
    let text: String
    let timestamp: String
    let fromBot: Bool
    var authorName: String
    var date: Date { ISO8601DateFormatter().date(from: timestamp) ?? .now }
    enum CodingKeys: String, CodingKey {
        case id = "message_id"
        case text = "content"
        case timestamp
        case fromBot = "from_bot"
        case authorName = "author_name"
    }
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
    static func save(token: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
    static func clear() { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
}

@MainActor @Observable
final class ConversationModel {
    var messages: [ChatMessage] = []
    var draft = ""
    var username = ""
    var password = ""
    var authenticated = false
    var loggingIn = false
    var sending = false
    var error: String?
    var status = "未连接"

    private var token = ""
    private var tokenExpires = Date.distantPast
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var sequence: Int?
    private var lastAck = Date()
    private var target = ""
    private var scene = "c2c"
    private var replyID = ""
    private var replySequence = 0
    private var shouldRun = false
    private var reconnectAttempt = 0

    init() {
        if let saved = CredentialStore.load(), let data = saved.data(using: .utf8), let pair = try? JSONDecoder().decode(LoginInput.self, from: data) {
            username = pair.username
            password = pair.password
        }
    }

    func start() {
        guard !authenticated, !shouldRun, !username.isEmpty, !password.isEmpty else { return }
        Task { await login() }
    }

    func stop() {
        shouldRun = false
        receiver?.cancel()
        heartbeat?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

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

    func login() async {
        guard !username.isEmpty, !password.isEmpty else { error = "请输入 AppID 和 AppSecret"; return }
        stop()
        loggingIn = true
        defer { loggingIn = false }
        shouldRun = true
        do {
            try await refreshToken(force: true)
            try await openSocket()
            authenticated = true
            error = nil
            if let data = try? JSONEncoder().encode(LoginInput(username: username, password: password)),
               let text = String(data: data, encoding: .utf8) {
                CredentialStore.save(token: text)
            }
        } catch {
            authenticated = false
            self.error = "QQ 登录失败，请检查机器人凭证和网络。"
            stop()
        }
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

    private func openSocket() async throws {
        try await refreshToken()
        let gateway = try await api("/gateway/bot")
        guard let address = gateway["url"] as? String, let url = URL(string: address), url.scheme == "wss" else { throw URLError(.badURL) }
        let ws = URLSession.shared.webSocketTask(with: url)
        socket = ws
        ws.resume()
        status = "连接中"
        receiver = Task { await receive() }
    }

    private func receive() async {
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
                    try await packet(["op": 2, "d": ["token": "QQBot " + token, "intents": (1 << 25) | (1 << 30), "shard": [0, 1], "properties": [:]]])
                    startHeartbeat(interval: interval)
                } else if op == 11 {
                    lastAck = Date()
                } else if op == 7 || op == 9 {
                    throw URLError(.networkConnectionLost)
                }
                if event["t"] as? String == "READY" {
                    reconnectAttempt = 0
                    status = "QQ 已连接，等待消息"
                }
                if let kind = event["t"] as? String, ["C2C_MESSAGE_CREATE", "GROUP_AT_MESSAGE_CREATE", "GROUP_MESSAGE_CREATE"].contains(kind) {
                    let author = payload["author"] as? [String: Any] ?? [:]
                    let nextTarget = payload["group_openid"] as? String ?? author["user_openid"] as? String ?? ""
                    guard !nextTarget.isEmpty, let id = payload["id"] as? String else { continue }
                    if target != nextTarget {
                        target = nextTarget
                        loadHistory()
                    }
                    scene = kind == "C2C_MESSAGE_CREATE" ? "c2c" : "group"
                    replyID = id
                    replySequence = 0
                    status = "QQ 已连接"
                    if !messages.contains(where: { $0.id == id }) {
                        messages.append(ChatMessage(id: id, text: payload["content"] as? String ?? "[非文字消息]", timestamp: payload["timestamp"] as? String ?? ISO8601DateFormatter().string(from: .now), fromBot: false, authorName: author["username"] as? String ?? "QQ 用户"))
                        saveHistory()
                    }
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
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard self.shouldRun else { return }
            do {
                try await self.openSocket()
            } catch {
                self.scheduleReconnect()
            }
        }
    }

    private func loadHistory() {
        guard !target.isEmpty, let data = UserDefaults.standard.data(forKey: "history." + target),
              let saved = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
            messages = []
            return
        }
        messages = saved
    }

    private func saveHistory() {
        guard !target.isEmpty, let data = try? JSONEncoder().encode(Array(messages.suffix(200))) else { return }
        UserDefaults.standard.set(data, forKey: "history." + target)
    }

    func logout() {
        stop()
        authenticated = false
        token = ""
        target = ""
        replyID = ""
        messages = []
    }

    func send() async {
        guard !target.isEmpty, !replyID.isEmpty else { error = "请先从 QQ 给机器人发送消息，再在这里回复。"; return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        replySequence += 1
        let destination = target
        let context = replyID
        let kind = scene
        let sequenceNumber = replySequence
        do {
            let encoded = destination.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? destination
            let path = kind == "c2c" ? "/v2/users/" : "/v2/groups/"
            let result = try await api(path + encoded + "/messages", body: ["content": text, "msg_type": 0, "msg_id": context, "msg_seq": sequenceNumber])
            guard let id = result["id"] as? String else { throw URLError(.badServerResponse) }
            if target == destination {
                messages.append(ChatMessage(id: id, text: text, timestamp: ISO8601DateFormatter().string(from: .now), fromBot: true, authorName: "QQ 机器人"))
                saveHistory()
            }
            draft = ""
            error = nil
        } catch {
            self.error = "发送失败，请检查回复时限、机器人权限和连接。"
        }
    }
}

struct ConversationView: View {
    @State private var model = ConversationModel()
    private let blue = Color(red: 0.20, green: 0.55, blue: 0.88)
    var body: some View {
        Group { if model.authenticated { chat } else { login } }
            .background(Color(uiColor: .systemBackground))
            .preferredColorScheme(.light)
            .task { model.start() }
            .onDisappear { model.stop() }
    }

    private var login: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 30)).foregroundStyle(blue).frame(width: 64, height: 64).background(blue.opacity(0.12), in: Circle())
            Text("QQ 机器人聊天").font(.system(size: 22, weight: .semibold))
            TextField("QQ 机器人 AppID", text: $model.username).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
            SecureField("QQ 机器人 AppSecret", text: $model.password).textFieldStyle(.roundedBorder)
            if let error = model.error { Text(error).font(.system(size: 13)).foregroundStyle(.red) }
            Button { Task { await model.login() } } label: {
                if model.loggingIn { ProgressView().tint(.white) } else { Text("登录").fontWeight(.semibold) }
            }
            .frame(maxWidth: .infinity).frame(height: 46)
            .foregroundStyle(.white).background(blue, in: RoundedRectangle(cornerRadius: 10))
            .disabled(model.loggingIn)
        }.padding(24).frame(maxWidth: 420).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chat: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                Text("由 QQ 官方机器人账号发送")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(red: 0.24, green: 0.40, blue: 0.53))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(red: 0.89, green: 0.94, blue: 0.98))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        Text("今天").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 14)
                        ForEach(model.messages) { message in messageRow(message).id(message.id) }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 16)
                }
                .background(Color(uiColor: .secondarySystemBackground))
                .onChange(of: model.messages.last?.id) { _, _ in
                    if let last = model.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 6)
            }
            composer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.white).frame(width: 42, height: 42).background(blue.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("QQ 机器人").font(.system(size: 16, weight: .semibold))
                Text(model.status).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.logout() } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right").foregroundStyle(blue)
            }.accessibilityLabel("退出登录")
        }.padding(14).overlay(alignment: .bottom) { Divider() }
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        HStack(alignment: .bottom, spacing: 7) {
            if message.fromBot { Spacer(minLength: 42) }
            VStack(alignment: message.fromBot ? .trailing : .leading, spacing: 4) {
                Text(message.fromBot ? "我 · QQ 机器人" : (message.authorName.isEmpty ? "QQ 用户" : message.authorName))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(message.text)
                    .font(.system(size: 16))
                    .foregroundStyle(message.fromBot ? Color.white : Color.primary)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(message.fromBot ? blue : Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))
                Text(message.date, format: .dateTime.hour().minute())
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if !message.fromBot { Spacer(minLength: 42) }
        }.frame(maxWidth: .infinity, alignment: message.fromBot ? .trailing : .leading)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("消息", text: $model.draft, axis: .vertical).lineLimit(1...5)
                .padding(10).background(Color(uiColor: .secondarySystemBackground), in: Capsule())
            Button { Task { await model.send() } } label: {
                Image(systemName: model.sending ? "hourglass" : "arrow.up")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(blue, in: Circle())
            }
            .disabled(model.sending || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("发送消息")
        }.padding(12).overlay(alignment: .top) { Divider() }
    }
}
