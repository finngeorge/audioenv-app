import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var auth: AuthenticationService

    var body: some View {
        VStack {
            if auth.isAuthenticated {
                AuthenticatedProfileView()
            } else {
                LoginRegisterView()
            }
        }
        .navigationTitle("Profile")
    }
}

// MARK: - Authenticated View

struct AuthenticatedProfileView: View {
    @EnvironmentObject var auth: AuthenticationService
    @EnvironmentObject var backup: BackupService
    @EnvironmentObject var sync: SyncService

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Profile Header
                VStack(spacing: 12) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)

                    if let user = auth.currentUser {
                        Text(user.username)
                            .font(.title2)
                            .fontWeight(.bold)

                        Text(user.email)
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        // Subscription tier badge
                        Text(user.subscriptionTier.uppercased())
                            .font(.caption)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(tierColor(user.subscriptionTier).opacity(0.2))
                            .foregroundColor(tierColor(user.subscriptionTier))
                            .cornerRadius(8)
                    } else {
                        Text("User")
                            .font(.title2)
                            .fontWeight(.bold)
                    }
                }
                .padding(.top, 40)

                Divider()

                // Account Info
                if let user = auth.currentUser {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Account Information")
                            .font(.headline)
                            .fontWeight(.semibold)

                        InfoRow(label: "User ID", value: String(user.id.prefix(8)) + "...")
                        InfoRow(label: "Device Name", value: sync.deviceName)
                        InfoRow(label: "macOS Version", value: ProcessInfo.processInfo.operatingSystemVersionString)
                        InfoRow(label: "Storage Used", value: formatBytes(user.storageUsedBytes))
                        InfoRow(label: "S3 Storage", value: backup.formattedTotalStorage)
                        InfoRow(label: "Subscription", value: user.subscriptionTier.capitalized)
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(12)
                }

                Divider()

                // Actions
                VStack(spacing: 12) {
                    Button(action: {
                        auth.logout()
                    }) {
                        HStack {
                            Image(systemName: "arrow.right.square")
                            Text("Sign Out")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .foregroundColor(.red)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(24)
        }
    }

    private func tierColor(_ tier: String) -> Color {
        switch tier.lowercased() {
        case "pro": return .blue
        case "unlimited": return .purple
        default: return .gray
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Login/Register View

struct LoginRegisterView: View {
    @EnvironmentObject var auth: AuthenticationService

    @State private var showingRegister = false
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)

                    Text(showingRegister ? "Create Account" : "Welcome Back")
                        .font(.title)
                        .fontWeight(.bold)

                    Text(showingRegister ? "Sign up to sync your plugins and projects" : "Sign in to access your account")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)

                // Form
                VStack(spacing: 16) {
                    if showingRegister {
                        TextField("Username", text: $username)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.username)
                    }

                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)

                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(showingRegister ? .newPassword : .password)
                }
                .padding(.horizontal, 40)

                // Error message
                if let error = auth.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 40)
                }

                // Submit button
                Button(action: {
                    Task {
                        await submitForm()
                    }
                }) {
                    HStack {
                        if auth.isLoading {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.8)
                        }
                        Text(showingRegister ? "Create Account" : "Sign In")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(auth.isLoading || !isFormValid)
                .padding(.horizontal, 40)

                // OAuth divider
                HStack {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                    Text("or")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                }
                .padding(.horizontal, 40)

                // OAuth buttons
                VStack(spacing: 10) {
                    Button {
                        Task {
                            do {
                                try await auth.signInWithApple()
                            } catch {
                                auth.errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "apple.logo")
                            Text(showingRegister ? "Sign up with Apple" : "Sign in with Apple")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.black)
                    .controlSize(.large)
                    .disabled(auth.isLoading)

                    Button {
                        Task {
                            do {
                                try await auth.signInWithGoogle()
                            } catch {
                                auth.errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        HStack {
                            Text("G")
                                .fontWeight(.bold)
                                .foregroundColor(.blue)
                            Text(showingRegister ? "Sign up with Google" : "Sign in with Google")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(auth.isLoading)
                }
                .padding(.horizontal, 40)

                // Toggle between login/register
                Button(action: {
                    showingRegister.toggle()
                    auth.errorMessage = nil
                }) {
                    Text(showingRegister ? "Already have an account? Sign In" : "Don't have an account? Sign Up")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }

                Spacer()
            }
            .padding(24)
        }
    }

    private var isFormValid: Bool {
        if showingRegister {
            return !email.isEmpty && !username.isEmpty && !password.isEmpty && password.count >= 6
        } else {
            return !email.isEmpty && !password.isEmpty
        }
    }

    private func submitForm() async {
        do {
            if showingRegister {
                try await auth.register(email: email, username: username, password: password)
            } else {
                try await auth.login(email: email, password: password)
            }
            // Clear form on success
            email = ""
            username = ""
            password = ""
        } catch {
            auth.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Info Row

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .layoutPriority(1)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

#Preview("Authenticated") {
    let auth = AuthenticationService()
    auth.isAuthenticated = true
    auth.currentUser = AuthenticationService.User(
        id: "123e4567-e89b-12d3-a456-426614174000",
        email: "test@example.com",
        username: "testuser",
        subscriptionTier: "pro",
        storageUsedBytes: 5_000_000_000
    )
    return ProfileView()
        .environmentObject(auth)
        .environmentObject(BackupService())
        .environmentObject(SyncService())
        .frame(width: 400, height: 600)
}

#Preview("Login") {
    ProfileView()
        .environmentObject(AuthenticationService())
        .environmentObject(BackupService())
        .environmentObject(SyncService())
        .frame(width: 400, height: 600)
}
