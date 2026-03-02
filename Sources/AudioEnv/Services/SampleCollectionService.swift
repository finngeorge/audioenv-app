import Foundation
import SwiftUI

/// Service for collecting project samples and media files
@MainActor
class SampleCollectionService: ObservableObject {

    // MARK: - Published State

    @Published var isCollecting = false
    @Published var collectionProgress: Double = 0.0
    @Published var collectionLog: [CollectionLogEntry] = []
    @Published var lastError: String?
    @Published var lastResult: CollectionResult?

    // MARK: - Main Collection Method

    /// Collect all samples and media files for a session
    func collectSamples(for session: AudioSession, outputDirectory: URL) async throws -> CollectionResult {
        isCollecting = true
        collectionProgress = 0.0
        collectionLog.removeAll()
        lastError = nil

        defer {
            isCollecting = false
            collectionProgress = 1.0
        }

        guard let project = session.project else {
            throw CollectionError.noProjectData
        }

        let result: CollectionResult

        switch project {
        case .ableton(let abletonProject):
            result = try await collectAbletonSamples(project: abletonProject, session: session, outputDirectory: outputDirectory)

        case .logic(let logicProject):
            result = try await collectLogicMedia(project: logicProject, session: session, outputDirectory: outputDirectory)

        case .proTools(let proToolsProject):
            result = try await collectProToolsMedia(project: proToolsProject, session: session, outputDirectory: outputDirectory)
        }

        lastResult = result
        return result
    }

    // MARK: - DAW-Specific Collection

    /// Collect Ableton samples using parsed sample paths (accurate)
    private func collectAbletonSamples(project: AbletonProject, session: AudioSession, outputDirectory: URL) async throws -> CollectionResult {
        log("Starting Ableton sample collection...", status: .info)
        log("Project root: \(project.projectRootPath)", status: .info)
        log("Output: \(outputDirectory.path)", status: .info)

        // Create output directory
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var copiedFiles = 0
        var failedFiles = 0
        var skippedInternal = 0
        var missingFiles: [String] = []
        var totalSize: UInt64 = 0

        let samplePaths = project.samplePaths
        let totalFiles = samplePaths.count
        let projectRootURL = URL(fileURLWithPath: project.projectRootPath)

        log("Found \(totalFiles) sample references in .als", status: .info)

        for (index, samplePath) in samplePaths.enumerated() {
            // Resolve path: use directly if absolute and exists, otherwise resolve against project root
            let sourcePath: URL
            if samplePath.hasPrefix("/") {
                sourcePath = URL(fileURLWithPath: samplePath)
            } else {
                sourcePath = projectRootURL.appendingPathComponent(samplePath)
            }

            // Skip files already inside the project folder — they don't need collecting
            if sourcePath.path.hasPrefix(projectRootURL.path) {
                skippedInternal += 1
                collectionProgress = Double(index + 1) / Double(totalFiles)
                continue
            }

            if FileManager.default.fileExists(atPath: sourcePath.path) {
                do {
                    // Preserve subdirectory structure based on original path
                    let relativePath = samplePath.hasPrefix("/") ? sourcePath.lastPathComponent : samplePath
                    let destinationPath = outputDirectory.appendingPathComponent(relativePath)

                    // Create intermediate directories
                    let destDir = destinationPath.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

                    // Count as success if destination already exists
                    if FileManager.default.fileExists(atPath: destinationPath.path) {
                        copiedFiles += 1
                        log("\(relativePath) (already collected)", status: .success)
                        collectionProgress = Double(index + 1) / Double(totalFiles)
                        continue
                    }

                    // Copy file
                    try FileManager.default.copyItem(at: sourcePath, to: destinationPath)

                    // Get file size
                    let attributes = try FileManager.default.attributesOfItem(atPath: sourcePath.path)
                    let fileSize = attributes[.size] as? UInt64 ?? 0
                    totalSize += fileSize

                    copiedFiles += 1
                    log(relativePath, status: .success)
                } catch {
                    failedFiles += 1
                    log(samplePath, status: .failed, message: error.localizedDescription)
                }
            } else {
                missingFiles.append(samplePath)
                log(samplePath, status: .missing)
            }

            collectionProgress = Double(index + 1) / Double(totalFiles)
        }

        log("Collection complete: \(copiedFiles) copied, \(skippedInternal) already in project, \(failedFiles) failed, \(missingFiles.count) missing", status: .success)

        return CollectionResult(
            format: .ableton,
            method: .pathExtraction,
            copiedFiles: copiedFiles,
            failedFiles: failedFiles,
            missingFiles: missingFiles,
            totalSize: totalSize,
            outputDirectory: outputDirectory,
            warning: nil
        )
    }

    /// Collect Logic Pro media using folder-based approach (approximate)
    private func collectLogicMedia(project: LogicProject, session: AudioSession, outputDirectory: URL) async throws -> CollectionResult {
        log("Starting Logic Pro media collection...", status: .info)
        log("⚠️ Using folder-based collection - external samples may be missing", status: .info)

        // Create output directory
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var copiedFiles = 0
        var totalSize: UInt64 = 0

        // Get project root
        let projectRoot = URL(fileURLWithPath: session.path).deletingLastPathComponent()

        // Folders to collect
        let foldersToCollect = [
            "Media",
            "Audio Files",
            "Sampler Files",
            "Bounces"
        ]

        for folderName in foldersToCollect {
            let folderPath = projectRoot.appendingPathComponent(folderName)

            if FileManager.default.fileExists(atPath: folderPath.path) {
                log("Collecting \(folderName)...", status: .info)

                let destinationPath = outputDirectory.appendingPathComponent(folderName)

                do {
                    try FileManager.default.copyItem(at: folderPath, to: destinationPath)

                    // Calculate size
                    let size = try FileSystemHelpers.calculateDirectorySize(folderPath)
                    totalSize += size

                    // Count files
                    let files = try FileManager.default.contentsOfDirectory(at: folderPath, includingPropertiesForKeys: nil)
                    copiedFiles += files.count

                    log("✅ Collected \(folderName) (\(files.count) files)", status: .success)
                } catch {
                    log("Failed to collect \(folderName): \(error.localizedDescription)", status: .failed)
                }
            }
        }

        log("✅ Collection complete: \(copiedFiles) files collected", status: .success)

        return CollectionResult(
            format: .logic,
            method: .folderBased,
            copiedFiles: copiedFiles,
            failedFiles: 0,
            missingFiles: [],
            totalSize: totalSize,
            outputDirectory: outputDirectory,
            warning: "Logic Pro uses a binary format. This collection includes project media folders but may miss externally referenced samples."
        )
    }

    /// Collect Pro Tools media using folder-based approach (approximate)
    private func collectProToolsMedia(project: ProToolsProject, session: AudioSession, outputDirectory: URL) async throws -> CollectionResult {
        log("Starting Pro Tools media collection...", status: .info)
        log("⚠️ Using folder-based collection - external samples may be missing", status: .info)

        // Create output directory
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var copiedFiles = 0
        var totalSize: UInt64 = 0

        // Get session root
        let sessionRoot = URL(fileURLWithPath: session.path).deletingLastPathComponent()

        // Folders to collect
        let foldersToCollect = [
            "Audio Files",
            "Bounced Files",
            "Clip Groups",
            "Session File Backups"
        ]

        for folderName in foldersToCollect {
            let folderPath = sessionRoot.appendingPathComponent(folderName)

            if FileManager.default.fileExists(atPath: folderPath.path) {
                log("Collecting \(folderName)...", status: .info)

                let destinationPath = outputDirectory.appendingPathComponent(folderName)

                do {
                    try FileManager.default.copyItem(at: folderPath, to: destinationPath)

                    // Calculate size
                    let size = try FileSystemHelpers.calculateDirectorySize(folderPath)
                    totalSize += size

                    // Count files
                    let files = try FileManager.default.contentsOfDirectory(at: folderPath, includingPropertiesForKeys: nil)
                    copiedFiles += files.count

                    log("✅ Collected \(folderName) (\(files.count) files)", status: .success)
                } catch {
                    log("Failed to collect \(folderName): \(error.localizedDescription)", status: .failed)
                }
            }
        }

        log("✅ Collection complete: \(copiedFiles) files collected", status: .success)

        return CollectionResult(
            format: .proTools,
            method: .folderBased,
            copiedFiles: copiedFiles,
            failedFiles: 0,
            missingFiles: [],
            totalSize: totalSize,
            outputDirectory: outputDirectory,
            warning: "Pro Tools uses a binary format. This collection includes session media folders but may miss externally referenced samples."
        )
    }

    // MARK: - Logging

    private func log(_ path: String, status: CollectionStatus, message: String = "") {
        let entry = CollectionLogEntry(path: path, status: status, message: message)
        collectionLog.append(entry)
    }
}

// MARK: - Models

enum CollectionMethod {
    case pathExtraction  // Ableton - accurate
    case folderBased     // Logic/Pro Tools - approximate
}

enum CollectionStatus: String {
    case success
    case failed
    case missing
    case info
}

struct CollectionResult {
    let format: SessionFormat
    let method: CollectionMethod
    let copiedFiles: Int
    let failedFiles: Int
    let missingFiles: [String]
    let totalSize: UInt64
    let outputDirectory: URL
    let warning: String?

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)
    }
}

struct CollectionLogEntry: Identifiable {
    let id = UUID()
    let path: String
    let status: CollectionStatus
    let message: String
}

enum CollectionError: LocalizedError {
    case noProjectData
    case invalidOutputDirectory
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .noProjectData:
            return "No project data available for this session"
        case .invalidOutputDirectory:
            return "Invalid output directory"
        case .copyFailed(let message):
            return "Copy failed: \(message)"
        }
    }
}
