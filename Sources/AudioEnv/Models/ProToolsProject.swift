import Foundation

struct ProToolsProject: Codable {
    let signatureHex: String
    let byteLength: UInt64
    let sampleRate: Int?
    let audioFiles: [String]
    let bouncedFiles: [String]
    let pluginNames: [String]
    let videoFiles: [String]
    let renderedFiles: [String]
    let projectRootPath: String
}
