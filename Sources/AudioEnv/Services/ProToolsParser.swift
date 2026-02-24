import Foundation
import os

enum ProToolsParser {
    private static let logger = Logger(subsystem: "com.audioenv", category: "ProToolsParser")

    private static let audioExtensions: Set<String> = [
        "wav", "aiff", "aif", "mp3", "m4a", "caf", "flac", "alac"
    ]
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "mxf", "avi"
    ]

    private static let maxFilesPerDirectory = 500

    // MARK: - Entry Points

    static func parse(path: String) -> ProToolsProject? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return parse(data: data, path: path)
    }

    static func parse(data: Data, path: String) -> ProToolsProject? {
        let start = CFAbsoluteTimeGetCurrent()

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? UInt64) ?? UInt64(data.count)

        let reader = BinaryReader(data: data)

        // 1) Header, paths, settings (from raw data)
        let header = parseHeader(reader: reader)

        // 2) Tracks and clips (from raw data)
        let (tracks, clips) = parseContentEntries(data: data)

        // 3) Decode entire file (XOR page rotation)
        let decoded = decodePTX(data: data)
        let bodyStart = 0x0F00

        // 4) Extract plugins using structural 5A container tree
        var mutableTracks = tracks
        extractPluginsStructural(decoded: decoded, bodyStart: bodyStart, tracks: &mutableTracks)

        // 5) Extract plugin catalog
        var pluginCatalog = extractPluginCatalog(decoded: decoded, bodyStart: bodyStart)

        // 6) Check which plugins are installed locally
        let installedIds = scanInstalledAAXPlugins()
        if !installedIds.isEmpty {
            markInstalledStatus(tracks: &mutableTracks, catalog: &pluginCatalog, installedIds: installedIds)
        }

        // 7) Sample rate from audio files
        let root = projectRoot(for: path)
        let audioDir = root.appendingPathComponent("Audio Files")
        let (sampleRate, bitDepth) = detectRateFromAudio(audioDir: audioDir.path)

        // 8) File discovery
        let audioFiles = discoverFiles(in: root.appendingPathComponent("Audio Files"), extensions: audioExtensions)
        let bouncedFiles = discoverFiles(in: root.appendingPathComponent("Bounced Files"), extensions: audioExtensions)
        let videoFiles = discoverFiles(in: root.appendingPathComponent("Video Files"), extensions: videoExtensions)
        let renderedFiles = discoverFiles(in: root.appendingPathComponent("Rendered Files"), extensions: audioExtensions)

        // Build session path
        let sessionPath: String
        if header.pathComponents.count > 1 {
            sessionPath = "/" + header.pathComponents.dropFirst().joined(separator: "/") + "/" + header.sessionDirName
        } else {
            sessionPath = ""
        }

        let prevPath: String?
        if let prevComps = header.prevPathComponents, prevComps.count > 1, let prevDir = header.prevSessionDirName {
            prevPath = "/" + prevComps.dropFirst().joined(separator: "/") + "/" + prevDir
        } else {
            prevPath = nil
        }

        let sessionFilename = header.sessionFilename
        let sessionName: String
        if !sessionFilename.isEmpty, let dotIdx = sessionFilename.lastIndex(of: ".") {
            sessionName = String(sessionFilename[..<dotIdx])
        } else {
            sessionName = header.sessionDirName
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        logger.info("Parsed \(path, privacy: .public) in \(elapsed, format: .fixed(precision: 3))s (tracks=\(mutableTracks.count), plugins=\(pluginCatalog.count), clips=\(clips.count))")

        return ProToolsProject(
            headerVersion: header.version,
            byteLength: size,
            sessionName: sessionName,
            sessionFilename: sessionFilename,
            volumeName: header.volumeName,
            sessionPath: sessionPath,
            prevSessionFilename: header.prevSessionFilename,
            prevSessionPath: prevPath,
            sampleRate: sampleRate > 0 ? sampleRate : nil,
            bitDepth: bitDepth > 0 ? bitDepth : nil,
            tracks: mutableTracks,
            audioClips: clips,
            pluginCatalog: pluginCatalog,
            audioFiles: audioFiles,
            bouncedFiles: bouncedFiles,
            videoFiles: videoFiles,
            renderedFiles: renderedFiles,
            projectRootPath: root.path
        )
    }

    // MARK: - Binary Reader

    private final class BinaryReader {
        let data: Data
        var pos: Int
        let length: Int

        init(data: Data) {
            self.data = data
            self.pos = 0
            self.length = data.count
        }

        var remaining: Int { length - pos }

        func seek(_ offset: Int) {
            pos = min(offset, length)
        }

        func skip(_ n: Int) {
            pos = min(pos + n, length)
        }

        func peek(_ n: Int) -> Data {
            let end = min(pos + n, length)
            return data[pos..<end]
        }

        func readBytes(_ n: Int) -> Data {
            let end = min(pos + n, length)
            let result = data[pos..<end]
            pos = end
            return result
        }

        func readU8() -> UInt8 {
            guard pos < length else { return 0 }
            let val = data[data.startIndex + pos]
            pos += 1
            return val
        }

        func readU16() -> UInt16 {
            guard pos + 2 <= length else { return 0 }
            let val = data.withUnsafeBytes { raw -> UInt16 in
                raw.loadUnaligned(fromByteOffset: pos, as: UInt16.self)
            }
            pos += 2
            return UInt16(littleEndian: val)
        }

        func readU32() -> UInt32 {
            guard pos + 4 <= length else { return 0 }
            let val = data.withUnsafeBytes { raw -> UInt32 in
                raw.loadUnaligned(fromByteOffset: pos, as: UInt32.self)
            }
            pos += 4
            return UInt32(littleEndian: val)
        }

        func readString() -> String {
            let length = Int(readU32())
            if length == 0 || length > 4096 { return "" }
            let raw = readBytes(length)
            return String(data: raw, encoding: .ascii) ?? String(data: raw, encoding: .utf8) ?? ""
        }
    }

    // MARK: - Constants

    private static let entryMarker: [UInt8] = [0x2A, 0x00, 0x00, 0x00]
    private static let markerLen = 4
    private static let uidLen = 8

    // MARK: - XOR Decoding

    private static func decodePTX(data: Data) -> Data {
        var result = data
        let pageSize = 4096
        let numPages = (data.count + pageSize - 1) / pageSize

        result.withUnsafeMutableBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            for page in 1..<numPages {
                let key = UInt8((page * 0xB1) & 0xFF)
                if key == 0 { continue }
                let start = page * pageSize
                let end = min(start + pageSize, data.count)
                for i in start..<end {
                    ptr[i] ^= key
                }
            }
        }
        return result
    }

    // MARK: - 5A TLV Container Parser

    private struct Tag5A {
        let tagType: UInt8
        let subtag: UInt16
        let payloadStart: Int
        let containerEnd: Int
        let tagOffset: Int
    }

    private static func parse5ATag(data: Data, offset: Int) -> Tag5A? {
        guard offset + 9 <= data.count else { return nil }
        return data.withUnsafeBytes { raw -> Tag5A? in
            let ptr = raw.bindMemory(to: UInt8.self)
            guard ptr[offset] == 0x5A else { return nil }
            guard ptr[offset + 2] == 0x00 else { return nil }
            let tagType = ptr[offset + 1]
            let length = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 3, as: UInt32.self)))
            guard length >= 2, offset + 7 + length <= data.count else { return nil }
            let subtag = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 7, as: UInt16.self))
            return Tag5A(tagType: tagType, subtag: subtag, payloadStart: offset + 9, containerEnd: offset + 7 + length, tagOffset: offset)
        }
    }

    private static func find5AChildren(data: Data, start: Int, end: Int) -> [Tag5A] {
        var children: [Tag5A] = []
        var pos = start
        while pos < end - 8 {
            guard data.withUnsafeBytes({ $0.bindMemory(to: UInt8.self)[pos] }) == 0x5A else {
                pos += 1
                continue
            }
            guard let tag = parse5ATag(data: data, offset: pos), tag.containerEnd <= end else {
                pos += 1
                continue
            }
            children.append(tag)
            pos = tag.containerEnd
        }
        return children
    }

    private static func find5ABySubtag(data: Data, start: Int, end: Int, targetSubtag: UInt16) -> [Tag5A] {
        find5AChildren(data: data, start: start, end: end).filter { $0.subtag == targetSubtag }
    }

    private static func drillToSubtag(data: Data, start: Int, end: Int, chain: [UInt16]) -> [(Int, Int)] {
        var currentRanges = [(start, end)]
        for subtag in chain {
            var nextRanges: [(Int, Int)] = []
            for (s, e) in currentRanges {
                for child in find5ABySubtag(data: data, start: s, end: e, targetSubtag: subtag) {
                    nextRanges.append((child.payloadStart, child.containerEnd))
                }
            }
            currentRanges = nextRanges
            if currentRanges.isEmpty { return [] }
        }
        return currentRanges
    }

    // MARK: - Header Parsing

    private struct ParsedHeader {
        var version: String = ""
        var volumeName: String = ""
        var pathComponents: [String] = []
        var sessionDirName: String = ""
        var sessionFilename: String = ""
        var prevSessionFilename: String? = nil
        var prevSessionDirName: String? = nil
        var prevPathComponents: [String]? = nil
    }

    private static func findAllMarkers(data: Data) -> [Int] {
        var positions: [Int] = []
        let count = data.count
        guard count >= 4 else { return positions }
        data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i <= count - 4 {
                if ptr[i] == 0x2A && ptr[i+1] == 0x00 && ptr[i+2] == 0x00 && ptr[i+3] == 0x00 {
                    positions.append(i)
                }
                i += 1
            }
        }
        return positions
    }

    private static func parseHeader(reader: BinaryReader) -> ParsedHeader {
        var header = ParsedHeader()

        // Version string
        reader.seek(0)
        _ = reader.readU8()  // type byte (0x03)
        let versionData = reader.readBytes(16)
        header.version = String(data: versionData, encoding: .ascii)?
            .replacingOccurrences(of: "\0", with: "") ?? ""

        let markerPositions = findAllMarkers(data: reader.data)
        guard markerPositions.count >= 2 else { return header }

        let firstMarker = markerPositions[0]
        let secondMarker = markerPositions[1]

        let scanStart = firstMarker + markerLen + uidLen + 20
        let scanEnd = secondMarker

        // Current session path
        reader.data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            for absOff in scanStart..<max(scanStart, scanEnd - 8) {
                guard absOff + 8 <= reader.data.count else { break }
                let count = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: absOff, as: UInt32.self)))
                guard 3 <= count && count <= 20 else { continue }
                let nextLen = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: absOff + 4, as: UInt32.self)))
                guard 1 <= nextLen && nextLen <= 64 && absOff + 8 + nextLen <= reader.data.count else { continue }
                let allPrintable = (0..<nextLen).allSatisfy { ptr[absOff + 8 + $0] >= 32 && ptr[absOff + 8 + $0] <= 126 }
                guard allPrintable else { continue }

                reader.seek(absOff)
                let pathCount = Int(reader.readU32())
                var allStrings: [String] = []
                for _ in 0..<pathCount {
                    allStrings.append(reader.readString())
                }
                header.sessionFilename = reader.readString()
                if !allStrings.isEmpty {
                    header.sessionDirName = allStrings.last!.trimmingCharacters(in: .whitespaces)
                    header.pathComponents = Array(allStrings.dropLast())
                    if let first = header.pathComponents.first {
                        header.volumeName = first
                    }
                }
                break
            }
        }

        // Previous session path (second marker block)
        if markerPositions.count >= 2 {
            reader.seek(markerPositions[1] + markerLen + uidLen)
            let prevCount = Int(reader.readU32())
            if 3 <= prevCount && prevCount <= 20 {
                var allStrings: [String] = []
                for _ in 0..<prevCount {
                    allStrings.append(reader.readString())
                }
                if allStrings.count >= 2 {
                    header.prevSessionFilename = allStrings.last
                    header.prevSessionDirName = allStrings[allStrings.count - 2].trimmingCharacters(in: .whitespaces)
                    if allStrings.count > 2 {
                        header.prevPathComponents = Array(allStrings.dropLast(2))
                    }
                }
            }
        }

        return header
    }

    // MARK: - Content Entry Parsing (Tracks + Clips)

    private static let markerTypeMap: [UInt8: String] = [
        0x05: "master",
        0x0B: "folder",
    ]

    private static func readEntryString(data: Data, afterUidOffset: Int) -> (name: String, flags: Data, endOffset: Int)? {
        return data.withUnsafeBytes { raw -> (String, Data, Int)? in
            let ptr = raw.bindMemory(to: UInt8.self)
            for delta in 0..<20 {
                let off = afterUidOffset + delta
                guard off + 4 < data.count else { break }
                let slen = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)))
                guard 1 <= slen && slen <= 512 && off + 4 + slen <= data.count else { continue }
                let allPrintable = (0..<slen).allSatisfy { ptr[off + 4 + $0] >= 32 && ptr[off + 4 + $0] <= 126 }
                guard allPrintable else { continue }
                let name = String(bytes: UnsafeBufferPointer(start: ptr.baseAddress! + off + 4, count: slen), encoding: .ascii) ?? ""
                guard !name.isEmpty else { continue }
                let flags = data[afterUidOffset..<(afterUidOffset + delta)]
                return (name, flags, off + 4 + slen)
            }
            return nil
        }
    }

    private static func isClipName(_ name: String) -> Bool {
        let clipExtensions = [".DA", ".wav", ".aif", ".aiff", ".WAV", ".AIF"]
        for ext in clipExtensions {
            if name.contains(ext) { return true }
        }
        if name.contains(".dup") { return true }
        if let dotIdx = name.lastIndex(of: ".") {
            let afterDot = String(name[name.index(after: dotIdx)...])
            if afterDot.allSatisfy({ $0.isNumber }) && !afterDot.isEmpty { return true }
        }
        if name.contains("-01.") || name.contains("_1-") { return true }
        return false
    }

    private static func inferTrackType(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("master") { return "master" }
        if lower.contains("click") { return "click" }
        let auxKeywords = ["aux", "reverb", "delay", "bus", "verb"]
        if auxKeywords.contains(where: { lower.contains($0) }) { return "aux" }
        return "audio"
    }

    private static func isValidTrackName(_ name: String) -> Bool {
        let stripped = name.trimmingCharacters(in: .whitespaces)
        guard stripped.count >= 2 else { return false }
        return stripped.allSatisfy { $0.asciiValue != nil && $0.asciiValue! <= 126 }
    }

    private static func parseContentEntries(data: Data) -> ([PTTrack], [PTAudioClip]) {
        let markerPositions = findAllMarkers(data: data)
        guard markerPositions.count >= 4 else { return ([], []) }

        var tracks: [PTTrack] = []
        var clips: [PTAudioClip] = []
        var seenNames: Set<String> = []
        var clipNames: Set<String> = []

        for mPos in markerPositions[3...] {
            let afterUid = mPos + markerLen + uidLen
            guard let entry = readEntryString(data: data, afterUidOffset: afterUid) else { continue }

            let flags = entry.flags
            let markerTypeByte: UInt8 = flags.count >= 4 ? flags[flags.startIndex + 3] : 0xFF
            let isStereo = markerTypeByte == 0x02 || markerTypeByte == 0x05 || markerTypeByte == 0x0B

            let trackType: String
            if let mappedType = markerTypeMap[markerTypeByte] {
                trackType = mappedType
            } else {
                trackType = inferTrackType(entry.name)
            }

            if isClipName(entry.name) {
                if !clipNames.contains(entry.name) {
                    clipNames.insert(entry.name)
                    clips.append(PTAudioClip(name: entry.name, index: clips.count))
                }
                continue
            }

            guard !seenNames.contains(entry.name) else { continue }
            guard isValidTrackName(entry.name) else { continue }
            guard !entry.name.hasPrefix("Info #") else { continue }

            seenNames.insert(entry.name)
            tracks.append(PTTrack(
                name: entry.name,
                index: tracks.count,
                isStereo: isStereo,
                trackType: trackType,
                plugins: []
            ))
        }

        return (tracks, clips)
    }

    // MARK: - Plugin Constants

    private static let insertCodeMap: [String: (String, String)] = {
        var map: [String: (String, String)] = [:]
        let entries: [(String, String, String, String)] = [
            ("UADx", "U3DY", "com.uaudio.effects.U3DY", "UADx 1176 FET Compressor"),
            ("UADx", "U3BU", "com.uaudio.effects.U3BU", "UADx API 2500 Bus Compressor"),
            ("UADx", "U39N", "com.uaudio.effects.U39N", "UADx Lexicon 224 Digital Reverb"),
            ("UADx", "U3BY", "com.uaudio.effects.U3BY", "UADx SSL G Bus Compressor"),
            ("Digi", "clik", "com.avid.aax.sdk.megaclick", "Click II"),
            ("Digi", "Trim", "com.avid.aax.trim", "Trim"),
            ("FabF", "FQ3p", "com.fabfilter.Pro-Q.3.AAX", "FabFilter Pro-Q 3"),
            ("FabF", "FPGr", "com.fabfilter.Pro-G.1.AAX", "FabFilter Pro-G"),
            ("oDin", "uber", "com.ValhallaDSP.ValhallaUberMod", "Valhalla UberMod"),
            ("oDin", "dLay", "com.ValhallaDSP.ValhallaDelay", "Valhalla Delay"),
            ("Wzoo", "DynD", "com.air.AIR Dynamic Delay", "AIR Dynamic Delay"),
            ("wave", "LA3M", "com.waves.aax.RTAS.LA3A.CLA-3A", "CLA-3A"),
            ("ksWV", "LA3A", "com.waves.aax.RTAS.LA3A.CLA-3A", "CLA-3A"),
            ("PlAl", "ASVT", "com.plugin-alliance.plugins.aax.AmpegSVTVRClassic", "Ampeg SVTVR Classic"),
            ("brwx", "AMVC", "com.plugin-alliance.plugins.aax.AmpegSVTVRClassic", "Ampeg SVTVR Classic"),
            ("SfTb", "TTCM", "com.softube.TubeTechCL1BmkII_AAX_Protect", "Tube-Tech CL 1B mk II"),
            ("sftb", "xfqy", "com.softube.TubeTechCL1BmkII_AAX_Protect", "Tube-Tech CL 1B mk II"),
        ]
        for (vendor, code, pid, name) in entries {
            map["\(vendor).\(code)"] = (pid, name)
        }
        return map
    }()

    private static let skipCodes: Set<String> = [
        "Digi.FeLP", "Digi.FelP",
    ]

    private static let knownPluginNames: [String: String] = [
        "com.uaudio.effects.U3DY": "UADx 1176 FET Compressor",
        "com.uaudio.effects.U3BU": "UADx API 2500 Bus Compressor",
        "com.uaudio.effects.U39N": "UADx Lexicon 224 Digital Reverb",
        "com.uaudio.effects.U3BY": "UADx SSL G Bus Compressor",
        "com.waves.aax.RTAS.LA3A.CLA-3A": "CLA-3A",
        "com.fabfilter.Pro-Q.3.AAX": "FabFilter Pro-Q 3",
        "com.fabfilter.Pro-G.1.AAX": "FabFilter Pro-G",
        "com.ValhallaDSP.ValhallaDelay": "Valhalla Delay",
        "com.ValhallaDSP.ValhallaUberMod": "Valhalla UberMod",
        "com.avid.aax.sdk.megaclick": "Click II",
        "com.avid.aax.trim": "Trim",
        "com.air.AIR Dynamic Delay": "AIR Dynamic Delay",
        "com.plugin-alliance.plugins.aax.AmpegSVTVRClassic": "Ampeg SVTVR Classic",
        "com.softube.TubeTechCL1BmkII_AAX_Protect": "Tube-Tech CL 1B mk II",
    ]

    private static let excludedCatalogIds: Set<String> = ["com.avid.aax.fela.2sola"]

    private static func inferManufacturer(_ pluginId: String) -> String {
        let manufacturers: [(String, String)] = [
            ("com.uaudio", "Universal Audio"),
            ("com.fabfilter", "FabFilter"),
            ("com.ValhallaDSP", "Valhalla DSP"),
            ("com.waves", "Waves"),
            ("com.softube", "Softube"),
            ("com.plugin-alliance", "Plugin Alliance"),
            ("com.avid", "Avid"),
            ("com.air", "AIR Music Technology"),
            ("com.soundtoys", "Soundtoys"),
            ("com.eventide", "Eventide"),
            ("com.izotope", "iZotope"),
            ("com.slate", "Slate Digital"),
            ("com.sonnox", "Sonnox"),
        ]
        for (prefix, mfr) in manufacturers {
            if pluginId.hasPrefix(prefix) { return mfr }
        }
        return ""
    }

    // MARK: - Structural Plugin Extraction

    private static func extractNameAndUid(data: Data, payloadStart: Int, containerEnd: Int) -> (String?, Data?) {
        guard payloadStart + 4 <= containerEnd else { return (nil, nil) }

        return data.withUnsafeBytes { raw -> (String?, Data?) in
            let ptr = raw.bindMemory(to: UInt8.self)
            let nameLen = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: payloadStart, as: UInt32.self)))
            guard nameLen >= 1, nameLen <= 512, payloadStart + 4 + nameLen <= containerEnd else { return (nil, nil) }

            let allPrintable = (0..<nameLen).allSatisfy { ptr[payloadStart + 4 + $0] >= 32 && ptr[payloadStart + 4 + $0] <= 126 }
            guard allPrintable else { return (nil, nil) }

            let name = String(bytes: UnsafeBufferPointer(start: ptr.baseAddress! + payloadStart + 4, count: nameLen), encoding: .ascii)
            guard let name else { return (nil, nil) }

            // Search backwards from end for the last 2A 00 00 00 marker + 8-byte UID
            var uid: Data? = nil
            let searchStart = payloadStart + 4 + nameLen
            for pos in stride(from: containerEnd - 12, through: searchStart, by: -1) {
                if ptr[pos] == 0x2A && ptr[pos+1] == 0x00 && ptr[pos+2] == 0x00 && ptr[pos+3] == 0x00 {
                    uid = data[pos + 4 ..< pos + 4 + 8]
                    break
                }
            }

            return (name, uid)
        }
    }

    private static func extractPluginFrom1038(data: Data, payloadStart: Int, containerEnd: Int) -> (String, String)? {
        let payloadLen = containerEnd - payloadStart
        guard payloadLen >= 24 else { return nil }

        return data.withUnsafeBytes { raw -> (String, String)? in
            let ptr = raw.bindMemory(to: UInt8.self)

            // Primary: read vendor/code at fixed offset 16/20
            let vendorOff = payloadStart + 16
            let codeOff = payloadStart + 20
            if codeOff + 4 <= containerEnd {
                let vendorOK = (0..<4).allSatisfy { ptr[vendorOff + $0] >= 32 && ptr[vendorOff + $0] <= 126 }
                let codeOK = (0..<4).allSatisfy { ptr[codeOff + $0] >= 32 && ptr[codeOff + $0] <= 126 }
                if vendorOK && codeOK {
                    let vendor = String(bytes: UnsafeBufferPointer(start: ptr.baseAddress! + vendorOff, count: 4), encoding: .ascii) ?? ""
                    let code = String(bytes: UnsafeBufferPointer(start: ptr.baseAddress! + codeOff, count: 4), encoding: .ascii) ?? ""
                    if !vendor.isEmpty && !code.isEmpty { return (vendor, code) }
                }
            }

            // Fallback: look for 'elck' marker
            let payload = data[payloadStart..<containerEnd]
            if let elckRange = payload.range(of: Data("elck".utf8)) {
                let elckPos = payload.distance(from: payload.startIndex, to: elckRange.lowerBound)
                if elckPos >= 12 {
                    let vOff = payloadStart + elckPos - 12
                    let cOff = payloadStart + elckPos - 8
                    let vendorOK = (0..<4).allSatisfy { ptr[vOff + $0] >= 32 && ptr[vOff + $0] <= 126 }
                    let codeOK = (0..<4).allSatisfy { ptr[cOff + $0] >= 32 && ptr[cOff + $0] <= 126 }
                    if vendorOK && codeOK {
                        let vendor = String(bytes: UnsafeBufferPointer(start: ptr.baseAddress! + vOff, count: 4), encoding: .ascii) ?? ""
                        let code = String(bytes: UnsafeBufferPointer(start: ptr.baseAddress! + cOff, count: 4), encoding: .ascii) ?? ""
                        if !vendor.isEmpty && !code.isEmpty { return (vendor, code) }
                    }
                }
            }

            return nil
        }
    }

    private static func extractPresetFromState(data: Data, payloadStart: Int, containerEnd: Int) -> String {
        let payload = data[payloadStart..<containerEnd]

        // Valhalla/UAD: preset_nameSi...i
        if let range = payload.range(of: Data("preset_nameSi".utf8)) {
            let afterMarker = payload.distance(from: payload.startIndex, to: range.upperBound)
            let absStart = payloadStart + afterMarker
            var end = absStart
            while end < containerEnd && data[end] != 0x69 { end += 1 }  // look for trailing 'i'
            if end > absStart && end < containerEnd {
                let presetData = data[absStart..<end]
                if let str = String(data: presetData, encoding: .ascii) {
                    let trimmed = str.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
        }

        // Waves XML: SetupName="xxx"
        if let str = String(data: payload, encoding: .ascii),
           let range = str.range(of: "SetupName=\"") {
            let afterQuote = str[range.upperBound...]
            if let endQuote = afterQuote.firstIndex(of: "\"") {
                return String(afterQuote[..<endQuote])
            }
        }

        return ""
    }

    private static func buildTrackUidTable(decoded: Data, bodyStart: Int) -> [Data: String] {
        var uidToName: [Data: String] = [:]

        for tag in find5ABySubtag(data: decoded, start: bodyStart, end: decoded.count, targetSubtag: 0x2107) {
            for child in find5ABySubtag(data: decoded, start: tag.payloadStart, end: tag.containerEnd, targetSubtag: 0x210B) {
                let (name, uid) = extractNameAndUid(data: decoded, payloadStart: child.payloadStart, containerEnd: child.containerEnd)
                if let name, let uid {
                    uidToName[uid] = name
                    continue
                }

                // Fallback scan
                decoded.withUnsafeBytes { raw in
                    let ptr = raw.bindMemory(to: UInt8.self)
                    var pos = child.payloadStart
                    while pos < child.containerEnd - 4 {
                        let slen = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: pos, as: UInt32.self)))
                        if 2 <= slen && slen <= 256 && pos + 4 + slen <= child.containerEnd {
                            let allPrintable = (0..<slen).allSatisfy { ptr[pos + 4 + $0] >= 32 && ptr[pos + 4 + $0] <= 126 }
                            if allPrintable {
                                let foundName = String(bytes: UnsafeBufferPointer(start: ptr.baseAddress! + pos + 4, count: slen), encoding: .ascii)
                                if let foundName {
                                    let restStart = pos + 4 + slen
                                    for mPos in restStart..<(child.containerEnd - 12) {
                                        if ptr[mPos] == 0x2A && ptr[mPos+1] == 0x00 && ptr[mPos+2] == 0x00 && ptr[mPos+3] == 0x00 {
                                            let foundUid = decoded[mPos + 4 ..< mPos + 4 + 8]
                                            uidToName[foundUid] = foundName
                                            break
                                        }
                                    }
                                }
                                return
                            }
                        }
                        pos += 1
                    }
                }
            }
        }

        return uidToName
    }

    private static func extractPluginsFromContainer(decoded: Data, contPayload: Int, contEnd: Int) -> [(pluginId: String, pluginName: String, presetName: String, manufacturer: String)] {
        var plugins: [(String, String, String, String)] = []

        let insertSections = drillToSubtag(data: decoded, start: contPayload, end: contEnd, chain: [0x261B, 0x2627])

        for (sectStart, sectEnd) in insertSections {
            for slot in find5ABySubtag(data: decoded, start: sectStart, end: sectEnd, targetSubtag: 0x2616) {
                // Try 0x2615 -> 0x2613 -> 0x1038
                var pluginStates = drillToSubtag(data: decoded, start: slot.payloadStart, end: slot.containerEnd, chain: [0x2615, 0x2613, 0x1038])

                // Fallback: direct 0x1038
                if pluginStates.isEmpty {
                    pluginStates = drillToSubtag(data: decoded, start: slot.payloadStart, end: slot.containerEnd, chain: [0x1038])
                }

                // Fallback: 0x2613 -> 0x1038
                if pluginStates.isEmpty {
                    pluginStates = drillToSubtag(data: decoded, start: slot.payloadStart, end: slot.containerEnd, chain: [0x2613, 0x1038])
                }

                for (psStart, psEnd) in pluginStates {
                    guard let (vendor, code) = extractPluginFrom1038(data: decoded, payloadStart: psStart, containerEnd: psEnd) else { continue }
                    let key = "\(vendor).\(code)"
                    guard !skipCodes.contains(key) else { continue }

                    let pluginId: String
                    let pluginName: String
                    if let info = insertCodeMap[key] {
                        pluginId = info.0
                        pluginName = info.1
                    } else {
                        pluginId = key
                        pluginName = "\(vendor) \(code)"
                    }

                    let presetName = extractPresetFromState(data: decoded, payloadStart: psStart, containerEnd: psEnd)
                    let manufacturer = inferManufacturer(pluginId)

                    plugins.append((pluginId, pluginName, presetName, manufacturer))
                }
            }
        }

        return plugins
    }

    private static func extractPluginsStructural(decoded: Data, bodyStart: Int, tracks: inout [PTTrack]) {
        let uidToName = buildTrackUidTable(decoded: decoded, bodyStart: bodyStart)
        var trackByName: [String: Int] = [:]
        for (i, t) in tracks.enumerated() {
            trackByName[t.name] = i
            let stripped = t.name.trimmingCharacters(in: .whitespaces)
            if stripped != t.name { trackByName[stripped] = i }
        }

        let rootContainers = find5ABySubtag(data: decoded, start: bodyStart, end: decoded.count, targetSubtag: 0x2624)
        guard !rootContainers.isEmpty else { return }

        for root in rootContainers {
            // Process 0x261E (track containers) and 0x261D (master containers)
            for subtag: UInt16 in [0x261E, 0x261D] {
                for cont in find5ABySubtag(data: decoded, start: root.payloadStart, end: root.containerEnd, targetSubtag: subtag) {
                    let nameEntries = drillToSubtag(data: decoded, start: cont.payloadStart, end: cont.containerEnd, chain: [0x261B, 0x102D, 0x2619])
                    var trackName: String? = nil
                    for (neStart, neEnd) in nameEntries {
                        let (name, _) = extractNameAndUid(data: decoded, payloadStart: neStart, containerEnd: neEnd)
                        if let name {
                            trackName = name.trimmingCharacters(in: .whitespaces)
                            break
                        }
                    }
                    guard let trackName else { continue }
                    guard let trackIdx = trackByName[trackName] else { continue }

                    let plugins = extractPluginsFromContainer(decoded: decoded, contPayload: cont.payloadStart, contEnd: cont.containerEnd)
                    for (pluginId, pluginName, presetName, manufacturer) in plugins {
                        if !tracks[trackIdx].plugins.contains(where: { $0.pluginId == pluginId }) {
                            tracks[trackIdx].plugins.append(PTPluginInsert(
                                name: pluginName, pluginId: pluginId, presetName: presetName,
                                manufacturer: manufacturer, isInstalled: true
                            ))
                        }
                    }
                }
            }

            // Process 0x261C (clip containers) — UID->track
            for cont in find5ABySubtag(data: decoded, start: root.payloadStart, end: root.containerEnd, targetSubtag: 0x261C) {
                let nameEntries = drillToSubtag(data: decoded, start: cont.payloadStart, end: cont.containerEnd, chain: [0x261B, 0x102D, 0x2619])
                var clipUid: Data? = nil
                for (neStart, neEnd) in nameEntries {
                    let (_, uid) = extractNameAndUid(data: decoded, payloadStart: neStart, containerEnd: neEnd)
                    if let uid {
                        clipUid = uid
                        break
                    }
                }
                guard let clipUid else { continue }
                guard let trackName = uidToName[clipUid] else { continue }
                let resolvedName = trackByName[trackName] != nil ? trackName : trackName.trimmingCharacters(in: .whitespaces)
                guard let trackIdx = trackByName[resolvedName] else { continue }

                let plugins = extractPluginsFromContainer(decoded: decoded, contPayload: cont.payloadStart, contEnd: cont.containerEnd)
                for (pluginId, pluginName, presetName, manufacturer) in plugins {
                    if !tracks[trackIdx].plugins.contains(where: { $0.pluginId == pluginId }) {
                        tracks[trackIdx].plugins.append(PTPluginInsert(
                            name: pluginName, pluginId: pluginId, presetName: presetName,
                            manufacturer: manufacturer, isInstalled: true
                        ))
                    }
                }
            }
        }
    }

    // MARK: - Plugin Catalog

    private static func extractPluginDisplayName(decoded: Data, idOffset: Int) -> String {
        let searchStart = max(0, idOffset - 200)
        let region = decoded[searchStart..<idOffset]
        var bestName = ""

        region.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            let len = region.count
            var pos = 0
            while pos < len - 4 {
                let slen = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: pos, as: UInt32.self)))
                if 3 <= slen && slen <= 80 && pos + 4 + slen <= len {
                    let allPrintable = (0..<slen).allSatisfy { ptr[pos + 4 + $0] >= 32 && ptr[pos + 4 + $0] <= 126 }
                    if allPrintable {
                        let name = String(bytes: UnsafeBufferPointer(start: ptr.baseAddress! + pos + 4, count: slen), encoding: .ascii) ?? ""
                        if name.count > bestName.count && !name.hasPrefix("com.") {
                            bestName = name
                        }
                        pos += 4 + slen
                    } else {
                        pos += 1
                    }
                } else {
                    pos += 1
                }
            }
        }

        return bestName
    }

    private static func extractPluginCatalog(decoded: Data, bodyStart: Int) -> [PTPluginInsert] {
        var plugins: [PTPluginInsert] = []
        var seenIds: Set<String> = []

        guard let bodyStr = String(data: decoded[bodyStart...], encoding: .ascii) else { return plugins }

        // Use simple scanning for com.xxx patterns
        let pattern = try! NSRegularExpression(pattern: #"(com\.[a-zA-Z0-9][a-zA-Z0-9 ._-]{4,80})"#)
        let nsString = bodyStr as NSString
        let matches = pattern.matches(in: bodyStr, range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            let rawPid = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !excludedCatalogIds.contains(rawPid), !seenIds.contains(rawPid) else { continue }
            seenIds.insert(rawPid)

            var name = knownPluginNames[rawPid] ?? ""
            if name.isEmpty {
                let idOffset = bodyStart + match.range.location
                name = extractPluginDisplayName(decoded: decoded, idOffset: idOffset)
            }
            if name.isEmpty {
                name = rawPid.split(separator: ".").last.map(String.init) ?? rawPid
            }

            let manufacturer = inferManufacturer(rawPid)
            plugins.append(PTPluginInsert(
                name: name, pluginId: rawPid, presetName: "",
                manufacturer: manufacturer, isInstalled: true
            ))
        }

        return plugins
    }

    // MARK: - AAX Plugin Installation Check

    private static let aaxPluginDir = "/Library/Application Support/Avid/Audio/Plug-Ins"

    private static func scanInstalledAAXPlugins() -> Set<String> {
        var installedIds: Set<String> = []
        let fm = FileManager.default
        guard fm.fileExists(atPath: aaxPluginDir) else { return installedIds }

        guard let enumerator = fm.enumerator(atPath: aaxPluginDir) else { return installedIds }
        while let path = enumerator.nextObject() as? String {
            if path.hasSuffix(".aaxplugin") {
                let plistPath = (aaxPluginDir as NSString).appendingPathComponent(path + "/Contents/Info.plist")
                if let plistData = fm.contents(atPath: plistPath),
                   let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
                   let bid = plist["CFBundleIdentifier"] as? String {
                    installedIds.insert(bid)
                }
                enumerator.skipDescendants()
            }
        }
        return installedIds
    }

    private static let bundleAliases: [String: [String]] = [
        "com.avid.aax.sdk.megaclick": ["com.AVID.plugin.ClickII"],
        "com.avid.aax.trim": ["com.AVID.plugin.Trim"],
        "com.air.AIR Dynamic Delay": ["com.wizoo.AIR Dynamic Delay"],
    ]

    private static func markInstalledStatus(tracks: inout [PTTrack], catalog: inout [PTPluginInsert], installedIds: Set<String>) {
        var expanded = installedIds
        let hasWaveshell = installedIds.contains { $0.hasPrefix("com.WavesAudio.WaveShell") }

        for (sessionId, aliases) in bundleAliases {
            for alias in aliases {
                if installedIds.contains(alias) { expanded.insert(sessionId) }
            }
        }

        func isInstalled(_ pid: String) -> Bool {
            if expanded.contains(pid) { return true }
            if hasWaveshell && pid.hasPrefix("com.waves.") { return true }
            return false
        }

        for i in catalog.indices {
            if !catalog[i].pluginId.isEmpty && !isInstalled(catalog[i].pluginId) {
                catalog[i].isInstalled = false
            }
        }
        for i in tracks.indices {
            for j in tracks[i].plugins.indices {
                if !tracks[i].plugins[j].pluginId.isEmpty && !isInstalled(tracks[i].plugins[j].pluginId) {
                    tracks[i].plugins[j].isInstalled = false
                }
            }
        }
    }

    // MARK: - Sample Rate Detection

    private static func detectRateFromAudio(audioDir: String) -> (Int, Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: audioDir),
              let files = try? fm.contentsOfDirectory(atPath: audioDir) else { return (0, 0) }

        for fname in files {
            guard fname.lowercased().hasSuffix(".wav") else { continue }
            let fpath = (audioDir as NSString).appendingPathComponent(fname)
            guard let handle = FileHandle(forReadingAtPath: fpath) else { continue }
            defer { try? handle.close() }

            guard var data = try? handle.read(upToCount: 2000) else { continue }
            var fmtIdx = data.range(of: Data("fmt ".utf8))
            if fmtIdx == nil {
                handle.seek(toFileOffset: 0)
                data = (try? handle.read(upToCount: 10000)) ?? data
                fmtIdx = data.range(of: Data("fmt ".utf8))
            }
            guard let fmtRange = fmtIdx else { continue }
            let offset = data.distance(from: data.startIndex, to: fmtRange.lowerBound)
            guard offset + 24 <= data.count else { continue }

            let sr = data.withUnsafeBytes { raw -> UInt32 in
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self))
            }
            let bits = data.withUnsafeBytes { raw -> UInt16 in
                UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 22, as: UInt16.self))
            }
            if sr >= 8000 && sr <= 384000 {
                return (Int(sr), Int(bits))
            }
        }
        return (0, 0)
    }

    // MARK: - File Discovery

    private static func projectRoot(for path: String) -> URL {
        var dir = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
        if dir.lastPathComponent.lowercased() == "session file backups" {
            dir.deleteLastPathComponent()
        }
        return dir
    }

    private static func discoverFiles(in dir: URL, extensions: Set<String>) -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path),
              let enumerator = FileManager.default.enumerator(atPath: dir.path)
        else { return [] }

        var results: [String] = []
        while let rel = enumerator.nextObject() as? String {
            let ext = (rel as NSString).pathExtension.lowercased()
            if extensions.contains(ext) {
                results.append(rel)
                if results.count >= maxFilesPerDirectory {
                    logger.warning("File enumeration capped at \(maxFilesPerDirectory) in \(dir.path, privacy: .public)")
                    break
                }
            }
        }
        return results.sorted()
    }

    // MARK: - Known-plugin matching

    static func matchKnownPlugins(in data: Data, against plugins: [AudioPlugin]) -> [PluginMatch] {
        let start = CFAbsoluteTimeGetCurrent()
        var matches: [PluginMatch] = []
        var matchedNames: Set<String> = []

        for plugin in plugins {
            guard !matchedNames.contains(plugin.name) else { continue }

            if plugin.name.count >= 4 {
                let nameData = Data(plugin.name.utf8)
                if data.range(of: nameData) != nil {
                    matches.append(PluginMatch(name: plugin.name, confidence: .nameMatch))
                    matchedNames.insert(plugin.name)
                    continue
                }
            }

            if let bundleID = plugin.bundleID, bundleID.count >= 8 {
                let bundleData = Data(bundleID.utf8)
                if data.range(of: bundleData) != nil {
                    matches.append(PluginMatch(name: plugin.name, confidence: .bundleIdMatch))
                    matchedNames.insert(plugin.name)
                }
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        logger.info("matchKnownPlugins: \(plugins.count) plugins checked in \(elapsed, format: .fixed(precision: 3))s → \(matches.count) matches")
        return matches
    }
}
