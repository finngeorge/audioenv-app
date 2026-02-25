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

    // Detailed breakdown (Ableton-specific but available for other DAWs too)
    let audioTrackCount: Int?
    let midiTrackCount: Int?
    let returnTrackCount: Int?
    let clipCount: Int?
    let sampleCount: Int?
    let pluginNames: [String]?
    let trackPlugins: [TrackPluginInfo]?
    let abletonVersion: String?

    init(timestamp: Date = Date(), fileSize: Int64, pluginCount: Int? = nil,
         trackCount: Int? = nil, tempo: Double? = nil,
         keySignature: String? = nil, timeSignature: String? = nil,
         audioTrackCount: Int? = nil, midiTrackCount: Int? = nil,
         returnTrackCount: Int? = nil, clipCount: Int? = nil,
         sampleCount: Int? = nil, pluginNames: [String]? = nil,
         trackPlugins: [TrackPluginInfo]? = nil,
         abletonVersion: String? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.fileSize = fileSize
        self.pluginCount = pluginCount
        self.trackCount = trackCount
        self.tempo = tempo
        self.keySignature = keySignature
        self.timeSignature = timeSignature
        self.audioTrackCount = audioTrackCount
        self.midiTrackCount = midiTrackCount
        self.returnTrackCount = returnTrackCount
        self.clipCount = clipCount
        self.sampleCount = sampleCount
        self.pluginNames = pluginNames
        self.trackPlugins = trackPlugins
        self.abletonVersion = abletonVersion
    }
}

/// Plugin info with track location context.
struct TrackPluginInfo: Codable {
    let pluginName: String
    let trackName: String
    let trackType: String  // "audio", "midi", "return", "master"
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

    init(projectPath: String, projectName: String, format: SessionFormat, dawPID: Int32, openedAt: Date? = nil) {
        self.id = UUID()
        self.projectPath = projectPath
        self.projectName = projectName
        self.format = format
        self.dawPID = dawPID
        self.openedAt = openedAt ?? Date()
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

/// Diff between two consecutive session snapshots.
struct SnapshotDiff: Codable {
    let addedPlugins: [String]
    let removedPlugins: [String]
    let addedTracks: Int
    let removedTracks: Int
    let tempoChanged: Bool
    let oldTempo: Double?
    let newTempo: Double?

    /// Compute the diff between two snapshots.
    static func diff(from prev: SessionSnapshot, to curr: SessionSnapshot) -> SnapshotDiff {
        let prevPlugins = Set(prev.pluginNames ?? [])
        let currPlugins = Set(curr.pluginNames ?? [])

        let prevTracks = prev.trackCount ?? 0
        let currTracks = curr.trackCount ?? 0
        let trackDelta = currTracks - prevTracks

        let tempoChanged = prev.tempo != curr.tempo

        return SnapshotDiff(
            addedPlugins: Array(currPlugins.subtracting(prevPlugins)).sorted(),
            removedPlugins: Array(prevPlugins.subtracting(currPlugins)).sorted(),
            addedTracks: max(0, trackDelta),
            removedTracks: max(0, -trackDelta),
            tempoChanged: tempoChanged,
            oldTempo: tempoChanged ? prev.tempo : nil,
            newTempo: tempoChanged ? curr.tempo : nil
        )
    }
}

extension LiveSession {
    /// Diff the two most recent snapshots.
    var latestDiff: SnapshotDiff? {
        guard snapshots.count >= 2 else { return nil }
        let prev = snapshots[snapshots.count - 2]
        let curr = snapshots[snapshots.count - 1]
        return SnapshotDiff.diff(from: prev, to: curr)
    }
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
