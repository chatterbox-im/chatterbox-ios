import Combine
import SwiftUI

@MainActor
class AppState: ObservableObject {
    let client = ChatterboxClient()

    // MARK: - Connection
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var isReconnecting = false
    @Published var connectionError: String?

    /// Own bare JID (no resource), e.g. "alice@example.com".
    private(set) var ownJid = ""

    // Kept in memory so reconnection doesn't need another Keychain read on every retry
    private var savedServer = ""
    private var savedPassword = ""
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    // MARK: - Roster
    @Published var contacts: [String: FfiContact] = [:]

    // MARK: - Conversations
    /// Messages keyed by the partner's bare JID.
    @Published var conversations: [String: [FfiMessage]] = [:]
    /// Unread counts keyed by partner JID.
    @Published var unread: [String: Int] = [:]
    /// JIDs currently composing a message.
    @Published var typing: Set<String> = []

    // MARK: - Connect

    func connect(server: String, username: String, password: String) async {
        isConnecting = true
        connectionError = nil
        do {
            try await client.connect(server: server, username: username, password: password)

            // Bare JID — strip resource if present
            let bare = (username.contains("@") ? username : "\(username)@\(server)")
                .components(separatedBy: "/").first ?? username
            ownJid = bare

            isConnected = true
            isReconnecting = false
            reconnectAttempt = 0
            savedServer = server
            savedPassword = password

            // Persist credentials on success
            CredentialStore.shared.server   = server
            CredentialStore.shared.username = username
            CredentialStore.shared.savePassword(password)

            // Ask for notification permission (needed for background refresh alerts)
            requestNotificationPermission()

            // Restore history from local SQLite before the event loop starts
            await loadStoredHistory()
            // MAM catch-up: fetch any messages that arrived while the app was closed
            await catchUpMAM()

            // Refresh roster
            if let fetched = try? await client.getContacts() {
                for c in fetched { contacts[c.jid] = c }
            }

            startEventLoop()
        } catch {
            connectionError = error.localizedDescription
        }
        isConnecting = false
    }

    // MARK: - Send

    func sendMessage(to jid: String, body: String) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let msg = try await client.sendMessage(toJid: jid, body: trimmed)
            append(msg, partner: jid)
        } catch {
            let failed = FfiMessage(
                id: UUID().uuidString,
                fromJid: ownJid,
                toJid: jid,
                body: trimmed,
                timestamp: Int64(Date().timeIntervalSince1970),
                isEncrypted: true,
                status: "failed"
            )
            append(failed, partner: jid)
        }
    }

    func markRead(_ jid: String) {
        unread[jid] = 0
    }

    func sendTyping(to jid: String, isTyping: Bool) {
        Task { try? await client.sendTyping(jid: jid, isTyping: isTyping) }
    }

    func deleteConversation(jid: String) {
        conversations.removeValue(forKey: jid)
        unread.removeValue(forKey: jid)
        typing.remove(jid)
        Task { try? await client.deleteConversation(jid: jid) }
    }

    func deleteMessage(id: String, partner: String) {
        conversations[partner]?.removeAll { $0.id == id }
    }

    // MARK: - Sign out

    func signOut() async {
        // Cancel any pending reconnect before disconnecting
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        isReconnecting = false

        await client.disconnect()
        CredentialStore.shared.clearAll()

        isConnected = false
        conversations = [:]
        contacts = [:]
        unread = [:]
        typing = []
        ownJid = ""
        savedServer = ""
        savedPassword = ""
        connectionError = nil
    }

    // MARK: - Derived

    /// Conversations sorted newest-first, only those with at least one message.
    var sortedConversations: [(jid: String, lastMessage: FfiMessage)] {
        conversations.compactMap { jid, msgs in
            msgs.last.map { (jid: jid, lastMessage: $0) }
        }
        .sorted { $0.lastMessage.timestamp > $1.lastMessage.timestamp }
    }

    // MARK: - Private: history restore

    private func loadStoredHistory() async {
        guard let jids = try? await client.listConversations() else { return }
        for jid in jids {
            guard jid != "me", jid != "unknown", jid != "system",
                  !jid.isEmpty, jid.contains("@") else { continue }
            guard let msgs = try? await client.loadHistory(jid: jid, limit: 100) else { continue }
            conversations[jid] = msgs
        }
    }

    /// Fetch server archive (MAM) for every known conversation to catch up on
    /// messages that arrived while the app was closed or offline.
    private func catchUpMAM() async {
        let jids = Array(conversations.keys)
        await withTaskGroup(of: Void.self) { group in
            for jid in jids {
                group.addTask { [weak self] in
                    guard let self else { return }
                    // Use the timestamp of the newest locally stored message as the start point.
                    // Add 1 second so the MAM query is exclusive — avoids re-fetching the last
                    // message whose OMEMO ratchet state has already been advanced.
                    let since: Int64
                    let knownIds: Set<String>
                    if let last = await self.conversations[jid]?.last {
                        since = last.timestamp + 1
                        knownIds = Set(await self.conversations[jid]!.map { $0.id })
                    } else {
                        since = Int64(Date().timeIntervalSince1970) - 7 * 86400
                        knownIds = []
                    }
                    guard let newMsgs = try? await self.client.fetchMam(jid: jid, sinceUnixSecs: since) else { return }
                    await MainActor.run {
                        // Filter out IDs already in memory (belt-and-suspenders dedup)
                        for msg in newMsgs where !knownIds.contains(msg.id) {
                            self.append(msg, partner: jid)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Private: event loop

    private func startEventLoop() {
        Task {
            while let event = await client.nextEvent() {
                handle(event)
            }
            // Event loop exited — connection dropped
            isConnected = false
            scheduleReconnect()
        }
    }

    private func handle(_ event: FfiEvent) {
        switch event {
        case .message(let msg):
            let partner = partnerJid(for: msg)
            guard partner != "me", partner != "unknown", partner.contains("@") else { return }
            let isNew = append(msg, partner: partner)
            if isNew { unread[partner, default: 0] += 1 }
        case .statusUpdate(let msgId, let status):
            for jid in conversations.keys {
                if let idx = conversations[jid]!.firstIndex(where: { $0.id == msgId }) {
                    let old = conversations[jid]![idx]
                    conversations[jid]![idx] = FfiMessage(
                        id: old.id, fromJid: old.fromJid, toJid: old.toJid,
                        body: old.body, timestamp: old.timestamp,
                        isEncrypted: old.isEncrypted, status: status
                    )
                    break
                }
            }
        case .typingUpdate(let jid, let isTyping):
            let bare = jid.components(separatedBy: "/").first ?? jid
            if isTyping { typing.insert(bare) } else { typing.remove(bare) }
        case .contactUpdate(let contact):
            contacts[contact.jid] = contact
        case .disconnected:
            isConnected = false
            scheduleReconnect()
        }
    }

    // MARK: - Private: reconnection

    private func scheduleReconnect() {
        // Don't retry if signed out or no saved credentials
        guard !savedServer.isEmpty,
              let pw = CredentialStore.shared.loadPassword(),
              !pw.isEmpty else { return }

        reconnectTask?.cancel()
        reconnectAttempt += 1
        // Exponential backoff: 2s, 4s, 8s, 16s, 30s (capped)
        let delay = min(pow(2.0, Double(reconnectAttempt)), 30.0)
        isReconnecting = true

        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, !isConnected else {
                isReconnecting = false
                return
            }
            await connect(
                server: savedServer,
                username: CredentialStore.shared.username,
                password: pw
            )
        }
    }

    // MARK: - Private: routing

    private func partnerJid(for msg: FfiMessage) -> String {
        let fromBare = msg.fromJid.components(separatedBy: "/").first ?? msg.fromJid
        let toBare   = msg.toJid.components(separatedBy: "/").first   ?? msg.toJid
        let ownBare  = ownJid.components(separatedBy: "/").first      ?? ownJid

        let isOwn = fromBare == ownBare || fromBare == "me"
        return isOwn ? toBare : fromBare
    }

    @discardableResult
    private func append(_ msg: FfiMessage, partner: String) -> Bool {
        if conversations[partner, default: []].contains(where: { $0.id == msg.id }) {
            return false
        }
        conversations[partner, default: []].append(msg)
        return true
    }
}
