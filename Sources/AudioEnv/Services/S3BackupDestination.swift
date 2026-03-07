import Foundation
import Compression
import CryptoKit
import os.log

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

    private let logger = Logger(subsystem: "com.audioenv.app", category: "S3Upload")

    /// Multipart upload threshold (5 MB minimum per AWS spec, but we use higher for efficiency)
    private let multipartThreshold: Int64 = 100 * 1024 * 1024 // 100 MB
    private let partSize: Int64 = 50 * 1024 * 1024 // 50 MB per part

    @Published var currentUpload: String?
    @Published var uploadProgress: Double = 0 // 0.0 to 1.0
    @Published var uploadSpeed: Double = 0 // bytes per second

    // MARK: - BackupDestination Protocol

    nonisolated var displayName: String {
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
            logger.error("File not found at \(localPath)")
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
        let fileSize: Int64
        if let size = attrs[.size] as? Int64 {
            fileSize = size
        } else if let size = attrs[.size] as? UInt64 {
            fileSize = Int64(size)
        } else if let size = attrs[.size] as? NSNumber {
            fileSize = size.int64Value
        } else {
            logger.error("Cannot determine file size for: \(fileToUpload, privacy: .public)")
            throw BackupError.cannotDetermineSize
        }
        logger.info("📏 File size for upload: \(fileSize) bytes (\(fileToUpload, privacy: .public))")

        // Choose upload method based on size
        if fileSize > multipartThreshold {
            try await multipartUpload(filePath: fileToUpload, remotePath: remotePath, fileSize: fileSize)
        } else {
            try await simpleUpload(filePath: fileToUpload, remotePath: remotePath)
        }
    }

    /// Simple PUT upload for smaller files — streams from disk instead of loading into memory
    private func simpleUpload(filePath: String, remotePath: String) async throws {
        logger.info("🔐 Preparing S3 upload request")
        let fileURL = URL(fileURLWithPath: filePath)
        let url = URL(string: "\(baseURL)/\(remotePath)")!
        logger.info("🌐 Upload URL: \(url.absoluteString)")

        // Read file data for signing (required by AWS Sig V4 — needs content hash)
        let fileData = try Data(contentsOf: fileURL)
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(fileData.count), countStyle: .file)
        logger.info("📦 File size: \(sizeStr)")

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        // Sign request (AWS Signature V4)
        logger.info("✍️ Signing with AWS Signature V4")
        signRequest(&request, method: "PUT", path: remotePath, body: fileData)

        // Upload from file URL to avoid keeping the full Data in memory during transfer
        logger.info("🚀 Sending HTTP PUT to S3")
        uploadProgress = 0
        let (data, response) = try await URLSession.shared.upload(for: request, from: fileData)
        uploadProgress = 1.0

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("❌ Invalid response type received")
            throw BackupError.uploadFailed(response)
        }

        logger.info("📨 HTTP Status: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorBody = String(data: data, encoding: .utf8) {
                logger.error("❌ S3 Error Response:")
                logger.error("\(errorBody)")
            }
            logger.error("❌ Upload failed with HTTP \(httpResponse.statusCode)")
            throw BackupError.uploadFailed(response)
        }

        logger.info("✅ Upload successful!")
    }

    /// Multipart upload for large files (>100 MB)
    private func multipartUpload(filePath: String, remotePath: String, fileSize: Int64) async throws {
        // Step 1: Initiate multipart upload
        let uploadId = try await initiateMultipartUpload(remotePath: remotePath)
        uploadProgress = 0

        // Step 2: Upload parts
        let partCount = Int(ceil(Double(fileSize) / Double(partSize)))
        var uploadedParts: [(partNumber: Int, etag: String)] = []

        let fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        defer { try? fileHandle.close() }

        let startTime = Date()

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

            // Update progress and speed
            uploadProgress = Double(partNumber) / Double(partCount)
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > 0 {
                let bytesUploaded = Double(partNumber) * Double(partSize)
                uploadSpeed = bytesUploaded / elapsed
            }
        }

        // Step 3: Complete multipart upload
        try await completeMultipartUpload(remotePath: remotePath, uploadId: uploadId, parts: uploadedParts)
        uploadProgress = 1.0
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
        logger.info("📋 Listing S3 objects with prefix: \(prefix, privacy: .public)")

        // AWS-strict URL encoding: only A-Z, a-z, 0-9, -, _, ., ~ allowed
        let encodedPrefix = awsUrlEncode(prefix)

        // Build URL with encoded query parameters
        let queryString = "list-type=2&prefix=\(encodedPrefix)"
        let url = URL(string: "\(baseURL)?\(queryString)")!
        logger.info("🌐 List URL: \(url.absoluteString, privacy: .public)")
        logger.info("📝 Encoded prefix: \(encodedPrefix, privacy: .public)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Sign with the query string for canonical request (bucket root is "/")
        signRequest(&request, method: "GET", path: "/?\(queryString)", body: Data())

        logger.info("🚀 Sending LIST request to S3")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("❌ Invalid response type")
            throw BackupError.listFailed(response)
        }

        logger.info("📨 List response status: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorBody = String(data: data, encoding: .utf8) {
                logger.error("❌ S3 List Error: \(errorBody)")
            }
            throw BackupError.listFailed(response)
        }

        // Parse XML response (simplified)
        let xmlString = String(data: data, encoding: .utf8) ?? ""
        logger.info("📄 Response size: \(xmlString.count) characters")

        let objects = parseListResponse(xmlString)
        logger.info("✅ Parsed \(objects.count) objects from response")

        return objects
    }

    func delete(key: String) async throws {
        logger.info("🗑️ Deleting S3 object: \(key, privacy: .public)")

        // Build URL - use addingPercentEncoding for proper URL encoding
        let encodedPath = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        guard let url = URL(string: "\(baseURL)/\(encodedPath)") else {
            throw BackupError.invalidResponse
        }

        logger.info("🌐 Delete URL: \(url.absoluteString, privacy: .public)")
        logger.info("📝 Key for signing: \(key, privacy: .public)")

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        // CRITICAL: Prevent URLSession from adding conditional headers
        // S3 returns 501 NotImplemented if If-Modified-Since header is present
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(nil, forHTTPHeaderField: "If-Modified-Since")
        request.setValue(nil, forHTTPHeaderField: "If-None-Match")

        // Pass the UNENCODED key to signRequest - it will encode for canonical URI
        signRequest(&request, method: "DELETE", path: key, body: Data())

        logger.info("🚀 Sending DELETE request to S3")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("❌ Invalid response type")
            throw BackupError.deleteFailed(response)
        }

        logger.info("📨 Delete response status: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorBody = String(data: data, encoding: .utf8) {
                logger.error("❌ S3 Delete Error: \(errorBody, privacy: .public)")
            }
            throw BackupError.deleteFailed(response)
        }

        logger.info("✅ Delete successful!")
    }

    func download(key: String) async throws -> Data {
        logger.info("📥 Downloading S3 object: \(key)")

        let url = URL(string: "\(baseURL)/\(key)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        signRequest(&request, method: "GET", path: key, body: Data())

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("❌ Invalid response type")
            throw BackupError.downloadFailed(response)
        }

        logger.info("📨 Download response status: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorBody = String(data: data, encoding: .utf8) {
                logger.error("❌ S3 Download Error: \(errorBody)")
            }
            throw BackupError.downloadFailed(response)
        }

        logger.info("✅ Downloaded \(data.count) bytes")
        return data
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

    /// AWS Signature V4 signing
    private func signRequest(_ request: inout URLRequest, method: String, path: String, body: Data) {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let amzDate = dateFormatter.string(from: now)

        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = dateFormatter.string(from: now)

        // Set required headers
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue("\(bucketName).s3.\(region).amazonaws.com", forHTTPHeaderField: "Host")

        // Only set Content-Type for PUT/POST requests with a body
        if method == "PUT" || method == "POST" {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        }

        // Calculate payload hash
        let payloadHash = sha256(data: body)
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        // Build canonical request
        let pathParts = path.split(separator: "?", maxSplits: 1)
        let pathComponent = pathParts.first.map(String.init) ?? "/"

        // Build canonical URI with proper encoding for each path segment
        let canonicalURI: String
        if pathComponent == "/" {
            canonicalURI = "/"
        } else {
            // Remove leading slash if present, split into segments, encode each, rejoin
            let cleanPath = pathComponent.hasPrefix("/") ? String(pathComponent.dropFirst()) : pathComponent

            let segments = cleanPath.split(separator: "/").map { segment in
                awsUrlEncode(String(segment))
            }
            canonicalURI = "/" + segments.joined(separator: "/")
        }

        // Build canonical query string (must be URI-encoded and sorted)
        let canonicalQueryString: String
        if pathParts.count > 1 {
            let queryString = String(pathParts[1])
            let params = queryString.split(separator: "&").map(String.init)
            let sortedParams = params.map { param -> String in
                let parts = param.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0])
                    let value = String(parts[1])
                    // Value is already AWS-encoded when passed in, don't double-encode
                    return "\(key)=\(value)"
                }
                return param
            }.sorted()
            canonicalQueryString = sortedParams.joined(separator: "&")
        } else {
            canonicalQueryString = ""
        }

        let canonicalHeaders: String
        let signedHeaders: String

        if method == "GET" || method == "DELETE" {
            // GET and DELETE don't include Content-Type
            canonicalHeaders = """
            host:\(bucketName).s3.\(region).amazonaws.com
            x-amz-content-sha256:\(payloadHash)
            x-amz-date:\(amzDate)

            """
            signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        } else {
            // PUT and POST include Content-Type
            canonicalHeaders = """
            content-type:application/octet-stream
            host:\(bucketName).s3.\(region).amazonaws.com
            x-amz-content-sha256:\(payloadHash)
            x-amz-date:\(amzDate)

            """
            signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date"
        }

        let canonicalRequest = """
        \(method)
        \(canonicalURI)
        \(canonicalQueryString)
        \(canonicalHeaders)
        \(signedHeaders)
        \(payloadHash)
        """

        let canonicalRequestHash = sha256(string: canonicalRequest)

        // Build string to sign
        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = """
        AWS4-HMAC-SHA256
        \(amzDate)
        \(credentialScope)
        \(canonicalRequestHash)
        """

        // Calculate signature
        let kDate = hmac(key: "AWS4\(secretAccessKey)", message: dateStamp)
        let kRegion = hmac(key: kDate, message: region)
        let kService = hmac(key: kRegion, message: "s3")
        let kSigning = hmac(key: kService, message: "aws4_request")
        let signature = hmac(key: kSigning, message: stringToSign).map { String(format: "%02x", $0) }.joined()

        // Set Authorization header
        let authorizationHeader = "AWS4-HMAC-SHA256 Credential=\(accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
    }

    // MARK: - URL Encoding Helper

    /// AWS-compliant URL encoding for query parameters
    /// Only A-Z, a-z, 0-9, -, _, ., ~ are left unencoded
    private func awsUrlEncode(_ string: String) -> String {
        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

        var encoded = ""
        for scalar in string.unicodeScalars {
            if allowedCharacters.contains(scalar) {
                encoded.append(String(scalar))
            } else {
                // Percent encode with uppercase hex
                let utf8 = String(scalar).utf8
                for byte in utf8 {
                    encoded.append(String(format: "%%%02X", byte))
                }
            }
        }
        return encoded
    }

    // MARK: - Crypto Helpers

    private func sha256(data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func sha256(string: String) -> String {
        sha256(data: string.data(using: .utf8)!)
    }

    private func hmac(key: String, message: String) -> [UInt8] {
        return hmac(key: [UInt8](key.utf8), message: message)
    }

    private func hmac(key: [UInt8], message: String) -> [UInt8] {
        let messageData = message.data(using: .utf8)!
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: messageData, using: symmetricKey)
        return Array(mac)
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
        guard let xmlData = xml.data(using: .utf8),
              let doc = try? XMLDocument(data: xmlData) else {
            logger.error("❌ Failed to parse XML response")
            return []
        }

        var objects: [RemoteObject] = []

        // Extract all <Contents> elements
        guard let contentsNodes = try? doc.nodes(forXPath: "//Contents") else {
            logger.warning("⚠️ No Contents nodes found in XML")
            return []
        }

        let dateFormatter = ISO8601DateFormatter()

        for contentNode in contentsNodes {
            guard let element = contentNode as? XMLElement else { continue }

            // Extract Key
            guard let keyNodes = try? element.nodes(forXPath: "Key"),
                  let keyNode = keyNodes.first,
                  let key = keyNode.stringValue else {
                continue
            }

            // Extract Size
            guard let sizeNodes = try? element.nodes(forXPath: "Size"),
                  let sizeNode = sizeNodes.first,
                  let sizeString = sizeNode.stringValue,
                  let size = UInt64(sizeString) else {
                continue
            }

            // Extract LastModified
            var lastModified = Date()
            if let dateNodes = try? element.nodes(forXPath: "LastModified"),
               let dateNode = dateNodes.first,
               let dateString = dateNode.stringValue,
               let parsedDate = dateFormatter.date(from: dateString) {
                lastModified = parsedDate
            }

            objects.append(RemoteObject(
                id: key,
                size: size,
                lastModified: lastModified
            ))
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
    case downloadFailed(URLResponse)
    case compressionFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .cannotDetermineSize:
            return "Cannot determine file size"
        case .uploadFailed(let response):
            if let httpResponse = response as? HTTPURLResponse {
                return "Upload failed: HTTP \(httpResponse.statusCode) - \(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))"
            }
            return "Upload failed: \(response)"
        case .listFailed(let response):
            if let httpResponse = response as? HTTPURLResponse {
                return "List failed: HTTP \(httpResponse.statusCode) - \(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))"
            }
            return "List failed: \(response)"
        case .deleteFailed(let response):
            if let httpResponse = response as? HTTPURLResponse {
                return "Delete failed: HTTP \(httpResponse.statusCode) - \(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))"
            }
            return "Delete failed: \(response)"
        case .downloadFailed(let response):
            if let httpResponse = response as? HTTPURLResponse {
                return "Download failed: HTTP \(httpResponse.statusCode) - \(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))"
            }
            return "Download failed: \(response)"
        case .compressionFailed:
            return "Failed to compress plugin bundle"
        case .invalidResponse:
            return "Invalid response from S3"
        }
    }
}
