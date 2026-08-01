import SwiftUI

// MARK: - Single toast row

private struct ToastRow: View {
    let toast: Toast
    let onDismiss: () -> Void
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.level.icon)
                .foregroundStyle(toast.level.color)
                .frame(width: 22)

            Text(toast.message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(3)

            Spacer(minLength: 0)

            if toast.action != nil {
                Button(toast.action!.title) {
                    onAction()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(toast.level.color)
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }
}

// MARK: - Overlay

struct ToastOverlay: View {
    @ObservedObject private var store: ToastStore

    init(store: ToastStore) {
        self.store = store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.toasts) { toast in
                ToastRow(
                    toast: toast,
                    onDismiss: { store.dismiss(toast) },
                    onAction: {
                        toast.action?.action()
                        store.dismiss(toast)
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeOut(duration: 0.2), value: store.toasts.count)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, max(UIApplication.shared.keyWindow?.safeAreaInsets.top ?? 16, 16))
    }
}
