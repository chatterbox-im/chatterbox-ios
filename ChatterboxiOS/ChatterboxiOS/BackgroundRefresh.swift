import BackgroundTasks
import UserNotifications
import Foundation

// Identifier must match BGTaskSchedulerPermittedIdentifiers in Info.plist
let kBGRefreshTaskID = "io.github.chatterbox-im.ChatterboxiOS.refresh"
private let kLastBGRefreshKey = "lastBGRefreshTimestamp"
private let kPendingBadgeKey = "pendingBadgeCount"

// MARK: - Registration (call once at app startup)

func registerBackgroundTasks() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: kBGRefreshTaskID, using: nil) { task in
        guard let refreshTask = task as? BGAppRefreshTask else { return }
        handleBackgroundRefresh(task: refreshTask)
    }
}

// MARK: - Scheduling (call when app backgrounds)

func scheduleBackgroundRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: kBGRefreshTaskID)
    // iOS will honour "no earlier than" but may delay significantly — this is expected.
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    do {
        try BGTaskScheduler.shared.submit(request)
    } catch BGTaskScheduler.Error.notPermitted {
        // Background fetch not enabled — silently ignore in simulator/TestFlight
    } catch {
        // Best-effort; do not surface to user
    }
}

// MARK: - Task handler

/// Ensures `setTaskCompleted` runs exactly once: calling it after expiry has
/// already completed the task is treated by iOS as a programmer error.
private final class CompletionGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var isDone = false

    func completeOnce(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !isDone else { return }
        isDone = true
        body()
    }
}

private func handleBackgroundRefresh(task: BGAppRefreshTask) {
    // Re-schedule before doing any work so we don't miss the next slot
    scheduleBackgroundRefresh()

    let completion = CompletionGuard()

    let work = Task {
        let newMessages = await performMAMCatchUp()
        if newMessages > 0, !Task.isCancelled {
            await deliverLocalNotification(
                newMessages: newMessages,
                badgeCount: addPendingBadgeCount(newMessages)
            )
        }
        completion.completeOnce { task.setTaskCompleted(success: true) }
    }

    task.expirationHandler = {
        work.cancel()
        completion.completeOnce { task.setTaskCompleted(success: false) }
    }
}

// MARK: - MAM catch-up (runs in background, independent of foreground AppState)

private func performMAMCatchUp() async -> Int {
    guard CredentialStore.shared.isComplete,
          let password = CredentialStore.shared.loadPassword() else { return 0 }

    let client = ChatterboxClient()
    var newCount = 0
    let ownUsername = CredentialStore.shared.username
    // The login form stores server and username separately, so `username` is
    // usually a bare local part ("alice") while MAM returns full JIDs
    // ("alice@example.com/resource").  Comparing the two unmodified made every
    // message we had sent ourselves count as an incoming one, which is how the
    // badge ends up claiming new messages that do not exist.
    let ownBareJid = bareJid(username: ownUsername, server: CredentialStore.shared.server)
    let ownLocalPart = ownBareJid.components(separatedBy: "@").first ?? ownBareJid

    // NOTE: Do NOT call setLogFile here. setLogFile truncates the file, which
    // would wipe all foreground session logs. Background refresh logs are kept
    // in the in-memory ring buffer only.

    // Use the timestamp of the last successful background refresh; default to 24 h ago.
    let lastRefresh = UserDefaults.standard.double(forKey: kLastBGRefreshKey)
    let since: Int64 = lastRefresh > 0
        ? Int64(lastRefresh)
        : Int64(Date().timeIntervalSince1970) - 86400

    do {
        try await client.connect(
            server: CredentialStore.shared.server,
            username: ownUsername,
            password: password
        )

        if let jids = try? await client.listConversations() {
            for jid in jids where jid.contains("@") {
                // The expiration handler cancels us; stop promptly so we can
                // disconnect cleanly before iOS kills the process.
                if Task.isCancelled { break }
                let msgs = (try? await client.fetchMam(jid: jid, sinceUnixSecs: since)) ?? []
                // Count only messages FROM others (not our own echoes)
                newCount += msgs.filter {
                    let from = $0.fromJid.components(separatedBy: "/").first ?? $0.fromJid
                    return from != ownBareJid && from != ownLocalPart && from != "me"
                }.count
            }
        }

        // timeIntervalSinceNow is ~0, not an epoch value: storing it made the
        // `lastRefresh > 0` check below always fail and re-count a full day.
        if !Task.isCancelled {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: kLastBGRefreshKey)
        }
    } catch {
        // Connection failed — will retry on next background slot
    }

    await client.disconnect()
    return newCount
}

/// Builds the account's bare JID from the separately stored server/username.
private func bareJid(username: String, server: String) -> String {
    let withDomain = username.contains("@") ? username : "\(username)@\(server)"
    return withDomain.components(separatedBy: "/").first ?? withDomain
}

// MARK: - Badge bookkeeping

/// The badge must survive several background wakes, and must be cleared by the
/// foreground once the user has actually seen the messages.
private func addPendingBadgeCount(_ delta: Int) -> Int {
    let total = UserDefaults.standard.integer(forKey: kPendingBadgeKey) + delta
    UserDefaults.standard.set(total, forKey: kPendingBadgeKey)
    return total
}

/// Call when the app becomes active — the in-app unread counts take over.
func resetPendingBadgeCount() {
    UserDefaults.standard.set(0, forKey: kPendingBadgeKey)
}

// MARK: - Local notification

private func deliverLocalNotification(newMessages: Int, badgeCount: Int) async {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    guard settings.authorizationStatus == .authorized else { return }

    let content = UNMutableNotificationContent()
    content.title = "Chatterbox"
    content.body = newMessages == 1
        ? "You have 1 new message"
        : "You have \(newMessages) new messages"
    content.sound = .default
    content.badge = NSNumber(value: badgeCount)

    let request = UNNotificationRequest(
        identifier: "bg-refresh-\(Int(Date().timeIntervalSince1970))",
        content: content,
        trigger: nil  // deliver immediately
    )
    try? await center.add(request)
}

// MARK: - Notification permission (call after first connect)

func requestNotificationPermission() {
    Task {
        try? await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        )
    }
}
