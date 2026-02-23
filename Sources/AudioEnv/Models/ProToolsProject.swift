import Foundation

struct PTPluginInsert: Codable, Hashable {
    let name: String
    let pluginId: String
    let presetName: String
    let manufacturer: String
    var isInstalled: Bool
}

struct PTTrack: Codable {
    let name: String
    let index: Int
    let isStereo: Bool
    let trackType: String  // "audio", "aux", "master", "bus", "click", "folder"
    var plugins: [PTPluginInsert]
}

struct PTAudioClip: Codable {
    let name: String
    let index: Int
}

struct ProToolsProject: Codable {
    // File info
    let headerVersion: String
    let byteLength: UInt64

    // Session path
    let sessionName: String
    let sessionFilename: String
    let volumeName: String
    let sessionPath: String

    // Previous session (Save As origin)
    let prevSessionFilename: String?
    let prevSessionPath: String?

    // Settings
    let sampleRate: Int?
    let bitDepth: Int?

    // Content
    let tracks: [PTTrack]
    let audioClips: [PTAudioClip]
    let pluginCatalog: [PTPluginInsert]

    // File discovery (kept from old parser)
    let audioFiles: [String]
    let bouncedFiles: [String]
    let videoFiles: [String]
    let renderedFiles: [String]
    let projectRootPath: String

    // Computed
    var trackCount: Int { tracks.count }
    var audioTrackCount: Int { tracks.filter { $0.trackType == "audio" }.count }
    var auxTrackCount: Int { tracks.filter { $0.trackType == "aux" || $0.trackType == "bus" }.count }
    var masterTrackCount: Int { tracks.filter { $0.trackType == "master" }.count }
}
