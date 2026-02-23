import SwiftUI

/// Configure a smart query on a collection so new bounces matching the query
/// are automatically added.
struct SmartWatchSheet: View {
    let collection: AudioCollection
    @EnvironmentObject var collectionService: CollectionService
    @EnvironmentObject var commandService: CommandService
    @EnvironmentObject var bounceService: BounceService
    @EnvironmentObject var scanner: ScannerService
    @EnvironmentObject var auth: AuthenticationService
    @Environment(\.dismiss) private var dismiss

    @State private var query: Query
    @State private var autoBackup: Bool
    @State private var queryResult: CommandResult?
    @State private var isSaving = false

    /// Whether this collection already has a smart watch configured.
    private var isAlreadySmart: Bool {
        collection.isSmart
    }

    init(collection: AudioCollection) {
        self.collection = collection
        // Pre-populate from existing smart source if available
        if case .smart(let existingQuery) = collection.collectionSource {
            _query = State(initialValue: existingQuery)
        } else {
            _query = State(initialValue: Query(entityType: .bounces))
        }
        let key = "smartAutoBackup-\(collection.id)"
        _autoBackup = State(initialValue: UserDefaults.standard.bool(forKey: key))
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundColor(.purple)
                Text("Set Up Smart Watch")
                    .font(.title2)
                    .bold()
            }

            Text("New bounces matching this query will be automatically added to this collection.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            // Query builder
            CommandVisualBuilder(query: $query) {
                updatePreview()
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(12)

            // Match count
            if let result = queryResult {
                HStack(spacing: 6) {
                    Image(systemName: "number")
                        .foregroundColor(.secondary)
                    Text("\(result.totalMatchCount) items currently match")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            // Auto-backup toggle
            Toggle(isOn: $autoBackup) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-update backup when new items are added")
                        .font(.subheadline)
                    Text("Requires an existing backup for this collection")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(.horizontal)

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)

                if isAlreadySmart {
                    Button("Remove Watch", role: .destructive) {
                        removeSmartWatch()
                    }
                    .buttonStyle(.bordered)
                }

                Button("Save") {
                    saveSmartWatch()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
        }
        .padding()
        .frame(width: 540, height: 560)
        .task {
            // Ensure bounce and project data is loaded for accurate preview counts
            if let token = try? await auth.validToken() {
                if bounceService.bounces.isEmpty {
                    await bounceService.fetchBounces(token: token)
                }
            }
            updatePreview()
        }
    }

    private func updatePreview() {
        queryResult = commandService.executeQueryLocally(
            query,
            scanner: scanner,
            bounceService: bounceService,
            collectionService: collectionService
        )
    }

    private func saveSmartWatch() {
        guard let token = auth.authToken else { return }
        isSaving = true

        // Encode CollectionSource.smart(query) to JSON
        let source = CollectionSource.smart(query)
        guard let sourceData = try? JSONEncoder().encode(source),
              let sourceString = String(data: sourceData, encoding: .utf8) else {
            isSaving = false
            return
        }

        // Save auto-backup preference
        let key = "smartAutoBackup-\(collection.id)"
        UserDefaults.standard.set(autoBackup, forKey: key)

        Task {
            await collectionService.updateCollection(
                id: collection.id,
                name: nil,
                description: nil,
                color: nil,
                source: sourceString,
                token: token
            )
            isSaving = false
            dismiss()
        }
    }

    private func removeSmartWatch() {
        guard let token = auth.authToken else { return }
        isSaving = true

        // Encode CollectionSource.manual to JSON
        guard let sourceData = try? JSONEncoder().encode(CollectionSource.manual),
              let sourceString = String(data: sourceData, encoding: .utf8) else {
            isSaving = false
            return
        }

        // Clear auto-backup preference
        let key = "smartAutoBackup-\(collection.id)"
        UserDefaults.standard.removeObject(forKey: key)

        Task {
            await collectionService.updateCollection(
                id: collection.id,
                name: nil,
                description: nil,
                color: nil,
                source: sourceString,
                token: token
            )
            isSaving = false
            dismiss()
        }
    }
}
