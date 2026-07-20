import SwiftUI
import UIKit
import UserNotifications

@main
struct ChatterboxiOSApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        registerBackgroundTasks()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if state.isConnected {
                    ConversationListView()
                } else {
                    LoginView()
                }
            }
            .environmentObject(state)
            .animation(.easeInOut, value: state.isConnected)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                scheduleBackgroundRefresh()
                let app = UIApplication.shared
                var bgTask = UIBackgroundTaskIdentifier.invalid
                bgTask = app.beginBackgroundTask(withName: "xmpp-disconnect") {
                    app.endBackgroundTask(bgTask)
                }
                Task {
                    await state.suspend()
                    app.endBackgroundTask(bgTask)
                }
            case .active:
                UNUserNotificationCenter.current().setBadgeCount(0)
                state.resumeIfNeeded()
            default:
                break
            }
        }
    }
}
