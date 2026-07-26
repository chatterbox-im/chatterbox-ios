import SwiftUI
import os.log

struct ContactInfoView: View {
    let jid: String
    @EnvironmentObject private var state: AppState
    @State private var fingerprints: [FfiFingerprint] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private var contact: FfiContact? { state.contacts[jid] }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .frame(width: 60, height: 60)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        if let name = contact?.displayName, !name.isEmpty {
                            Text(name).font(.title3.bold())
                        }

                        Text(jid)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                if let successMessage {
                    Label(successMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                self.successMessage = nil
                            }
                        }
                }
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading fingerprints…")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                    }
                } else if let errorMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                        Button("Retry") {
                            Task { await loadFingerprints() }
                        }
                        .font(.footnote)
                        .foregroundStyle(.blue)
                    }
                } else if fingerprints.isEmpty {
                    Text("No OMEMO devices found")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                } else {
                    ForEach(fingerprints, id: \.deviceId) { fp in
                        FingerprintRow(fingerprint: fp, jid: jid)
                            .environmentObject(state)
                    }
                }
            } header: {
                Label("OMEMO Fingerprints", systemImage: "lock.shield")
            } footer: {
                if !fingerprints.isEmpty {
                    Text("Verify these fingerprints out-of-band to confirm end-to-end encryption.")
                        .font(.caption)
                }
            }

            Section {
                Button {
                    Task { await resetAndReload() }
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Reset OMEMO Session & Reload")
                        Spacer()
                        if isLoading {
                            ProgressView()
                        }
                    }
                }
                .disabled(isLoading)
            }
        }
        .navigationTitle("Contact Info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await loadFingerprints() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task { await loadFingerprints() }
    }

    private func resetAndReload() async {
        let count = self.fingerprints.count
        print("[ContactInfoView] Resetting OMEMO sessions for \(count) device(s)")
        for fp in self.fingerprints {
            print("[ContactInfoView] Resetting session for device \(fp.deviceId)")
            try? await state.client.resetOmemoSession(jid: jid, deviceId: fp.deviceId)
        }
        print("[ContactInfoView] Reset complete, reloading fingerprints")
        await loadFingerprints()
        self.successMessage = "Reset \(count) session(s) and reloaded fingerprints"
    }

    private func loadFingerprints() async {
        print("[ContactInfoView] Loading fingerprints for \(jid)")
        self.isLoading = true
        self.errorMessage = nil
        self.successMessage = nil
        do {
            self.fingerprints = try await withTimeout(10) {
                try await state.client.getFingerprints(jid: jid)
            }
            print("[ContactInfoView] Loaded \(self.fingerprints.count) fingerprint(s)")
            self.successMessage = "Loaded \(self.fingerprints.count) fingerprint(s)"
        } catch {
            print("[ContactInfoView] Error loading fingerprints: \(error.localizedDescription)")
            self.errorMessage = error.localizedDescription
        }
        self.isLoading = false
    }

    private func withTimeout<T>(_ seconds: UInt64, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw NSError(domain: "ContactInfoView", code: 1, userInfo: [NSLocalizedDescriptionKey: "Request timed out after \(seconds)s"])
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Fingerprint row

private struct FingerprintRow: View {
    let fingerprint: FfiFingerprint
    let jid: String
    @EnvironmentObject private var state: AppState

    private var fingerprintLines: (line1: String, line2: String) {
        let groups = fingerprint.fingerprint.components(separatedBy: " ")
        let line1 = groups.prefix(8).joined(separator: " ")
        let line2 = groups.dropFirst(8).joined(separator: " ")
        return (line1, line2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Device \(fingerprint.deviceId)", systemImage: "iphone")
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    Task { await toggleTrust() }
                } label: {
                    Image(systemName: fingerprint.isTrusted ? "checkmark.shield.fill" : "shield.slash")
                        .foregroundStyle(fingerprint.isTrusted ? .green : .orange)
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(fingerprintLines.line1)
                if !fingerprintLines.line2.isEmpty { Text(fingerprintLines.line2) }
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func toggleTrust() async {
        do {
            if fingerprint.isTrusted {
                try await state.client.distrustDevice(jid: jid, deviceId: fingerprint.deviceId)
            } else {
                try await state.client.trustDevice(jid: jid, deviceId: fingerprint.deviceId)
            }
        } catch {
            // Ignore — fingerprint list will refresh on next open
        }
    }
}
