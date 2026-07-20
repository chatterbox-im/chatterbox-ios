import SwiftUI
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
                Task { await state.suspend() }
            case .active:
                UNUserNotificationCenter.current().setBadgeCount(0)
                state.resumeIfNeeded()
            default:
                break
            }
        }
    }
}
