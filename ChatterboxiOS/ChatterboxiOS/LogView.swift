import SwiftUI

// MARK: - Log line model

private struct LogLine: Identifiable {
    let id: Int          // stable index into the full unfiltered array
    let text: String
    let level: Level

    enum Level {
        case error, warn, info, debug

        var color: Color {
            switch self {
            case .error: return .red
            case .warn:  return .orange
            case .info:  return .primary
            case .debug: return Color(.secondaryLabel)
            }
        }
    }

    init(id: Int, text: String) {
        self.id   = id
        self.text = text
        // Detect log level from common Rust env_logger / log-crate patterns.
        let upper = text.uppercased()
        if upper.contains(" ERROR") || upper.contains("[ERROR]") {
            self.level = .error
        } else if upper.contains(" WARN") || upper.contains("[WARN]") {
            self.level = .warn
        } else if upper.contains(" DEBUG") || upper.contains("[DEBUG]") {
            self.level = .debug
        } else {
            self.level = .info
        }
    }
}

// MARK: - LogView

struct LogView: View {
    @State private var lines: [LogLine] = []
    @State private var filter = ""
    @State private var levelFilter: Set<LogLine.Level> = [.error, .warn, .info, .debug]

    private var displayLines: [LogLine] {
        lines.filter { line in
            levelFilter.contains(line.level) &&
            (filter.isEmpty || line.text.localizedCaseInsensitiveContains(filter))
        }
    }

    private var shareText: String {
        displayLines.map(\.text).joined(separator: "\n")
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if lines.isEmpty {
                    ContentUnavailableView(
                        "No Logs",
                        systemImage: "doc.text",
                        description: Text("No log output has been captured yet.")
                    )
                } else if displayLines.isEmpty {
                    ContentUnavailableView.search(text: filter)
                } else {
                    List {
                        ForEach(displayLines) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(line.level.color)
                                .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                                .listRowSeparator(.hidden)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                        // Invisible anchor to enable scroll-to-bottom
                        Color.clear.frame(height: 1).id("bottom").listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter")
            .navigationTitle("Debug Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    levelFilterMenu
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        reload()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }

                    Button {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                    }

                    ShareLink(item: shareText, subject: Text("Chatterbox Debug Logs")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .onAppear {
                reload()
                DispatchQueue.main.async {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !lines.isEmpty {
                let shown = displayLines.count
                let total = lines.count
                Text(shown == total ? "\(total) lines" : "\(shown) of \(total) lines")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(.bar)
            }
        }
    }

    // MARK: - Level filter menu

    private var levelFilterMenu: some View {
        Menu {
            ForEach([LogLine.Level.error, .warn, .info, .debug], id: \.self) { level in
                Button {
                    if levelFilter.contains(level) {
                        if levelFilter.count > 1 { levelFilter.remove(level) }
                    } else {
                        levelFilter.insert(level)
                    }
                } label: {
                    Label(
                        level.label,
                        systemImage: levelFilter.contains(level) ? "checkmark" : "circle"
                    )
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }

    // MARK: - Private

    private func reload() {
        let raw = getLogContents()
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
        lines = raw.enumerated().map { LogLine(id: $0.offset, text: $0.element) }
    }
}

// MARK: - Level helpers

extension LogLine.Level: CaseIterable, Hashable {
    var label: String {
        switch self {
        case .error: return "Errors"
        case .warn:  return "Warnings"
        case .info:  return "Info"
        case .debug: return "Debug"
        }
    }
}
