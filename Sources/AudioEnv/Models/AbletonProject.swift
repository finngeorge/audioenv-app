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

// MARK: – Logic project (metadata extracted from bundle)

struct LogicProject: Codable {
    let name:       String
    let path:       String
    let metadata:   [String: String]   /// key/value pairs pulled from plist files inside the bundle
    let tempo:      Double?            /// extracted from metadata if available
    let sampleRate: Int?               /// extracted from metadata if available
    let mediaFiles: [String]           /// audio files discovered inside the bundle
    let midiFiles:  [String]           /// MIDI files discovered inside the bundle
    let bouncedFiles: [String]         /// bounced audio files discovered inside the bundle
    let alternatives: [String]         /// named alternatives found in Alternatives/ subdirectory
    let pluginHints: [String]          /// AU plugin IDs found via binary string scan of ProjectData

    // Structured fields from Alternatives/000/MetaData.plist
    let trackCount: Int?
    let songKey: String?               /// e.g. "C", "F#"
    let songScale: String?             /// e.g. "major", "minor" (from SongGenderKey)
    let timeSignatureNumerator: Int?
    let timeSignatureDenominator: Int?
    let hasARAPlugins: Bool?

    // Asset file arrays from MetaData.plist (filenames only, paths stripped)
    let samplerInstrumentFiles: [String]?
    let alchemyFiles: [String]?
    let impulseResponseFiles: [String]?
    let quicksamplerFiles: [String]?
    let ultrabeatFiles: [String]?
    let unusedAudioFiles: [String]?

    // From Resources/ProjectInformation.plist
    let logicVersion: String?          /// e.g. "Logic Pro X 11.0.0 (6011)"
}
