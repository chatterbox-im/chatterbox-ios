import SwiftUI
import Combine

// MARK: - Toast

enum ToastLevel {
    case info
    case success
    case warning
    case error

    var color: Color {
        switch self {
        case .info:    return .blue
        case .success: return .green
        case .warning: return .orange
        case .error:   return .red
        }
    }

    var icon: String {
        switch self {
        case .info:    return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "exclamationmark.circle.fill"
        }
    }
}

struct ToastAction: Hashable {
    let title: String
    let action: () -> Void

    static func == (lhs: ToastAction, rhs: ToastAction) -> Bool {
        lhs.title == rhs.title
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let level: ToastLevel
    let action: ToastAction?
    let createdAt = Date()

    static func == (lhs: Toast, rhs: Toast) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Store

@MainActor
class ToastStore: ObservableObject {
    @Published private(set) var toasts: [Toast] = []

    private let dismissDelay: TimeInterval = 5

    func push(_ message: String, level: ToastLevel = .info, action: ToastAction? = nil) {
        let toast = Toast(message: message, level: level, action: action)
        toasts.append(toast)
        dismissAfterDelay(toast)
    }

    func dismiss(_ toast: Toast) {
        toasts.removeAll { $0.id == toast.id }
    }

    func dismissAll() {
        toasts.removeAll()
    }

    // MARK: - Convenience

    func info(_ message: String) {
        push(message, level: .info)
    }

    func success(_ message: String) {
        push(message, level: .success)
    }

    func warning(_ message: String) {
        push(message, level: .warning)
    }

    func error(_ message: String, retry: (() -> Void)? = nil) {
        let action: ToastAction? = retry.map { ToastAction(title: "Retry", action: $0) }
        push(message, level: .error, action: action)
    }

    // MARK: - Private

    private func dismissAfterDelay(_ toast: Toast) {
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay) { [weak self] in
            self?.dismiss(toast)
        }
    }
}
