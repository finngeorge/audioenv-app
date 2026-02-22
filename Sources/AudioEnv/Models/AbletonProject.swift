import Foundation

// MARK: – Ableton project (parsed from .als XML)

struct AbletonProject: Codable {
    let version:     String          /// MinorVersion attribute from root element
    let tempo:       Double          /// BPM
    let tracks:      [AbletonTrack]
    let usedPlugins: [String]        /// deduplicated, sorted list of every plugin name in the project
    let samplePaths: [String]        /// deduplicated, sorted list of sample files referenced across all clips
    let projectSampleFiles: [String] /// audio files found in the project Samples folder
    let bouncedFiles:      [String]  /// audio files found in project bounce folders
    let projectRootPath:   String    /// root folder for the project on disk
    let timeSignature: String?       /// e.g. "4/4"
    let keyRoot: String?             /// e.g. "C", "F#"
    let keyScale: String?            /// e.g. "Major", "Minor"
}

// MARK: – Track type

enum AbletonTrackType: String, Codable {
    case audio
    case midi
    case beatBassline
    case returnTrack
    case master
}

// MARK: – Single track

struct AbletonTrack: Codable {
    let name:    String
    let type:    AbletonTrackType
    let plugins: [String]            /// plugin names on this track's chains
    let clips:   [AbletonClip]       /// clips found on this track
    let isMuted: Bool
    let isSolo:  Bool
    let color:   Int?                /// Ableton ColorIndex (if present)
}

// MARK: – Clip type

enum ClipType: String, Codable {
    case audio
    case midi
    case automation
}

// MARK: – Single clip

struct AbletonClip: Codable {
    let name:       String
    let type:       ClipType
    let position:   Double          /// position in project-timeline ticks
    let length:     Double          /// length in project-timeline ticks
    let samplePath: String?         /// resolved sample path (audio clips only)
}
