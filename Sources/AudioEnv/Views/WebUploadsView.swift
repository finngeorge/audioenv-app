import SwiftUI

/// Lists projects uploaded from the web that are waiting to download onto this Mac.
struct WebUploadsView: View {
    @ObservedObject var model: WebUploadsViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Web Uploads")
                    .font(.title2).bold()
                Text("Projects uploaded from the web, waiting to download to this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.isLoading)
            .help("Refresh")
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.pending.isEmpty {
            Spacer()
            ProgressView("Loading…")
            Spacer()
        } else if model.pending.isEmpty {
            emptyState
        } else {
            List(model.pending) { item in
                row(item)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No uploads waiting")
                .font(.headline)
            Text("When you upload a project on the web, it'll appear here to download.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ item: PendingWebUpload) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.zipper")
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = item.sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.downloadingIds.contains(item.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Download") {
                    Task { await model.download(item) }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
