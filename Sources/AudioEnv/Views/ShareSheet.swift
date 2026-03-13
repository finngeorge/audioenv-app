import SwiftUI

/// Identifiable wrapper for share target data, usable with `.sheet(item:)`.
struct ShareTarget: Identifiable {
    let id = UUID()
    let entityType: String
    let entityId: String
    let entityName: String
}

/// Reusable share sheet for sharing projects, bounces, collections, or backups with other AudioEnv users.
struct ShareSheet: View {
    let entityType: String  // "project", "bounce", "collection", "backup"
    let entityId: String
    let entityName: String

    @EnvironmentObject var authService: AuthenticationService
    @EnvironmentObject var shareService: ContentShareService
    @Environment(\.dismiss) private var dismiss

    @State private var recipient = ""
    @State private var permission = "download"
    @State private var message = ""
    @State private var showMessage = false
    @State private var isSharing = false
    @State private var showSuccess = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 4) {
                Text("Share \(entityType.capitalized)")
                    .font(.headline)
                Text(entityName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding()

            Divider()

            // Content
            VStack(alignment: .leading, spacing: 16) {
                // Recipient
                VStack(alignment: .leading, spacing: 6) {
                    Text("Share with")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Username or email", text: $recipient)
                        .textFieldStyle(.roundedBorder)
                }

                // Permissions
                VStack(alignment: .leading, spacing: 6) {
                    Text("Permissions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $permission) {
                        Text("Can view").tag("view")
                        Text("Can download").tag("download")
                    }
                    .pickerStyle(.segmented)
                }

                // Optional message
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation { showMessage.toggle() }
                    } label: {
                        Label(showMessage ? "Hide message" : "Add message", systemImage: showMessage ? "chevron.up" : "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    if showMessage {
                        TextEditor(text: $message)
                            .frame(height: 60)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    }
                }

                // Error
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                // Success
                if showSuccess {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(shareService.lastSuccess ?? "Shared!")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding()

            Divider()

            // Footer
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Share") { share() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(recipient.isEmpty || isSharing)
            }
            .padding()
        }
        .frame(width: 380, height: showMessage ? 380 : 300)
    }

    private func share() {
        guard !recipient.isEmpty else { return }
        isSharing = true
        errorMessage = nil

        Task {
            do {
                guard let token = authService.authToken else {
                    errorMessage = "Not logged in"
                    isSharing = false
                    return
                }

                let isEmail = recipient.contains("@")
                _ = try await shareService.share(
                    entityType: entityType,
                    entityId: entityId,
                    recipientUsername: isEmail ? nil : recipient,
                    recipientEmail: isEmail ? recipient : nil,
                    permissions: permission,
                    message: message.isEmpty ? nil : message,
                    token: token
                )

                showSuccess = true
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                dismiss()
            } catch {
                errorMessage = shareService.lastError ?? error.localizedDescription
            }
            isSharing = false
        }
    }
}
