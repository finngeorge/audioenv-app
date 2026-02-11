import Foundation
import Compression

/// S3 backup destination with multipart upload support for large plugin bundles
/// Requires AWS SDK (via Swift Package Manager or REST API calls)
@MainActor
class S3BackupDestination: BackupDestination, ObservableObject {

    // MARK: - Configuration

    private let bucketName: String
    private let region: String
    private let accessKeyId: String
    private let secretAccessKey: String
    private let baseURL: String

    /// Multipart upload threshold (5 MB minimum per AWS spec, but we use higher for efficiency)
    private let multipartThreshold: Int64 = 100 * 1024 * 1024 // 100 MB
    private let partSize: Int64 = 50 * 1024 * 1024 // 50 MB per part

    @Published var currentUpload: String?
    @Published var uploadSpeed: Double = 0 // bytes per second

    // MARK: - BackupDestination Protocol

    var displayName: String {
        "S3 - \(bucketName)"
    }

    init(bucketName: String, region: String = "us-west-2", credentials: (accessKeyId: String, secretAccessKey: String)) {
        self.bucketName = bucketName
        self.region = region
        self.accessKeyId = credentials.accessKeyId
        self.secretAccessKey = credentials.secretAccessKey
        self.baseURL = "https://\(bucketName).s3.\(region).amazonaws.com"
    }

    // MARK: - Upload Methods

    /// Uploads a plugin bundle to S3
    /// For bundles, we zip them first, then upload
    func upload(localPath: String, remotePath: String) async throws {
        guard FileManager.default.fileExists(atPath: localPath) else {
            throw BackupError.fileNotFound(localPath)
        }

        // Check if it's a bundle (directory)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: localPath, isDirectory: &isDirectory)

        let fileToUpload: String
        let shouldCleanup: Bool

        if isDirectory.boolValue {
            // Zip the bundle in a temporary location
            let tempZip = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".zip")
                .path

            try await zipBundle(sourcePath: localPath, destinationPath: tempZip)
            fileToUpload = tempZip
            shouldCleanup = true
        } else {
            fileToUpload = localPath
            shouldCleanup = false
        }

        defer {
            if shouldCleanup {
                try? FileManager.default.removeItem(atPath: fileToUpload)
            }
        }

        // Get file size
        let attrs = try FileManager.default.attributesOfItem(atPath: fileToUpload)
        guard let fileSize = attrs[.size] as? Int64 else {
            throw BackupError.cannotDetermineSize
        }

        // Choose upload method based on size
        if fileSize > multipartThreshold {
            try await multipartUpload(filePath: fileToUpload, remotePath: remotePath, fileSize: fileSize)
        } else {
            try await simpleUpload(filePath: fileToUpload, remotePath: remotePath)
        }
    }

    /// Simple PUT upload for smaller files
    private func simpleUpload(filePath: String, remotePath: String) async throws {
        let url = URL(string: "\(baseURL)/\(remotePath)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        // Read file data
        let fileData = try Data(contentsOf: URL(fileURLWithPath: filePath))

        // Sign request (AWS Signature V4)
        signRequest(&request, method: "PUT", path: remotePath, body: fileData)

        // Upload
        let (_, response) = try await URLSession.shared.upload(for: request, from: fileData)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw BackupError.uploadFailed(response)
        }
    }

    /// Multipart upload for large files (>100 MB)
    private func multipartUpload(filePath: String, remotePath: String, fileSize: Int64) async throws {
        // Step 1: Initiate multipart upload
        let uploadId = try await initiateMultipartUpload(remotePath: remotePath)

        // Step 2: Upload parts
        let partCount = Int(ceil(Double(fileSize) / Double(partSize)))
        var uploadedParts: [(partNumber: Int, etag: String)] = []

        let fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        defer { try? fileHandle.close() }

        for partNumber in 1...partCount {
            let offset = Int64(partNumber - 1) * partSize
            let length = min(partSize, fileSize - offset)

            try fileHandle.seek(toOffset: UInt64(offset))
            let partData = fileHandle.readData(ofLength: Int(length))

            let etag = try await uploadPart(
                remotePath: remotePath,
                uploadId: uploadId,
                partNumber: partNumber,
                data: partData
            )

            uploadedParts.append((partNumber, etag))

            // Update progress (would be passed to BackupService)
            await MainActor.run {
                let progress = Double(partNumber) / Double(partCount)
                print("Uploaded part \(partNumber)/\(partCount) (\(Int(progress * 100))%)")
            }
        }

        // Step 3: Complete multipart upload
        try await completeMultipartUpload(remotePath: remotePath, uploadId: uploadId, parts: uploadedParts)
    }

    // MARK: - S3 Multipart API Calls

    private func initiateMultipartUpload(remotePath: String) async throws -> String {
        let url = URL(string: "\(baseURL)/\(remotePath)?uploads")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        signRequest(&request, method: "POST", path: remotePath + "?uploads", body: Data())

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw BackupError.uploadFailed(response)
        }

        // Parse XML response to get UploadId
        // Simplified - would use XMLParser or XMLDocument
        guard let xmlString = String(data: data, encoding: .utf8),
              let uploadId = extractUploadId(from: xmlString) else {
            throw BackupError.invalidResponse
        }

        return uploadId
    }

    private func uploadPart(remotePath: String, uploadId: String, partNumber: Int, data: Data) async throws -> String {
        let url = URL(string: "\(baseURL)/\(remotePath)?partNumber=\(partNumber)&uploadId=\(uploadId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        signRequest(&request, method: "PUT", path: remotePath + "?partNumber=\(partNumber)&uploadId=\(uploadId)", body: data)

        let (_, response) = try await URLSession.shared.upload(for: request, from: data)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let etag = httpResponse.value(forHTTPHeaderField: "ETag") else {
            throw BackupError.uploadFailed(response)
        }

        return etag
    }

    private func completeMultipartUpload(remotePath: String, uploadId: String, parts: [(partNumber: Int, etag: String)]) async throws {
        let url = URL(string: "\(baseURL)/\(remotePath)?uploadId=\(uploadId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Build XML body
        var xml = "<CompleteMultipartUpload>"
        for part in parts {
            xml += "<Part><PartNumber>\(part.partNumber)</PartNumber><ETag>\(part.etag)</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"

        let bodyData = xml.data(using: .utf8)!
        signRequest(&request, method: "POST", path: remotePath + "?uploadId=\(uploadId)", body: bodyData)

        let (_, response) = try await URLSession.shared.upload(for: request, from: bodyData)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw BackupError.uploadFailed(response)
        }
    }

    // MARK: - List and Delete

    func list(prefix: String) async throws -> [RemoteObject] {
        let url = URL(string: "\(baseURL)?list-type=2&prefix=\(prefix)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        signRequest(&request, method: "GET", path: "?list-type=2&prefix=\(prefix)", body: Data())

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw BackupError.listFailed(response)
        }

        // Parse XML response (simplified)
        let xmlString = String(data: data, encoding: .utf8) ?? ""
        return parseListResponse(xmlString)
    }

    func delete(key: String) async throws {
        let url = URL(string: "\(baseURL)/\(key)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        signRequest(&request, method: "DELETE", path: key, body: Data())

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw BackupError.deleteFailed(response)
        }
    }

    // MARK: - Helpers

    /// Zips a plugin bundle to a temporary file
    private func zipBundle(sourcePath: String, destinationPath: String) async throws {
        // Use ditto or zip command for macOS
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", sourcePath, destinationPath]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw BackupError.compressionFailed
        }
    }

    /// AWS Signature V4 signing (simplified - would use crypto framework)
    private func signRequest(_ request: inout URLRequest, method: String, path: String, body: Data) {
        // This is a simplified placeholder
        // Real implementation would use HMAC-SHA256 for AWS Signature V4
        // Or use AWS SDK which handles this automatically

        let timestamp = ISO8601DateFormatter().string(from: Date())
        request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        request.setValue("AWS4-HMAC-SHA256 ...", forHTTPHeaderField: "Authorization")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    }

    private func extractUploadId(from xml: String) -> String? {
        // Simplified XML parsing
        let pattern = "<UploadId>(.*?)</UploadId>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return String(xml[range])
    }

    private func parseListResponse(_ xml: String) -> [RemoteObject] {
        // Simplified - would use XMLParser for production
        var objects: [RemoteObject] = []

        let pattern = "<Key>(.*?)</Key>.*?<Size>(\\d+)</Size>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) {
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            for match in matches {
                if let keyRange = Range(match.range(at: 1), in: xml),
                   let sizeRange = Range(match.range(at: 2), in: xml),
                   let size = Int64(xml[sizeRange]) {
                    objects.append(RemoteObject(
                        key: String(xml[keyRange]),
                        size: size,
                        lastModified: Date()
                    ))
                }
            }
        }

        return objects
    }
}

// MARK: - Errors

enum BackupError: Error, LocalizedError {
    case fileNotFound(String)
    case cannotDetermineSize
    case uploadFailed(URLResponse)
    case listFailed(URLResponse)
    case deleteFailed(URLResponse)
    case compressionFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .cannotDetermineSize:
            return "Cannot determine file size"
        case .uploadFailed(let response):
            return "Upload failed: \(response)"
        case .listFailed(let response):
            return "List failed: \(response)"
        case .deleteFailed(let response):
            return "Delete failed: \(response)"
        case .compressionFailed:
            return "Failed to compress plugin bundle"
        case .invalidResponse:
            return "Invalid response from S3"
        }
    }
}
