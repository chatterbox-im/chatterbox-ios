import SwiftUI

struct ContactInfoView: View {
    let jid: String
    @EnvironmentObject private var state: AppState
    @State private var fingerprints: [FfiFingerprint] = []
    @State private var isLoading = true
    @State private var error: String?

    private var contact: FfiContact? { state.contacts[jid] }

    var body: some View {
        List {
            // Contact header
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

            // OMEMO fingerprints
            Section {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading fingerprints…")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                    }
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
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
        }
        .navigationTitle("Contact Info")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadFingerprints() }
    }

    private func loadFingerprints() async {
        isLoading = true
        error = nil
        do {
            fingerprints = try await state.client.getFingerprints(jid: jid)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Fingerprint row

private struct FingerprintRow: View {
    let fingerprint: FfiFingerprint
    let jid: String
    @EnvironmentObject private var state: AppState

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
            let groups = fingerprint.fingerprint.components(separatedBy: " ")
            let line1 = groups.prefix(8).joined(separator: " ")
            let line2 = groups.dropFirst(8).joined(separator: " ")
            VStack(alignment: .leading, spacing: 2) {
                Text(line1)
                if !line2.isEmpty { Text(line2) }
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
