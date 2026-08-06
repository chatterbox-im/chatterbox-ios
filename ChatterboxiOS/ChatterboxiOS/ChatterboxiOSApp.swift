import SwiftUI
import UIKit
import UserNotifications

@main
struct ChatterboxiOSApp: App {
    @StateObject private var state: AppState
    @StateObject private var toasts: ToastStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // AppState needs the store by reference, not via the environment.
        let toastStore = ToastStore()
        _toasts = StateObject(wrappedValue: toastStore)
        _state = StateObject(wrappedValue: AppState(toasts: toastStore))
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
                    // Ending the same identifier twice is a hard error.
                    guard bgTask != .invalid else { return }
                    app.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
                Task {
                    await state.suspend()
                    guard bgTask != .invalid else { return }
                    app.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            case .active:
                UNUserNotificationCenter.current().setBadgeCount(0)
                // Drop the accumulated background count too, otherwise the next
                // refresh re-adds messages the user has already seen.
                resetPendingBadgeCount()
                state.resumeIfNeeded()
            default:
                break
            }
        }
    }
}
