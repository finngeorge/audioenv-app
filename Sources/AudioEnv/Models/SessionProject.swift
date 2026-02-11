import Foundation

struct SessionProject: Identifiable, Hashable {
    let id: String
    let name: String
    let format: SessionFormat
    let sessions: [AudioSession]    // primary (non-backup)
    let backups: [AudioSession]
    let latestDate: Date

    var totalSessions: Int { sessions.count }
}

extension SessionProject {
    static func groupSessions(_ sessions: [AudioSession]) -> [SessionProject] {
        let groups = Dictionary(grouping: sessions, by: { $0.projectGroupKey })
        var result: [SessionProject] = []
        result.reserveCapacity(groups.count)

        for (_, items) in groups {
            let sorted = items.sorted { $0.modifiedDate > $1.modifiedDate }
            let backups = sorted.filter { $0.isBackup }
            let primary = sorted.filter { !$0.isBackup }
            if primary.isEmpty {
                continue
            }
            let name = sorted.first?.projectDisplayName ?? "Project"
            let format = sorted.first?.format ?? .ableton
            let latestDate = sorted.first?.modifiedDate ?? Date.distantPast

            result.append(SessionProject(
                id: sorted.first?.projectGroupKey ?? UUID().uuidString,
                name: name,
                format: format,
                sessions: primary,
                backups: backups,
                latestDate: latestDate
            ))
        }

        return result.sorted { $0.latestDate > $1.latestDate }
    }
}
