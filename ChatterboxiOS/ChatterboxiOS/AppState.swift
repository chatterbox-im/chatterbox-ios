import Combine
import SwiftUI

@MainActor
class AppState: ObservableObject {
    let client = ChatterboxClient()
    @EnvironmentObject private var toasts: ToastStore

    // MARK: - Connection
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var isReconnecting = false
    @Published var connectionError: String?

    /// Own bare JID (no resource), e.g. "alice@example.com".
    private(set) var ownJid = ""

    // Saved after a successful connection and cleared on sign-out.
    private var savedServer = ""
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var eventLoopTask: Task<Void, Never>?
    /// Incremented whenever a connection attempt or intentional disconnect
    /// supersedes earlier work.  Events from an old connection are ignored.
    private var connectionGeneration = 0
    /// Backgrounding and signing out are intentional disconnects: neither may
    /// result in an automatic reconnect.
    private var reconnectEnabled = false
    /// A foreground transition that happened while a native connect call was
    /// still draining.  Starting a second connection before it exits can make
    /// the stale call disconnect the new one.
    private var resumePending = false

    // MARK: - Roster
    @Published var contacts: [String: FfiContact] = [:]

    // MARK: - Conversations
    /// Messages keyed by the partner's bare JID.
    @Published var conversations: [String: [FfiMessage]] = [:]
    /// Unread counts keyed by partner JID.
    @Published var unread: [String: Int] = [:]
    /// JIDs currently composing a message.
    @Published var typing: Set<String> = []
    /// Error reason for messages in "failed" state, keyed by optimistic message ID.
    /// In-memory only — cleared when a message is retried or deleted.
    @Published private(set) var messageErrors: [String: String] = [:]

    // MARK: - Connect

    func connect(server: String, username: String, password: String) async {
        guard !isConnecting else { return }
        reconnectEnabled = true
        connectionGeneration &+= 1
        let generation = connectionGeneration
        isConnecting = true
        connectionError = nil
        do {
            try await client.connect(server: server, username: username, password: password)

            // The app may have been backgrounded or signed out while the
            // native connection attempt was in flight.  Do not revive it.
            guard reconnectEnabled, generation == connectionGeneration else {
                await client.disconnect()
                isConnecting = false
                if resumePending {
                    resumeIfNeeded()
                }
                return
            }

            // Bare JID — strip resource if present
            let bare = (username.contains("@") ? username : "\(username)@\(server)")
                .components(separatedBy: "/").first ?? username
            ownJid = bare

            isConnected = true
            isReconnecting = false
            reconnectAttempt = 0
            resumePending = false
            savedServer = server

            // Persist credentials on success
            CredentialStore.shared.server   = server
            CredentialStore.shared.username = username
            do {
                try CredentialStore.shared.savePassword(password)
            } catch {
                toasts.error("Failed to save password: \(error.localizedDescription)")
            }

            // Ask for notification permission (needed for background refresh alerts)
            requestNotificationPermission()

            // Restore history from local SQLite before the event loop starts
            await loadStoredHistory()
            // MAM catch-up: fetch any messages that arrived while the app was closed
            await catchUpMAM()

            // Refresh roster
            do {
                let fetched = try await client.getContacts()
                for c in fetched { contacts[c.jid] = c }
            } catch {
                toasts.error("Failed to load contacts: \(userMessage(from: error))")
            }

            startEventLoop(generation: generation)
        } catch {
            guard generation == connectionGeneration else {
                finishSupersededConnect()
                return
            }
            connectionError = userMessage(from: error)
            // After 3 failed reconnect attempts surface a toast — the bottom bar
            // "Reconnecting…" indicator is easy to miss when the user is in a chat.
            if reconnectAttempt >= 2 && !savedServer.isEmpty {
                toasts.warning("Still unable to connect: \(userMessage(from: error))")
            }
            // A reconnect failure should keep using bounded backoff.  A first
            // sign-in has no saved credentials, so this is a no-op for bad
            // manual credentials.
            scheduleReconnect()
        }
        if generation == connectionGeneration {
            isConnecting = false
        }
    }

    private func finishSupersededConnect() {
        isConnecting = false
        if resumePending {
            resumeIfNeeded()
        }
    }

    // MARK: - Send

    func sendMessage(to jid: String, body: String) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let optimisticId = UUID().uuidString
        let optimistic = FfiMessage(
            id: optimisticId,
            fromJid: ownJid,
            toJid: jid,
            body: trimmed,
            timestamp: Int64(Date().timeIntervalSince1970),
            isEncrypted: true,
            status: "sending"
        )
        append(optimistic, partner: jid)

        do {
            let msg = try await client.sendMessage(toJid: jid, body: trimmed)
            if let idx = conversations[jid]?.firstIndex(where: { $0.id == optimisticId }) {
                conversations[jid]?.remove(at: idx)
            }
            append(msg, partner: jid)
        } catch {
            let reason = userMessage(from: error)
            if let idx = conversations[jid]?.firstIndex(where: { $0.id == optimisticId }) {
                conversations[jid]?[idx] = FfiMessage(
                    id: optimisticId,
                    fromJid: ownJid,
                    toJid: jid,
                    body: trimmed,
                    timestamp: Int64(Date().timeIntervalSince1970),
                    isEncrypted: true,
                    status: "failed"
                )
            }
            messageErrors[optimisticId] = reason
            toasts.error("Message failed: \(reason)", retry: {
                Task { await self.sendMessage(to: jid, body: trimmed) }
            })
        }
    }

    func markRead(_ jid: String) {
        unread[jid] = 0
    }

    func sendTyping(to jid: String, isTyping: Bool) {
        Task {
            try? await client.sendTyping(jid: jid, isTyping: isTyping)
        }
    }

    func deleteConversation(jid: String) {
        conversations.removeValue(forKey: jid)
        unread.removeValue(forKey: jid)
        typing.remove(jid)
        Task {
            do {
                try await self.client.deleteConversation(jid: jid)
            } catch {
                self.toasts.warning("Failed to delete conversation on server: \(self.userMessage(from: error))")
            }
        }
    }

    func deleteMessage(id: String, partner: String) {
        conversations[partner]?.removeAll { $0.id == id }
        messageErrors.removeValue(forKey: id)
    }

    func retryMessage(id: String, partner: String, body: String) async {
        messageErrors.removeValue(forKey: id)
        do {
            let msg = try await client.sendMessage(toJid: partner, body: body)
            if let idx = conversations[partner]?.firstIndex(where: { $0.id == id }) {
                conversations[partner]?.remove(at: idx)
            }
            append(msg, partner: partner)
        } catch {
            let reason = userMessage(from: error)
            messageErrors[id] = reason
            toasts.error("Retry failed: \(reason)")
        }
    }

    // MARK: - Background suspend / foreground resume

    /// Cleanly disconnect when the app backgrounds. Credentials are preserved so
    /// the server gets a proper unavailable presence and can queue messages in MAM.
    func suspend() async {
        reconnectEnabled = false
        connectionGeneration &+= 1
        eventLoopTask?.cancel()
        eventLoopTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        isReconnecting = false
        await client.disconnect()
        isConnected = false
    }

    /// Reconnect immediately using saved credentials when returning to foreground.
    func resumeIfNeeded() {
        reconnectEnabled = true
        resumePending = true
        guard !isConnected, !isConnecting, !savedServer.isEmpty,
              let pw = CredentialStore.shared.loadPassword(), !pw.isEmpty else { return }
        resumePending = false
        reconnectTask?.cancel()
        reconnectAttempt = 0
        Task {
            await connect(server: savedServer,
                          username: CredentialStore.shared.username,
                          password: pw)
        }
    }

    // MARK: - Sign out

    func signOut() async {
        reconnectEnabled = false
        resumePending = false
        connectionGeneration &+= 1
        eventLoopTask?.cancel()
        eventLoopTask = nil
        // Cancel any pending reconnect before disconnecting
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        isReconnecting = false

        await client.disconnect()
        do {
            try CredentialStore.shared.clearAll()
        } catch {
            toasts.warning("Failed to clear keychain: \(error.localizedDescription)")
        }

        isConnected = false
        conversations = [:]
        contacts = [:]
        unread = [:]
        typing = []
        messageErrors = [:]
        ownJid = ""
        savedServer = ""
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
        let jids: [String]
        do {
            jids = try await client.listConversations()
        } catch {
            toasts.warning("Failed to load conversation list: \(userMessage(from: error))")
            return
        }
        for jid in jids {
            guard jid != "me", jid != "unknown", jid != "system",
                  !jid.isEmpty, jid.contains("@") else { continue }
            do {
                let msgs = try await client.loadHistory(jid: jid, limit: 100)
                conversations[jid] = msgs
            } catch {
                toasts.warning("Failed to load history for \(jid): \(userMessage(from: error))")
            }
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
                    // MAM queries and our stored timestamps are only precise to
                    // a second.  Query inclusively, then deduplicate by stable
                    // message ID: moving to the next second loses messages that
                    // share the final local message's timestamp.
                    let since: Int64
                    let knownIds: Set<String>
                    if let last = await self.conversations[jid]?.last {
                        since = last.timestamp
                        knownIds = Set(await self.conversations[jid]!.map { $0.id })
                    } else {
                        since = Int64(Date().timeIntervalSince1970) - 7 * 86400
                        knownIds = []
                    }
                    do {
                        let newMsgs = try await self.client.fetchMam(jid: jid, sinceUnixSecs: since)
                        await MainActor.run {
                            // Filter out IDs already in memory (belt-and-suspenders dedup)
                            for msg in newMsgs where !knownIds.contains(msg.id) {
                                self.append(msg, partner: jid)
                            }
                        }
                    } catch {
                        await MainActor.run {
                            self.toasts.warning("Failed to catch up messages for \(jid): \(self.userMessage(from: error))")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Private: event loop

    private func startEventLoop(generation: Int) {
        eventLoopTask?.cancel()
        eventLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let event = await self.client.nextEvent() {
                guard !Task.isCancelled,
                      generation == self.connectionGeneration else { return }
                self.handle(event)
            }
            guard !Task.isCancelled,
                  generation == self.connectionGeneration else { return }
            self.eventLoopTask = nil
            // The stream only closes when this connection has ended.  An
            // intentional disconnect increments the generation and is ignored.
            self.connectionDidDrop()
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
            connectionDidDrop()
        }
    }

    private func connectionDidDrop() {
        isConnected = false
        guard reconnectEnabled else { return }
        scheduleReconnect()
    }

    // MARK: - Private: reconnection

    private func scheduleReconnect() {
        // Don't retry if signed out or no saved credentials
        guard reconnectEnabled,
              !isConnecting,
              !isConnected,
              reconnectTask == nil,
              !savedServer.isEmpty,
              let pw = CredentialStore.shared.loadPassword(),
              !pw.isEmpty else { return }

        reconnectAttempt += 1
        // Exponential backoff: 2s, 4s, 8s, 16s, 30s (capped)
        let delay = min(pow(2.0, Double(reconnectAttempt)), 30.0)
        isReconnecting = true

        let generation = connectionGeneration
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self,
                  !Task.isCancelled,
                  self.reconnectEnabled,
                  generation == self.connectionGeneration,
                  !self.isConnected,
                  !self.isConnecting else {
                if let self, generation == self.connectionGeneration {
                    self.isReconnecting = false
                }
                return
            }
            self.reconnectTask = nil
            await self.connect(
                server: self.savedServer,
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

    /// Extract a user-friendly message from an FFI error.
    private func userMessage(from error: Swift.Error) -> String {
        if let ffiError = error as? FfiError {
            switch ffiError {
            case .NotConnected:
                return "Not connected to server"
            case .Connection(let reason):
                return cleanRustMessage(reason)
            case .Omemo(let reason):
                return omemoFriendlyMessage(reason)
            case .Send(let reason):
                return sendFriendlyMessage(reason)
            case .Roster(let reason):
                return cleanRustMessage(reason)
            }
        }
        return error.localizedDescription
    }

    /// Maps OMEMO-layer Rust error strings to concise actionable messages.
    private func omemoFriendlyMessage(_ reason: String) -> String {
        let lower = reason.lowercased()
        if lower.contains("no device") || lower.contains("no omemo") {
            return "Contact has no encryption devices registered"
        }
        if lower.contains("timeout") || lower.contains("timed out") {
            return "Timed out fetching encryption keys — retry when connected"
        }
        if lower.contains("untrusted") || lower.contains("trust") {
            return "Contact's encryption key is not trusted"
        }
        if lower.contains("session") {
            return "Encryption session error — retrying may help"
        }
        return "Encryption error"
    }

    /// Maps send-layer Rust error strings to concise actionable messages.
    private func sendFriendlyMessage(_ reason: String) -> String {
        let lower = reason.lowercased()
        if lower.contains("not connected") || lower.contains("notconnected") || lower.contains("xmpp") {
            return "Not connected to server"
        }
        if lower.contains("timeout") || lower.contains("timed out") {
            return "Send timed out — server may be slow"
        }
        if lower.contains("encrypt") || lower.contains("omemo") {
            return omemoFriendlyMessage(reason)
        }
        return cleanRustMessage(reason)
    }

    /// Returns the last segment of a Rust `anyhow` error chain ("A: B: root cause" → "root cause").
    private func cleanRustMessage(_ reason: String) -> String {
        let segments = reason.components(separatedBy: ": ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return segments.last ?? reason
    }
}
