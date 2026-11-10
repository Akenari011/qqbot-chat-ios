import SwiftUI
import Observation
import Security

@main
struct QQBotChatApp: App {
    var body: some Scene { WindowGroup { ConversationView() } }
}

struct ChatMessage: Identifiable, Decodable {
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
private struct IncomingResponse: Decodable { let messages: [ChatMessage] }
private struct SendResponse: Decodable { let messageID: String }
private struct OutgoingMessage: Encodable { let text: String }
private struct LoginInput: Encodable { let username: String; let password: String }
private struct LoginResponse: Decodable { let accessToken: String; enum CodingKeys: String, CodingKey { case accessToken = "access_token" } }

private enum CredentialStore {
    static let service = "org.example.qqbotchat.session"
    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }
    static func save(token: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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
    var gatewayAddress = UserDefaults.standard.string(forKey: "gatewayAddress") ?? ""
    private var baseURL: URL { URL(string: gatewayAddress) ?? URL(string: "https://your-domain.example")! }
    private var pollTask: Task<Void, Never>?
    private var credentials: String?

    init() {
        if let saved = CredentialStore.load() { credentials = saved; authenticated = true }
    }

    func start() {
        guard pollTask == nil, authenticated else { return }
        pollTask = Task { while !Task.isCancelled { await refresh(); try? await Task.sleep(for: .seconds(3)) } }
    }
    func stop() { pollTask?.cancel(); pollTask = nil }

    private func request(path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path)); request.httpMethod = method
        if let token = credentials { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.httpBody = body; return request
    }

    func login() async {
        guard !username.isEmpty, !password.isEmpty, let url = URL(string: gatewayAddress), url.scheme == "https", url.host != nil else { error = "请填写账号密码并使用 HTTPS 网关。"; return }
        loggingIn = true; defer { loggingIn = false }
        do {
            let body = try JSONEncoder().encode(LoginInput(username: username, password: password))
            let (data, response) = try await URLSession.shared.data(for: request(path: "/api/qqbot/login", method: "POST", body: body))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.userAuthenticationRequired) }
            let token = try JSONDecoder().decode(LoginResponse.self, from: data).accessToken
            UserDefaults.standard.set(gatewayAddress, forKey: "gatewayAddress"); credentials = token; CredentialStore.save(token: token); authenticated = true; error = nil; password = ""; start()
        } catch { credentials = nil; self.error = "登录失败，请检查账号、密码和网关地址。" }
    }

    func logout() { stop(); CredentialStore.clear(); credentials = nil; authenticated = false; messages = []; password = "" }

    func refresh() async {
        guard authenticated else { return }
        do { let (data, response) = try await URLSession.shared.data(for: request(path: "/api/qqbot/messages")); if (response as? HTTPURLResponse)?.statusCode == 401 { logout(); error = "登录已过期，请重新登录。"; return }; guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }; messages = try JSONDecoder().decode(IncomingResponse.self, from: data).messages; error = nil }
        catch { self.error = "暂时无法同步消息，请检查网络连接。" }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines); guard authenticated, !text.isEmpty, !sending else { return }
        sending = true; defer { sending = false }
        do { let body = try JSONEncoder().encode(OutgoingMessage(text: text)); let (data, response) = try await URLSession.shared.data(for: request(path: "/api/qqbot/messages", method: "POST", body: body)); guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }; _ = try JSONDecoder().decode(SendResponse.self, from: data); draft = ""; await refresh() }
        catch { self.error = "消息未发送，请检查机器人权限和网络。" }
    }
}

struct ConversationView: View {
    @State private var model = ConversationModel()
    private let blue = Color(red: 0.20, green: 0.55, blue: 0.88)
    var body: some View {
        Group { if model.authenticated { chat } else { login } }.background(Color(uiColor: .systemBackground)).preferredColorScheme(.light).task { model.start() }.onDisappear { model.stop() }
    }
    private var login: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 30)).foregroundStyle(blue).frame(width: 64, height: 64).background(blue.opacity(0.12), in: Circle())
            Text("QQ 机器人聊天").font(.system(size: 22, weight: .semibold))
            TextField("服务器地址（https://）", text: $model.gatewayAddress).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).textFieldStyle(.roundedBorder)
            TextField("聊天账号", text: $model.username).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
            SecureField("密码", text: $model.password).textFieldStyle(.roundedBorder)
            if let error = model.error { Text(error).font(.system(size: 13)).foregroundStyle(.red) }
            Button { Task { await model.login() } } label: { if model.loggingIn { ProgressView().tint(.white) } else { Text("登录").fontWeight(.semibold) } }.frame(maxWidth: .infinity).frame(height: 46).foregroundStyle(.white).background(blue, in: RoundedRectangle(cornerRadius: 10)).disabled(model.loggingIn)
        }.padding(24).frame(maxWidth: 420).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var chat: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 8) { Image(systemName: "info.circle.fill"); Text("由 QQ 官方机器人账号发送") }.font(.system(size: 12, weight: .medium)).foregroundStyle(Color(red: 0.24, green: 0.40, blue: 0.53)).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color(red: 0.89, green: 0.94, blue: 0.98))
            ScrollViewReader { proxy in ScrollView { LazyVStack(spacing: 14) { Text("今天").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 14); ForEach(model.messages) { message in messageRow(message).id(message.id) } }.padding(.horizontal, 12).padding(.bottom, 16) }.background(Color(uiColor: .secondarySystemBackground)).onChange(of: model.messages.last?.id) { _, _ in if let last = model.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } } }
            if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6) }
            composer
        }
    }
    private var header: some View { HStack(spacing: 12) { Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.white).frame(width: 42, height: 42).background(blue.gradient, in: Circle()); VStack(alignment: .leading, spacing: 3) { Text("QQ 机器人").font(.system(size: 16, weight: .semibold)); Text("机器人账号 · 在线").font(.system(size: 12)).foregroundStyle(.secondary) }; Spacer(); Button { model.logout() } label: { Image(systemName: "rectangle.portrait.and.arrow.right").foregroundStyle(blue) }.accessibilityLabel("退出登录") }.padding(14).overlay(alignment: .bottom) { Divider() } }
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
    private var composer: some View { HStack(spacing: 10) { TextField("消息", text: $model.draft, axis: .vertical).lineLimit(1...5).padding(10).background(Color(uiColor: .secondarySystemBackground), in: Capsule()); Button { Task { await model.send() } } label: { Image(systemName: model.sending ? "hourglass" : "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white).frame(width: 36, height: 36).background(blue, in: Circle()) }.disabled(model.sending || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("发送消息") }.padding(12).overlay(alignment: .top) { Divider() } }
}
