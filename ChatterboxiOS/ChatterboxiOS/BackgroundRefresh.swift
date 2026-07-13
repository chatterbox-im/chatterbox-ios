import BackgroundTasks
import UserNotifications
import Foundation

// Identifier must match BGTaskSchedulerPermittedIdentifiers in Info.plist
let kBGRefreshTaskID = "io.github.chatterbox-im.ChatterboxiOS.refresh"
private let kLastBGRefreshKey = "lastBGRefreshTimestamp"

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

private func handleBackgroundRefresh(task: BGAppRefreshTask) {
    // Re-schedule before doing any work so we don't miss the next slot
    scheduleBackgroundRefresh()

    let work = Task {
        let newMessages = await performMAMCatchUp()
        if newMessages > 0 {
            await deliverLocalNotification(newMessages: newMessages)
        }
        task.setTaskCompleted(success: true)
    }

    task.expirationHandler = {
        work.cancel()
        task.setTaskCompleted(success: false)
    }
}

// MARK: - MAM catch-up (runs in background, independent of foreground AppState)

private func performMAMCatchUp() async -> Int {
    guard CredentialStore.shared.isComplete,
          let password = CredentialStore.shared.loadPassword() else { return 0 }

    let client = ChatterboxClient()
    var newCount = 0
    let ownUsername = CredentialStore.shared.username

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
                let msgs = (try? await client.fetchMam(jid: jid, sinceUnixSecs: since)) ?? []
                // Count only messages FROM others (not our own echoes)
                let ownBare = ownUsername.components(separatedBy: "/").first ?? ownUsername
                newCount += msgs.filter {
                    let from = $0.fromJid.components(separatedBy: "/").first ?? $0.fromJid
                    return from != ownBare && from != "me"
                }.count
            }
        }

        UserDefaults.standard.set(Date().timeIntervalSinceNow, forKey: kLastBGRefreshKey)
    } catch {
        // Connection failed — will retry on next background slot
    }

    await client.disconnect()
    return newCount
}

// MARK: - Local notification

private func deliverLocalNotification(newMessages: Int) async {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    guard settings.authorizationStatus == .authorized else { return }

    let content = UNMutableNotificationContent()
    content.title = "Chatterbox"
    content.body = newMessages == 1
        ? "You have 1 new message"
        : "You have \(newMessages) new messages"
    content.sound = .default
    content.badge = NSNumber(value: newMessages)

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
