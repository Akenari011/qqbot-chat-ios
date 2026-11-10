import SwiftUI
import Observation

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

@MainActor @Observable
final class ConversationModel {
    var messages: [ChatMessage] = []
    var draft = ""
    var sending = false
    var error: String?
    private let baseURL = URL(string: ProcessInfo.processInfo.environment["QQBOT_GATEWAY_URL"] ?? "https://your-domain.example")!
    private let gatewayKey = ProcessInfo.processInfo.environment["QQBOT_GATEWAY_KEY"] ?? ""
    private var pollTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    private func request(path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(gatewayKey)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.httpBody = body
        return request
    }

    func refresh() async {
        guard !gatewayKey.isEmpty else { error = "请配置网关登录信息。"; return }
        do {
            let (data, response) = try await URLSession.shared.data(for: request(path: "/api/qqbot/messages"))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            messages = try JSONDecoder().decode(IncomingResponse.self, from: data).messages
            error = nil
        } catch { self.error = "暂时无法同步消息，请检查网络连接。" }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        guard !gatewayKey.isEmpty else { error = "请配置网关登录信息。"; return }
        sending = true; defer { sending = false }
        do {
            let body = try JSONEncoder().encode(OutgoingMessage(text: text))
            let (data, response) = try await URLSession.shared.data(for: request(path: "/api/qqbot/messages", method: "POST", body: body))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            _ = try JSONDecoder().decode(SendResponse.self, from: data)
            draft = ""
            await refresh()
        } catch { self.error = "消息未发送，请检查机器人权限和网络。" }
    }
}

struct ConversationView: View {
    @State private var model = ConversationModel()
    private let blue = Color(red: 0.20, green: 0.55, blue: 0.88)

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 8) { Image(systemName: "info.circle.fill"); Text("由 QQ 官方机器人账号发送") }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Color(red: 0.24, green: 0.40, blue: 0.53))
                .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color(red: 0.89, green: 0.94, blue: 0.98))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        Text("今天").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 14)
                        ForEach(model.messages) { message in messageRow(message).id(message.id) }
                    }.padding(.horizontal, 12).padding(.bottom, 16)
                }.background(Color(uiColor: .secondarySystemBackground))
                 .onChange(of: model.messages.count) { _, _ in if let last = model.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }
            if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6) }
            composer
        }.background(Color(uiColor: .systemBackground)).preferredColorScheme(.light)
         .task { model.start() }.onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.left").foregroundStyle(blue)
            Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.white).frame(width: 42, height: 42).background(blue.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 3) { Text("QQ 机器人").font(.system(size: 16, weight: .semibold)); Text("机器人账号 · 在线").font(.system(size: 12)).foregroundStyle(.secondary) }
            Spacer(); Image(systemName: "ellipsis").foregroundStyle(blue)
        }.padding(14).overlay(alignment: .bottom) { Divider() }
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        HStack(alignment: .bottom, spacing: 7) {
            if message.fromBot { avatar } else { Spacer(minLength: 42) }
            VStack(alignment: message.fromBot ? .leading : .trailing, spacing: 4) {
                Text(message.fromBot ? "QQ 机器人" : message.authorName).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
                Text(message.text).font(.system(size: 16)).foregroundStyle(message.fromBot ? Color.primary : Color.white).padding(.horizontal, 12).padding(.vertical, 9).background(message.fromBot ? Color(uiColor: .systemBackground) : blue, in: RoundedRectangle(cornerRadius: 16))
                Text(message.date, format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 4)
            }
            if message.fromBot { Spacer(minLength: 42) }
        }.frame(maxWidth: .infinity, alignment: message.fromBot ? .leading : .trailing)
    }

    private var avatar: some View {
        Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 12)).foregroundStyle(.white).frame(width: 30, height: 30).background(blue.gradient, in: Circle())
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("消息", text: $model.draft, axis: .vertical).lineLimit(1...5).padding(10).background(Color(uiColor: .secondarySystemBackground), in: Capsule())
            Button { Task { await model.send() } } label: { Image(systemName: model.sending ? "hourglass" : "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white).frame(width: 36, height: 36).background(blue, in: Circle()) }.disabled(model.sending || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("发送消息")
        }.padding(12).overlay(alignment: .top) { Divider() }
    }
}
