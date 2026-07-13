import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var state: AppState

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field { case server, username, password }

    var body: some View {
        NavigationStack {
            // If we're auto-connecting (credentials were already stored), show a
            // full-screen spinner instead of briefly flashing the form.
            if state.isConnecting && CredentialStore.shared.isComplete {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Connecting…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            Form {
                Section("Server") {
                    TextField("xmpp.server.org", text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focus, equals: .server)
                        .submitLabel(.next)
                        .onSubmit { focus = .username }
                }
                Section("Account") {
                    TextField("username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .focused($focus, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { Task { await connect() } }
                }
                if let error = state.connectionError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Sign In")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if state.isConnecting {
                        ProgressView()
                    } else {
                        Button("Connect") {
                            Task { await connect() }
                        }
                        .disabled(!isValid)
                    }
                }
            }
            } // end else (auto-connecting spinner branch)
        }
        .onAppear {
            // Pre-populate from stored credentials
            let store = CredentialStore.shared
            server   = store.server
            username = store.username
            if let saved = store.loadPassword() {
                password = saved
            }
            // Auto-connect if all credentials are already stored
            if store.isComplete {
                Task { await connect() }
            } else {
                focus = server.isEmpty ? .server : (username.isEmpty ? .username : .password)
            }
        }
    }

    private var isValid: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty
    }

    private func connect() async {
        await state.connect(
            server: server.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            password: password
        )
    }
}
