import Foundation

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

    // Binary-parsed track data from ProjectData
    var trackNames: [String: String]      /// channel strip → user track name, e.g. "Audio 12" → "Lead 1"
    var trackPlugins: [String: [String]]  /// channel strip → plugin names, e.g. "Audio 12" → ["FabFilter Pro-Q 4"]

    init(name: String, path: String, metadata: [String: String],
         tempo: Double?, sampleRate: Int?,
         mediaFiles: [String], midiFiles: [String],
         bouncedFiles: [String], alternatives: [String],
         pluginHints: [String],
         trackCount: Int?, songKey: String?, songScale: String?,
         timeSignatureNumerator: Int?, timeSignatureDenominator: Int?,
         hasARAPlugins: Bool?,
         samplerInstrumentFiles: [String]?, alchemyFiles: [String]?,
         impulseResponseFiles: [String]?, quicksamplerFiles: [String]?,
         ultrabeatFiles: [String]?, unusedAudioFiles: [String]?,
         logicVersion: String?,
         trackNames: [String: String] = [:],
         trackPlugins: [String: [String]] = [:]) {
        self.name = name
        self.path = path
        self.metadata = metadata
        self.tempo = tempo
        self.sampleRate = sampleRate
        self.mediaFiles = mediaFiles
        self.midiFiles = midiFiles
        self.bouncedFiles = bouncedFiles
        self.alternatives = alternatives
        self.pluginHints = pluginHints
        self.trackCount = trackCount
        self.songKey = songKey
        self.songScale = songScale
        self.timeSignatureNumerator = timeSignatureNumerator
        self.timeSignatureDenominator = timeSignatureDenominator
        self.hasARAPlugins = hasARAPlugins
        self.samplerInstrumentFiles = samplerInstrumentFiles
        self.alchemyFiles = alchemyFiles
        self.impulseResponseFiles = impulseResponseFiles
        self.quicksamplerFiles = quicksamplerFiles
        self.ultrabeatFiles = ultrabeatFiles
        self.unusedAudioFiles = unusedAudioFiles
        self.logicVersion = logicVersion
        self.trackNames = trackNames
        self.trackPlugins = trackPlugins
    }
}
