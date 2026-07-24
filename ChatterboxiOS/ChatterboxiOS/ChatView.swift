import SwiftUI

// MARK: - Chat item model (message or date separator)

private enum ChatItem: Identifiable {
    case message(FfiMessage)
    case dateSeparator(Date)

    var id: String {
        switch self {
        case .message(let m):      return m.id
        case .dateSeparator(let d): return "sep-\(Int(d.timeIntervalSince1970))"
        }
    }
}

// MARK: - ChatView

struct ChatView: View {
    let jid: String
    @EnvironmentObject private var state: AppState
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private var messages: [FfiMessage] { state.conversations[jid] ?? [] }

    private var chatItems: [ChatItem] {
        var items: [ChatItem] = []
        var lastDay: Date?
        let cal = Calendar.current
        for msg in messages {
            let date = Date(timeIntervalSince1970: Double(msg.timestamp))
            if let prev = lastDay, !cal.isDate(date, inSameDayAs: prev) {
                items.append(.dateSeparator(date))
            } else if lastDay == nil {
                items.append(.dateSeparator(date))
            }
            lastDay = date
            items.append(.message(msg))
        }
        return items
    }

    private var contactName: String {
        if let name = state.contacts[jid]?.displayName, !name.isEmpty { return name }
        return jid.components(separatedBy: "@").first ?? jid
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            composer
        }
        .navigationTitle(contactName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: "info:\(jid)") {
                    Image(systemName: "info.circle")
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.typing.contains(jid) {
                HStack(spacing: 4) {
                    ProgressView().scaleEffect(0.7)
                    Text("\(contactName) is typing…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 4)
                .background(.bar)
            }
        }
        .onAppear { state.markRead(jid) }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if messages.isEmpty {
                    ContentUnavailableView(
                        "No Messages",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Send a message to start the conversation.")
                    )
                    .padding(.top, 60)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(chatItems) { item in
                            switch item {
                            case .dateSeparator(let date):
                                Text(date, format: .dateTime.day().month().year())
                                    .font(.caption).foregroundStyle(.secondary)
                                    .padding(.vertical, 8)
                            case .message(let msg):
                                let ownBare  = state.ownJid.components(separatedBy: "/").first ?? state.ownJid
                                let fromBare = msg.fromJid.components(separatedBy: "/").first  ?? msg.fromJid
                                MessageBubble(msg: msg, isOwn: fromBare == ownBare || fromBare == "me")
                                    .id(msg.id)
                                    .contextMenu {
                                        Button {
                                            UIPasteboard.general.string = msg.body
                                        } label: {
                                            Label("Copy", systemImage: "doc.on.doc")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            state.deleteMessage(id: msg.id, partner: jid)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
            .onAppear { scrollToBottom(proxy: proxy, animated: false) }
            .onChange(of: messages.count) { scrollToBottom(proxy: proxy, animated: true) }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard let last = messages.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 20)
                )
                .onChange(of: draft) { _, new in
                    state.sendTyping(to: jid, isTyping: !new.isEmpty)
                }

            Button { send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .resizable()
                    .frame(width: 34, height: 34)
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? .gray : .blue)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""
        Task { await state.sendMessage(to: jid, body: body) }
    }
}

// MARK: - Bubble

private struct MessageBubble: View {
    let msg: FfiMessage
    let isOwn: Bool

    var body: some View {
        HStack(alignment: .bottom) {
            if isOwn { Spacer(minLength: 64) }
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 3) {
                Text(linkedBody)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        isOwn ? Color.blue : Color(.secondarySystemBackground),
                        in: BubbleShape(isOwn: isOwn)
                    )
                    .foregroundStyle(isOwn ? .white : .primary)
                    .textSelection(.enabled)
                    .tint(isOwn ? .white : .accentColor)

                HStack(spacing: 3) {
                    if msg.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                    }
                    Text(
                        Date(timeIntervalSince1970: Double(msg.timestamp)),
                        format: .dateTime.hour().minute()
                    )
                    .font(.system(size: 10))
                    if isOwn {
                        Image(systemName: statusIcon)
                            .font(.system(size: 10))
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
            if !isOwn { Spacer(minLength: 64) }
        }
        .padding(.horizontal, 8)
    }

    /// Build an AttributedString with any http/https URLs turned into tappable links.
    private var linkedBody: AttributedString {
        var attributed = AttributedString(msg.body)
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return attributed }

        let plain = msg.body
        let matches = detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
        for match in matches {
            guard let nsRange = Range(match.range, in: plain),
                  let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let attrRange = Range<AttributedString.Index>(nsRange, in: attributed)
            else { continue }
            attributed[attrRange].link = url
            attributed[attrRange].underlineStyle = .single
        }
        return attributed
    }

    private var statusIcon: String {
        switch msg.status {
        case "delivered": return "checkmark.circle"
        case "read":      return "checkmark.circle.fill"
        case "failed":    return "exclamationmark.circle"
        default:          return "clock"      // "sent" — awaiting delivery
        }
    }
}

// MARK: - Bubble shape

private struct BubbleShape: Shape {
    let isOwn: Bool
    private let radius: CGFloat = 18
    private let tailWidth: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var r = rect
        if isOwn {
            r.size.width -= tailWidth
        } else {
            r.origin.x += tailWidth
            r.size.width -= tailWidth
        }
        var path = Path()
        path.addRoundedRect(in: r, cornerSize: CGSize(width: radius, height: radius))
        return path
    }
}
