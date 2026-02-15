import SwiftUI
import AppKit

struct ProjectDetailView: View {
    let project: SessionProject
    @State private var selectedSession: AudioSession? = nil
    @State private var showBackups = false
    @State private var isParsing = false
    @EnvironmentObject var scanner: ScannerService

    private var sessionsToShow: [AudioSession] {
        let base = project.sessions
        if showBackups {
            return base + project.backups
        }
        return base
    }

    var body: some View {
        VStack(spacing: 0) {
            header()
            Divider()
            HStack(spacing: 12) {
                Toggle("Show Auto Backups", isOn: $showBackups)
                    .toggleStyle(.switch)
                    .fixedSize()
                Spacer()
                if isParsing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Parsing…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if unparsedCount > 0 && !isParsing {
                    Button("Parse One Unparsed") {
                        parseOneUnparsedSession()
                    }
                    .buttonStyle(.bordered)
                    .fixedSize(horizontal: true, vertical: false)
                }
                if !showBackups && project.backups.count > 0 {
                    Text("\(project.backups.count) auto backup\(project.backups.count == 1 ? "" : "s") hidden")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            HStack(spacing: 0) {
                List(sessionsToShow, selection: $selectedSession) { session in
                    SessionRow(session: session)
                        .tag(session)
                }
                .frame(minWidth: 220, idealWidth: 280)

                Divider()

                if let session = selectedSession {
                    SessionDetailView(session: session)
                } else {
                    emptyDetail()
                }
            }
        }
        .task(id: project.id) {
            let newest = (project.sessions + project.backups)
                .sorted { $0.modifiedDate > $1.modifiedDate }
                .first
            DispatchQueue.main.async {
                selectedSession = newest
            }
        }
    }

    private func header() -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(project.format.rawValue)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if project.backups.count > 0 {
                Text("\(project.backups.count) auto backup\(project.backups.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            HStack(spacing: 8) {
                Button("Show Folder") { showProjectFolder() }
                    .buttonStyle(.bordered)
                Button("Copy Path") { copyProjectPath() }
                    .buttonStyle(.bordered)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private func emptyDetail() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("Select a Session")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Choose a session to view details and analysis.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func projectFolderPath() -> String? {
        let path = (project.sessions.first ?? project.backups.first)?.path
        guard let p = path else { return nil }
        var dir = (p as NSString).deletingLastPathComponent
        if dir.lowercased().hasSuffix("/backups") || dir.lowercased().hasSuffix("/backup") {
            dir = (dir as NSString).deletingLastPathComponent
        }
        return dir
    }

    private func showProjectFolder() {
        guard let dir = projectFolderPath() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
    }

    private func copyProjectPath() {
        guard let dir = projectFolderPath() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dir, forType: .string)
    }

    private var unparsedCount: Int {
        project.sessions.filter { $0.project == nil }.count
    }

    private func parseOneUnparsedSession() {
        guard let session = project.sessions.first(where: { $0.project == nil }) else { return }
        isParsing = true
        scanner.parseIndividualSession(path: session.path) {
            isParsing = false
        }
    }
}

// MARK: – Session row

private struct SessionRow: View {
    let session: AudioSession

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle  = .medium
        f.timeStyle  = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(session.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if session.isBackup {
                    Text("Auto Backup")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.init(top: 2, leading: 6, bottom: 2, trailing: 6))
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                        .fixedSize(horizontal: true, vertical: false)
                }
                parsedBadge
                Text(session.format.rawValue)
                    .font(.caption)
                    .padding(.init(top: 2, leading: 6, bottom: 2, trailing: 6))
                    .background(fmtColor.opacity(0.15))
                    .foregroundColor(fmtColor)
                    .cornerRadius(4)
                    .fixedSize(horizontal: true, vertical: false)
            }

            HStack(spacing: 12) {
                Text(Self.dateFormatter.string(from: session.modifiedDate))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(sizeString)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if case .ableton(let p) = session.project {
                    Text("\(p.tracks.count) trk · \(p.samplePaths.count) smp · \(Int(p.tempo)) BPM")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(session.isBackup ? 0.7 : 1.0)
    }

    private var parsedBadge: some View {
        let isParsed = session.project != nil
        let label = isParsed ? "Parsed" : "Unparsed"
        let color = isParsed ? Color.green : Color.orange
        return Text(label)
            .font(.caption2)
            .foregroundColor(color)
            .padding(.init(top: 2, leading: 6, bottom: 2, trailing: 6))
            .background(color.opacity(0.15))
            .cornerRadius(4)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var fmtColor: Color {
        switch session.format {
        case .ableton:  return .gray
        case .logic:    return .blue
        case .proTools: return .purple
        }
    }

    private var sizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(session.fileSize), countStyle: .file)
    }
}
