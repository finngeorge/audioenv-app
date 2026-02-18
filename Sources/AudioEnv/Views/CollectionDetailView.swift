import SwiftUI

/// Detail view for a selected collection — shows its projects and management controls.
struct CollectionDetailView: View {
    let collection: AudioCollection
    @EnvironmentObject var collectionService: CollectionService
    @EnvironmentObject var auth: AuthenticationService
    @EnvironmentObject var scanner: ScannerService

    @State private var showEditSheet = false
    @State private var showAddProjectsSheet = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                header()

                Divider()

                // Projects section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Projects")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button {
                            showAddProjectsSheet = true
                        } label: {
                            Label("Add Projects", systemImage: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if collection.projectCount == 0 {
                        VStack(spacing: 12) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("No projects in this collection")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("Add Projects") {
                                showAddProjectsSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else {
                        Text("\(collection.projectCount) project\(collection.projectCount == 1 ? "" : "s") in this collection")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                // Quick actions
                VStack(alignment: .leading, spacing: 12) {
                    Text("Actions")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            showEditSheet = true
                        } label: {
                            Label("Edit Collection", systemImage: "pencil")
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                Spacer()
            }
            .padding(20)
        }
        .sheet(isPresented: $showEditSheet) {
            EditCollectionSheet(collection: collection)
        }
        .sheet(isPresented: $showAddProjectsSheet) {
            AddProjectsSheet(collectionId: collection.id)
        }
        .confirmationDialog(
            "Delete \"\(collection.name)\"?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    if let token = auth.authToken {
                        await collectionService.deleteCollection(id: collection.id, token: token)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the collection but not the projects themselves.")
        }
    }

    private func header() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let color = collection.color {
                    Circle()
                        .fill(Color(hex: color) ?? .blue)
                        .frame(width: 16, height: 16)
                }

                Text(collection.name)
                    .font(.title)
                    .fontWeight(.bold)
            }

            if let desc = collection.description, !desc.isEmpty {
                Text(desc)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 16) {
                Label("\(collection.projectCount) projects", systemImage: "folder")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Edit Collection Sheet

struct EditCollectionSheet: View {
    let collection: AudioCollection
    @EnvironmentObject var collectionService: CollectionService
    @EnvironmentObject var auth: AuthenticationService
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var description: String
    @State private var selectedColor: String

    private let colorOptions = [
        "3B82F6", "EF4444", "10B981", "F59E0B",
        "8B5CF6", "EC4899", "06B6D4", "F97316",
    ]

    init(collection: AudioCollection) {
        self.collection = collection
        _name = State(initialValue: collection.name)
        _description = State(initialValue: collection.description ?? "")
        _selectedColor = State(initialValue: collection.color ?? "3B82F6")
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Collection")
                .font(.title2)
                .bold()

            Form {
                TextField("Name", text: $name)
                TextField("Description", text: $description)

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
                Button("Save") {
                    Task {
                        if let token = auth.authToken {
                            await collectionService.updateCollection(
                                id: collection.id,
                                name: name,
                                description: description.isEmpty ? nil : description,
                                color: selectedColor,
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
        .frame(width: 450, height: 360)
    }
}

// MARK: - Add Projects Sheet

struct AddProjectsSheet: View {
    let collectionId: UUID
    @EnvironmentObject var collectionService: CollectionService
    @EnvironmentObject var auth: AuthenticationService
    @EnvironmentObject var scanner: ScannerService
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var selectedSessionIds: Set<String> = []

    private var projects: [SessionProject] {
        let all = SessionProject.groupSessions(scanner.sessions)
        if search.isEmpty { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Add Projects to Collection")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Select projects to add")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search projects...", text: $search)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            Divider().padding(.top, 8)

            // Project list
            List {
                ForEach(projects) { project in
                    HStack {
                        Image(systemName: selectedSessionIds.contains(project.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedSessionIds.contains(project.id) ? .blue : .secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                                .font(.body)
                                .fontWeight(.medium)
                            Text("\(project.sessions.count) session\(project.sessions.count == 1 ? "" : "s") - \(project.format.rawValue)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedSessionIds.contains(project.id) {
                            selectedSessionIds.remove(project.id)
                        } else {
                            selectedSessionIds.insert(project.id)
                        }
                    }
                }
            }
            .listStyle(.inset)

            // Footer
            HStack {
                Text("\(selectedSessionIds.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)

                Button("Add to Collection") {
                    Task {
                        if let token = auth.authToken {
                            // Note: the API uses scanned_session_id which maps to the session UUID
                            // For now we pass the project group IDs; the actual mapping depends
                            // on synced session IDs from the backend.
                            // This is a placeholder — the session IDs need to be the backend UUIDs.
                            await collectionService.fetchCollections(token: token)
                        }
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedSessionIds.isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 500)
    }
}
