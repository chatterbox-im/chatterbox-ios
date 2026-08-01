import SwiftUI
import UIKit
import UserNotifications

@main
struct ChatterboxiOSApp: App {
    @StateObject private var state = AppState()
    @StateObject private var toasts = ToastStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        registerBackgroundTasks()
        configureLogging()
    }

    private func configureLogging() {
        if let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first {
            let logPath = docs.appendingPathComponent("chatterbox.log").path
            setLogFile(path: logPath)
        }
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
            .environmentObject(toasts)
            .animation(.easeInOut, value: state.isConnected)
            .overlay(alignment: .top) {
                ToastOverlay(store: toasts)
            }
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
