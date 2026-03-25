import SwiftUI

struct CloudBrowserView: View {
    @Binding var selectedItem: CloudItem?
    @EnvironmentObject var cloud: CloudService
    @EnvironmentObject var auth: AuthenticationService

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header()
            Divider()
            filterBar()
            Divider()

            if cloud.isLoading && cloud.items.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading cloud files...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if cloud.filteredItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "cloud")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(cloud.items.isEmpty ? "No cloud files yet" : "No matching files")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(cloud.filteredItems, selection: $selectedItem) { item in
                    cloudItemRow(item)
                        .tag(item)
                }
            }
        }
        .task {
            if cloud.items.isEmpty, let token = auth.authToken {
                await cloud.loadAll(token: token)
            }
        }
    }

    // MARK: - Header

    private func header() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Cloud Files", systemImage: "cloud")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                if cloud.isLoading {
                    ProgressView().controlSize(.small)
                }

                Button {
                    Task {
                        if let token = auth.authToken {
                            await cloud.loadAll(token: token)
                        }
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(cloud.isLoading)
            }

            // Storage usage card
            if let usage = cloud.storageUsage {
                storageCard(usage)
            }
        }
        .padding()
    }

    private func storageCard(_ usage: CloudStorageUsage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Storage")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if let limit = usage.formattedLimit {
                    Text("\(usage.formattedUsed) of \(limit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(usage.formattedUsed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if usage.hasLimit {
                ProgressView(value: usage.usagePercent)
                    .tint(usage.usagePercent > 0.9 ? .red : usage.usagePercent > 0.7 ? .orange : .blue)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    // MARK: - Filter bar

    private func filterBar() -> some View {
        HStack(spacing: 8) {
            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Search files...", text: $cloud.searchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                if !cloud.searchText.isEmpty {
                    Button { cloud.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(6)
            .frame(maxWidth: 200)

            Spacer()

            // Filter pills
            filterPill("All", count: cloud.items.count, filter: nil)
            filterPill("Backups", count: cloud.backupCount, filter: .backup)
            filterPill("Uploads", count: cloud.uploadCount, filter: .upload)
            if cloud.sharedCount > 0 {
                filterPill("Shared", count: cloud.sharedCount, filter: .shared)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func filterPill(_ label: String, count: Int, filter: CloudItemType?) -> some View {
        let isActive = cloud.selectedFilter == filter
        return Button {
            cloud.selectedFilter = isActive ? nil : filter
        } label: {
            Text("\(label) (\(count))")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isActive ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                .foregroundColor(isActive ? .accentColor : .primary)
                .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Item row

    private func cloudItemRow(_ item: CloudItem) -> some View {
        HStack(spacing: 10) {
            // Type icon
            Image(systemName: item.itemType.systemImage)
                .font(.title3)
                .foregroundColor(iconColor(for: item.itemType))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if item.isPending {
                        Text("Pending")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(.orange)
                            .cornerRadius(3)
                    }
                }

                HStack(spacing: 6) {
                    // File type icons
                    ForEach(item.fileTypeIcons, id: \.self) { icon in
                        Image(systemName: icon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let format = item.format {
                        Text(format)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(3)
                    }

                    if let sender = item.senderUsername {
                        Text("from \(sender)")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }

                    if let date = item.uploadedAt {
                        Text(Self.dateFormatter.string(from: date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if item.sizeBytes > 0 {
                Text(item.formattedSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func iconColor(for type: CloudItemType) -> Color {
        switch type {
        case .backup: return .blue
        case .upload: return .green
        case .shared: return .purple
        }
    }
}
