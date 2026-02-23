import SwiftUI

/// Lists all user collections with project counts. Content column for the Collections sidebar entry.
struct CollectionBrowserView: View {
    @EnvironmentObject var collectionService: CollectionService
    @EnvironmentObject var auth: AuthenticationService

    @Binding var selectedCollection: AudioCollection?

    @State private var showNewCollectionSheet = false
    @State private var search = ""
    @State private var renamingCollectionId: UUID?
    @State private var renameText = ""
    @State private var collectionToDelete: AudioCollection?
    @State private var showDeleteConfirmation = false

    private var filteredCollections: [AudioCollection] {
        if search.isEmpty { return collectionService.collections }
        return collectionService.collections.filter {
            $0.name.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search...", text: $search)
                    .textFieldStyle(.roundedBorder)
            }
            .padding([.leading, .trailing])

            // Actions bar
            HStack {
                Text("\(collectionService.collections.count) collection\(collectionService.collections.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    showNewCollectionSheet = true
                } label: {
                    Label("New", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.top, 4)

            Divider().padding(.top, 4)

            // Collection list
            if collectionService.isLoading && collectionService.collections.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading collections...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredCollections.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No Collections")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Create a collection to organize\nyour projects.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                    Button("New Collection") {
                        showNewCollectionSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedCollection) {
                    ForEach(filteredCollections) { collection in
                        CollectionRow(
                            collection: collection,
                            renamingCollectionId: $renamingCollectionId,
                            renameText: $renameText
                        )
                        .tag(collection)
                        .contextMenu {
                            Button {
                                renameText = collection.name
                                renamingCollectionId = collection.id
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }

                            Button {
                                duplicateCollection(collection)
                            } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }

                            Divider()

                            Button(role: .destructive) {
                                collectionToDelete = collection
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .confirmationDialog(
                    "Delete \"\(collectionToDelete?.name ?? "")\"?",
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        if let collection = collectionToDelete, let token = auth.authToken {
                            Task {
                                await collectionService.deleteCollection(id: collection.id, token: token)
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will remove the collection but not the projects or bounces themselves.")
                }
            }
        }
        .task {
            if let token = try? await auth.validToken() {
                await collectionService.fetchCollections(token: token)
            }
        }
        .sheet(isPresented: $showNewCollectionSheet) {
            NewCollectionSheet()
        }
    }

    private func duplicateCollection(_ collection: AudioCollection) {
        guard let token = auth.authToken else { return }
        Task {
            _ = await collectionService.createCollection(
                name: "\(collection.name) Copy",
                description: collection.description,
                color: collection.color,
                contentTypes: collection.contentTypes,
                token: token
            )
        }
    }
}

// MARK: - Collection Row

private struct CollectionRow: View {
    let collection: AudioCollection
    @Binding var renamingCollectionId: UUID?
    @Binding var renameText: String
    @EnvironmentObject var collectionService: CollectionService
    @EnvironmentObject var auth: AuthenticationService
    @EnvironmentObject var backup: BackupService

    private var isBackedUp: Bool {
        let expectedName = "\(collection.name) Collection"
        return backup.availableBackups.contains { $0.name == expectedName }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let color = collection.color {
                    Circle()
                        .fill(Color(hex: color) ?? .blue)
                        .frame(width: 10, height: 10)
                }

                if renamingCollectionId == collection.id {
                    TextField("Collection name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                        .onSubmit {
                            let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty, let token = auth.authToken {
                                Task {
                                    await collectionService.updateCollection(
                                        id: collection.id,
                                        name: trimmed,
                                        description: nil,
                                        color: nil,
                                        token: token
                                    )
                                }
                            }
                            renamingCollectionId = nil
                        }
                } else {
                    Text(collection.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }

                if collection.isPack {
                    Text("Pack")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12))
                        .cornerRadius(4)
                }

                if collection.isSmart {
                    Label("Smart", systemImage: "sparkles")
                        .font(.caption2)
                        .foregroundColor(.purple)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.12))
                        .cornerRadius(4)
                }

                if isBackedUp {
                    Image(systemName: "checkmark.icloud")
                        .font(.caption2)
                        .foregroundColor(.green)
                }

                Spacer()

                // Content type badges
                HStack(spacing: 4) {
                    if collection.hasProjects {
                        Text("\(collection.projectCount)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.cyan.opacity(0.15))
                            .cornerRadius(3)
                    }
                    if collection.hasBounces {
                        Text("\(collection.bounceCount)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
            }

            HStack(spacing: 12) {
                if let desc = collection.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(Self.dateFormatter.string(from: collection.createdAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - New Collection Sheet

struct NewCollectionSheet: View {
    @EnvironmentObject var collectionService: CollectionService
    @EnvironmentObject var auth: AuthenticationService
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var selectedColor = "3B82F6" // blue
    @State private var selectedContentTypes: Set<CollectionContentType> = [.projects]

    private let colorOptions = [
        "3B82F6", // blue
        "EF4444", // red
        "10B981", // green
        "F59E0B", // amber
        "8B5CF6", // purple
        "EC4899", // pink
        "06B6D4", // cyan
        "F97316", // orange
    ]

    var body: some View {
        VStack(spacing: 20) {
            Text("New Collection")
                .font(.title2)
                .bold()

            Form {
                TextField("Name", text: $name)
                TextField("Description (optional)", text: $description)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Content Types")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        ForEach(CollectionContentType.allCases) { ct in
                            Button {
                                if selectedContentTypes.contains(ct) {
                                    // Don't allow deselecting the last one
                                    if selectedContentTypes.count > 1 {
                                        selectedContentTypes.remove(ct)
                                    }
                                } else {
                                    selectedContentTypes.insert(ct)
                                }
                            } label: {
                                Label(ct.label, systemImage: ct.icon)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(selectedContentTypes.contains(ct) ? Color.blue : Color.secondary.opacity(0.1))
                                    .foregroundColor(selectedContentTypes.contains(ct) ? .white : .primary)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Color")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        ForEach(colorOptions, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex) ?? .blue)
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary, lineWidth: selectedColor == hex ? 2 : 0)
                                )
                                .onTapGesture { selectedColor = hex }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Create") {
                    Task {
                        if let token = auth.authToken {
                            let types = selectedContentTypes.map(\.rawValue)
                            _ = await collectionService.createCollection(
                                name: name,
                                description: description.isEmpty ? nil : description,
                                color: selectedColor,
                                contentTypes: types,
                                token: token
                            )
                        }
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 500, height: 420)
    }
}

// MARK: - Color extension

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6,
              let int = UInt64(hex, radix: 16) else { return nil }
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
