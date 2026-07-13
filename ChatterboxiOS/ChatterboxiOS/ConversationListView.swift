import SwiftUI

struct ConversationListView: View {
    @EnvironmentObject private var state: AppState
    @State private var newJid = ""
    @State private var showNewChat = false
    @State private var showSignOut = false
    @State private var path = NavigationPath()

    /// Contacts not yet in any conversation, for the new-chat picker
    private var rosterContacts: [FfiContact] {
        state.contacts.values
            .filter { !state.conversations.keys.contains($0.jid) }
            .sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationDestination(for: String.self) { value in
                    if value.hasPrefix("info:") {
                        let jid = String(value.dropFirst(5))
                        ContactInfoView(jid: jid)
                    } else {
                        ChatView(jid: value)
                    }
                }
        }
    }

    private var list: some View {
        List {
            ForEach(state.sortedConversations, id: \.jid) { item in
                NavigationLink(value: item.jid) {
                    ConversationRow(
                        jid: item.jid,
                        contact: state.contacts[item.jid],
                        lastMessage: item.lastMessage,
                        unread: state.unread[item.jid] ?? 0
                    )
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        state.deleteConversation(jid: item.jid)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Chatterbox")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSignOut = true } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showNewChat = true } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
            ToolbarItem(placement: .bottomBar) {
                HStack(spacing: 5) {
                    if state.isReconnecting {
                        ProgressView().scaleEffect(0.7)
                        Text("Reconnecting…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Circle()
                            .fill(state.isConnected ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(state.isConnected ? "Connected" : "Disconnected")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .confirmationDialog("Sign out of \(CredentialStore.shared.username)?",
                            isPresented: $showSignOut,
                            titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Task { await state.signOut() }
            }
        }
        .alert("New Conversation", isPresented: $showNewChat) {
            TextField("user@example.com", text: $newJid)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
            Button("Open") {
                let jid = newJid.trimmingCharacters(in: .whitespaces)
                newJid = ""
                guard !jid.isEmpty else { return }
                openConversation(jid: jid)
            }
            Button("Cancel", role: .cancel) { newJid = "" }
        } message: {
            // Show roster contacts as a hint when available
            if rosterContacts.isEmpty {
                Text("Enter the JID of the person you want to chat with.")
            } else {
                Text("Enter a JID or choose from your contacts below.")
            }
        }
        .sheet(isPresented: .constant(!rosterContacts.isEmpty && showNewChat),
               onDismiss: { showNewChat = false }) {
            RosterPickerSheet(rosterContacts: rosterContacts) { jid in
                showNewChat = false
                openConversation(jid: jid)
            }
            .presentationDetents([.medium, .large])
        }
        .overlay {
            if state.sortedConversations.isEmpty {
                ContentUnavailableView(
                    "No Conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Tap ✏ to start a new conversation.")
                )
            }
        }
    }

    private func openConversation(jid: String) {
        if state.conversations[jid] == nil { state.conversations[jid] = [] }
        path.append(jid)
    }
}

// MARK: - Roster picker sheet

private struct RosterPickerSheet: View {
    let rosterContacts: [FfiContact]
    let onSelect: (String) -> Void

    @State private var search = ""

    private var filtered: [FfiContact] {
        search.isEmpty ? rosterContacts :
            rosterContacts.filter {
                $0.displayName.localizedCaseInsensitiveContains(search) ||
                $0.jid.localizedCaseInsensitiveContains(search)
            }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.jid) { contact in
                Button {
                    onSelect(contact.jid)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.displayName.isEmpty ? contact.jid : contact.displayName)
                            .foregroundStyle(.primary)
                        if !contact.displayName.isEmpty {
                            Text(contact.jid).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search contacts")
            .navigationTitle("New Conversation")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ConversationRow: View {
    let jid: String
    let contact: FfiContact?
    let lastMessage: FfiMessage
    let unread: Int

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Avatar with presence dot
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .frame(width: 46, height: 46)
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(presenceColor)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(formattedTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(lastMessage.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if unread > 0 {
                        Text("\(min(unread, 99))")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var displayName: String {
        contact?.displayName.isEmpty == false
            ? contact!.displayName
            : (jid.components(separatedBy: "@").first ?? jid)
    }

    private var presenceColor: Color {
        switch contact?.status {
        case "online":  return .green
        case "away":    return .yellow
        default:        return .gray
        }
    }

    private var formattedTime: String {
        let date = Date(timeIntervalSince1970: Double(lastMessage.timestamp))
        return Calendar.current.isDateInToday(date)
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.month().day())
    }
}
