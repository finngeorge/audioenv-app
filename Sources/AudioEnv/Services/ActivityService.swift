import Foundation
import os.log

/// Fetches session activity data from the API for display in the Activity tab.
@MainActor
class ActivityService: ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "Activity")

    // MARK: - Published State

    @Published var activities: [ActivityRecord] = []
    @Published var summary: ActivitySummaryResponse?
    @Published var isLoading = false
    @Published var lastError: String?

    private let baseURL: String = {
        if let override = UserDefaults.standard.string(forKey: "apiBaseURL"), !override.isEmpty {
            return override
        }
        return "https://api.audioenv.com"
    }()

    // MARK: - Fetch Activities

    func fetchActivities(token: String, days: Int = 30) async {
        isLoading = true
        defer { isLoading = false }

        let url = URL(string: "\(baseURL)/api/sessions/activity?days=\(days)&per_page=10000")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                lastError = "Failed to fetch activities (status \(code))"
                return
            }

            let decoder = FlexibleISO8601.makeAPIDecoder()
            // API returns paginated response
            let paginated = try decoder.decode(PaginatedActivityResponse.self, from: data)
            activities = paginated.items
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            logger.error("fetchActivities failed: \(error)")
        }
    }

    // MARK: - Fetch Summary

    func fetchSummary(token: String) async {
        let url = URL(string: "\(baseURL)/api/sessions/activity/summary")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            let decoder = FlexibleISO8601.makeAPIDecoder()
            summary = try decoder.decode(ActivitySummaryResponse.self, from: data)
        } catch {
            logger.error("fetchSummary failed: \(error)")
        }
    }

    // MARK: - Fetch All

    func fetchAll(token: String, days: Int = 30) async {
        async let a: () = fetchActivities(token: token, days: days)
        async let s: () = fetchSummary(token: token)
        _ = await (a, s)
    }
}

// MARK: - Response Models

struct PaginatedActivityResponse: Codable {
    let items: [ActivityRecord]
    let total: Int
    let page: Int
    let pages: Int
}

struct ActivityRecord: Codable, Identifiable, Hashable {
    let id: String
    let projectName: String
    let projectPath: String
    let sessionFormat: String
    let openedAt: Date
    let closedAt: Date?
    let durationSeconds: Int
    let saveCount: Int
    let initialSizeBytes: Int64
    let finalSizeBytes: Int64
    let newAudioFiles: Int
    let newBounces: Int
    let snapshots: [ActivitySnapshot]
    let relatedProjectPath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case projectName = "project_name"
        case projectPath = "project_path"
        case sessionFormat = "session_format"
        case openedAt = "opened_at"
        case closedAt = "closed_at"
        case durationSeconds = "duration_seconds"
        case saveCount = "save_count"
        case initialSizeBytes = "initial_size_bytes"
        case finalSizeBytes = "final_size_bytes"
        case newAudioFiles = "new_audio_files"
        case newBounces = "new_bounces"
        case snapshots
        case relatedProjectPath = "related_project_path"
    }

    static func == (lhs: ActivityRecord, rhs: ActivityRecord) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var sizeDelta: Int64 { finalSizeBytes - initialSizeBytes }
}

struct ActivitySnapshot: Codable, Hashable {
    let timestamp: Date
    let fileSize: Int64
    let pluginCount: Int?
    let trackCount: Int?
    let tempo: Double?
    let keySignature: String?
    let timeSignature: String?
    let pluginNames: [String]?
    let trackPlugins: [ActivityTrackPlugin]?
    let audioTrackCount: Int?
    let midiTrackCount: Int?
    let returnTrackCount: Int?
    let clipCount: Int?
    let sampleCount: Int?
    let abletonVersion: String?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case fileSize = "file_size"
        case pluginCount = "plugin_count"
        case trackCount = "track_count"
        case tempo
        case keySignature = "key_signature"
        case timeSignature = "time_signature"
        case pluginNames = "plugin_names"
        case trackPlugins = "track_plugins"
        case audioTrackCount = "audio_track_count"
        case midiTrackCount = "midi_track_count"
        case returnTrackCount = "return_track_count"
        case clipCount = "clip_count"
        case sampleCount = "sample_count"
        case abletonVersion = "ableton_version"
    }
}

struct ActivityTrackPlugin: Codable, Hashable {
    let pluginName: String
    let trackName: String
    let trackType: String

    // API sends track_plugins as [[plugin_name, track_name, track_type]] arrays
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let arr = try container.decode([String].self)
        guard arr.count >= 3 else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected 3-element array for TrackPlugin"
            )
        }
        pluginName = arr[0]
        trackName = arr[1]
        trackType = arr[2]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([pluginName, trackName, trackType])
    }
}

struct ActivitySummaryResponse: Codable {
    let totalSessionsWeek: Int
    let totalSessionsMonth: Int
    let totalHoursWeek: Double
    let totalHoursMonth: Double
    let mostActiveProjects: [ActivityProjectSummary]
    let mostUsedFormats: [ActivityFormatSummary]

    enum CodingKeys: String, CodingKey {
        case totalSessionsWeek = "total_sessions_week"
        case totalSessionsMonth = "total_sessions_month"
        case totalHoursWeek = "total_hours_week"
        case totalHoursMonth = "total_hours_month"
        case mostActiveProjects = "most_active_projects"
        case mostUsedFormats = "most_used_formats"
    }
}

struct ActivityProjectSummary: Codable, Identifiable {
    let projectName: String
    let sessionFormat: String
    let totalSessions: Int
    let totalHours: Double

    var id: String { "\(projectName)-\(sessionFormat)" }

    enum CodingKeys: String, CodingKey {
        case projectName = "project_name"
        case sessionFormat = "session_format"
        case totalSessions = "total_sessions"
        case totalHours = "total_hours"
    }
}

struct ActivityFormatSummary: Codable, Identifiable {
    let sessionFormat: String
    let sessionCount: Int

    var id: String { sessionFormat }

    enum CodingKeys: String, CodingKey {
        case sessionFormat = "session_format"
        case sessionCount = "session_count"
    }
}
