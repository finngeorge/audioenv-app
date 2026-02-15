import Foundation

/// A snapshot of session state captured on save or periodically.
struct SessionSnapshot: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let fileSize: Int64
    let pluginCount: Int?
    let trackCount: Int?
    let tempo: Double?
    let keySignature: String?
    let timeSignature: String?

    init(timestamp: Date = Date(), fileSize: Int64, pluginCount: Int? = nil,
         trackCount: Int? = nil, tempo: Double? = nil,
         keySignature: String? = nil, timeSignature: String? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.fileSize = fileSize
        self.pluginCount = pluginCount
        self.trackCount = trackCount
        self.tempo = tempo
        self.keySignature = keySignature
        self.timeSignature = timeSignature
    }
}

/// Represents a live DAW session being monitored in real time.
struct LiveSession: Identifiable, Codable {
    let id: UUID
    let projectPath: String
    let projectName: String
    let format: SessionFormat
    let dawPID: Int32
    var openedAt: Date
    var closedAt: Date?
    var saveCount: Int
    var lastSaveAt: Date?
    var initialFileSize: Int64
    var currentFileSize: Int64
    var newAudioFiles: [String]
    var newBounces: [String]
    var snapshots: [SessionSnapshot]

    init(projectPath: String, projectName: String, format: SessionFormat, dawPID: Int32) {
        self.id = UUID()
        self.projectPath = projectPath
        self.projectName = projectName
        self.format = format
        self.dawPID = dawPID
        self.openedAt = Date()
        self.closedAt = nil
        self.saveCount = 0
        self.lastSaveAt = nil

        let size = (try? FileManager.default.attributesOfItem(atPath: projectPath)[.size] as? Int64) ?? 0
        self.initialFileSize = size
        self.currentFileSize = size
        self.newAudioFiles = []
        self.newBounces = []
        self.snapshots = []
    }

    /// Duration the session has been open.
    var duration: TimeInterval {
        let end = closedAt ?? Date()
        return end.timeIntervalSince(openedAt)
    }

    /// File size change since session opened.
    var sizeDelta: Int64 {
        currentFileSize - initialFileSize
    }

    var isOpen: Bool { closedAt == nil }
}

/// Info about a running DAW process.
struct DAWProcessInfo: Codable {
    let bundleID: String
    let format: SessionFormat
    let pid: Int32
    let name: String
    var stats: DAWProcessStats?
}

/// CPU/memory/audio stats for a running DAW.
struct DAWProcessStats: Codable {
    let cpuPercent: Double
    let memoryMB: Double
    let audioDevice: String?
    let sampleRate: Int?
    let timestamp: Date

    init(cpuPercent: Double = 0, memoryMB: Double = 0,
         audioDevice: String? = nil, sampleRate: Int? = nil) {
        self.cpuPercent = cpuPercent
        self.memoryMB = memoryMB
        self.audioDevice = audioDevice
        self.sampleRate = sampleRate
        self.timestamp = Date()
    }
}
