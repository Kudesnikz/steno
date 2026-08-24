import Foundation

public struct SessionStore {
    public enum FolderError: LocalizedError {
        case invalidName
        case duplicateName
        case missingFolder

        public var errorDescription: String? {
            switch self {
            case .invalidName: "Folder name cannot be empty."
            case .duplicateName: "A folder with this name already exists."
            case .missingFolder: "The recording folder no longer exists."
            }
        }
    }

    public enum ReportError: LocalizedError {
        case invalidPath

        public var errorDescription: String? {
            switch self {
            case .invalidPath: "The protocol file is outside the recordings directory."
            }
        }
    }

    public let fileManager: FileManager
    public var saveDirectory: URL

    public init(saveDirectory: URL, fileManager: FileManager = .default) {
        self.saveDirectory = saveDirectory
        self.fileManager = fileManager
    }

    public func scanSessions() -> [MeetingSession] {
        let validFolderIDs = Set(loadFolders().map(\.id))
        guard let items = try? fileManager.contentsOfDirectory(
            at: saveDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            AppLog.warning("Session directory is unavailable", category: .sessions)
            return []
        }

        let basePattern = #"^(Meet_\d{2}\.\d{2}\.\d{4}(?:_\d{2}:\d{2}:\d{2})?)"#
        var builders: [String: SessionBuilder] = [:]

        for url in items {
            let fileName = url.lastPathComponent
            guard fileName.hasPrefix("Meet_"),
                  let baseName = fileName.firstMatch(pattern: basePattern) else {
                continue
            }

            var builder = builders[baseName] ?? SessionBuilder(baseName: baseName, directory: saveDirectory)
            let escapedBaseName = NSRegularExpression.escapedPattern(for: baseName)
            let protocolPattern = "^\(NSRegularExpression.escapedPattern(for: baseName))_protocol_(.+)\\.txt$"
            let segmentVideoPattern = "^\(escapedBaseName)_part_(\\d{3})\\.mp4$"
            let segmentMicrophonePattern = "^\(escapedBaseName)_part_(\\d{3})_mic\\.m4a$"
            if fileName == "\(baseName).mp4" {
                builder.videoURL = url
            } else if let index = fileName.firstIntegerMatch(pattern: segmentVideoPattern) {
                builder.segmentVideoURLs[index] = url
            } else if let index = fileName.firstIntegerMatch(pattern: segmentMicrophonePattern) {
                builder.segmentMicrophoneURLs[index] = url
            } else if fileName == "\(baseName).json" {
                builder.metadataURL = url
            } else if fileName == "\(baseName)_protocol.txt" {
                builder.reportURLsByAgentID["default"] = url
            } else if let agentID = fileName.firstMatch(pattern: protocolPattern) {
                builder.reportURLsByAgentID[agentID] = url
            } else if ["m4a", "mp3", "wav"].contains(url.pathExtension.lowercased()), fileName.hasPrefix(baseName) {
                builder.audioURLs.append(url)
            }
            builders[baseName] = builder
        }

        let sessions: [MeetingSession] = builders.values.compactMap { builder in
            let metadataURL = builder.metadataURL ?? saveDirectory.appending(path: "\(builder.baseName).json")
            var metadata = loadMetadata(url: metadataURL)
            var didMigrateMetadata = metadata.schemaVersion != 3
            metadata.schemaVersion = 3
            if !builder.segmentVideoURLs.isEmpty,
               metadata.recording?.segments.isEmpty != false {
                let segments = builder.segmentVideoURLs.keys.sorted().compactMap { index -> RecordingSegment? in
                    guard let videoURL = builder.segmentVideoURLs[index] else { return nil }
                    let micURL = builder.segmentMicrophoneURLs[index]
                    return RecordingSegment(
                        index: index,
                        startSeconds: 0,
                        durationSeconds: 0,
                        videoPath: videoURL.lastPathComponent,
                        microphoneAudioPath: micURL?.lastPathComponent,
                        videoSizeBytes: fileSize(at: videoURL),
                        microphoneSizeBytes: micURL.map(fileSize(at:)) ?? 0
                    )
                }
                let totalVideoBytes = segments.reduce(Int64(0)) { $0 + $1.videoSizeBytes }
                let totalMicBytes = segments.reduce(Int64(0)) { $0 + $1.microphoneSizeBytes }
                metadata.recording = RecordingInfo(
                    durationSeconds: metadata.recording?.durationSeconds ?? 0,
                    videoQuality: metadata.recording?.videoQuality ?? "",
                    videoPath: segments.first?.videoPath ?? "",
                    microphoneAudioPath: segments.first?.microphoneAudioPath ?? "",
                    videoSizeMB: megabytes(totalVideoBytes),
                    microphoneSizeMB: megabytes(totalMicBytes),
                    segmented: true,
                    limitProfileID: metadata.recording?.limitProfileID,
                    stopReason: metadata.recording?.stopReason,
                    segments: segments
                )
                didMigrateMetadata = true
            }
            let metadataSegmentURLs = metadata.recording?.segments.map {
                saveDirectory.appending(path: $0.videoPath)
            } ?? []
            guard let videoURL = builder.videoURL
                ?? metadataSegmentURLs.first(where: { fileManager.fileExists(atPath: $0.path) })
                ?? builder.segmentVideoURLs.sorted(by: { $0.key < $1.key }).first?.value else {
                return nil
            }
            let mediaURLs = [videoURL]
                + builder.segmentVideoURLs.values
                + builder.segmentMicrophoneURLs.values
            let modifiedAt = mediaURLs.compactMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }.compactMap { $0 }.max() ?? .distantPast
            if metadata.source == nil {
                metadata.source = .legacy
                didMigrateMetadata = true
            }
            if let folderID = metadata.folderID, !validFolderIDs.contains(folderID) {
                metadata.folderID = nil
                didMigrateMetadata = true
            }
            if metadata.reports?.isEmpty != false, !builder.reportURLsByAgentID.isEmpty {
                metadata.reports = builder.reportURLsByAgentID.map { agentID, url in
                    ReportInfo(
                        agentID: agentID,
                        agentName: agentID,
                        model: AIModelCatalog.defaultModelID(for: .gemini),
                        providerID: AIProviderID.gemini.rawValue,
                        createdAt: ISO8601DateFormatter().string(from: modifiedAt),
                        processingDurationSeconds: 0,
                        tokens: ReportTokens(input: 0, output: 0, total: 0),
                        outputPath: url.lastPathComponent,
                        status: "success"
                    )
                }
                didMigrateMetadata = true
            } else if var reports = metadata.reports {
                for index in reports.indices {
                    let normalized = AIModelCatalog.normalizedModelID(reports[index].model)
                    if normalized != reports[index].model {
                        reports[index].model = normalized
                        didMigrateMetadata = true
                    }
                }
                metadata.reports = reports
            }
            if didMigrateMetadata {
                try? saveMetadata(metadata, to: metadataURL)
            }
            var reportURLsByID: [String: URL] = [:]
            let latestReportForOutput = Dictionary(grouping: metadata.reports ?? [], by: \.outputPath)
                .compactMap { outputPath, reports -> ReportInfo? in
                    guard !outputPath.isEmpty else { return nil }
                    return reports.max { $0.createdAt < $1.createdAt }
                }
            for report in latestReportForOutput {
                let reportURL = saveDirectory.appending(path: report.outputPath)
                guard fileManager.fileExists(atPath: reportURL.path) else {
                    continue
                }
                reportURLsByID[report.id] = reportURL
            }
            let mappedURLs = Set(reportURLsByID.values)
            var latestURLsByAgentID = builder.reportURLsByAgentID.filter { !mappedURLs.contains($0.value) }
            for report in (metadata.reports ?? []).sorted(by: { $0.createdAt < $1.createdAt }) {
                if let reportURL = reportURLsByID[report.id] {
                    latestURLsByAgentID[report.agentID] = reportURL
                }
            }
            return MeetingSession(
                baseName: builder.baseName,
                baseURL: saveDirectory.appending(path: builder.baseName),
                videoURL: videoURL,
                metadataURL: metadataURL,
                audioURLs: (builder.audioURLs + builder.segmentMicrophoneURLs.values)
                    .sorted { $0.lastPathComponent < $1.lastPathComponent },
                reportURLsByAgentID: latestURLsByAgentID,
                reportURLsByReportID: reportURLsByID,
                metadata: metadata,
                modifiedAt: modifiedAt
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }

        AppLog.info("Scanned \(sessions.count) sessions", category: .sessions)
        return sessions
    }

    public func rename(session: MeetingSession, to newName: String) throws {
        var metadata = session.metadata
        metadata.name = newName
        try saveMetadata(metadata, to: session.metadataURL)
        AppLog.info("Renamed session \(session.baseName)", category: .sessions)
    }

    public func move(session: MeetingSession, toFolderID folderID: String?) throws {
        if let folderID, !loadFolders().contains(where: { $0.id == folderID }) {
            throw FolderError.missingFolder
        }
        var metadata = session.metadata
        metadata.schemaVersion = 3
        metadata.folderID = folderID
        try saveMetadata(metadata, to: session.metadataURL)
        AppLog.info("Moved session \(session.baseName) to folder=\(folderID ?? "root")", category: .sessions)
    }

    public func delete(session: MeetingSession) throws {
        try deleteArtifacts(baseName: session.baseName)
    }

    public func deleteArtifacts(baseName: String) throws {
        guard let items = try? fileManager.contentsOfDirectory(at: saveDirectory, includingPropertiesForKeys: nil) else {
            AppLog.warning("Cannot delete artifacts; directory unavailable", category: .sessions)
            return
        }
        for item in items where item.lastPathComponent.hasPrefix(baseName) {
            try fileManager.removeItem(at: item)
        }
        AppLog.info("Deleted artifacts for \(baseName)", category: .sessions)
    }

    public func createInitialMetadata(baseName: String, displayName: String, createdAt: String) throws {
        let url = saveDirectory.appending(path: "\(baseName).json")
        try saveMetadata(SessionMetadata(name: displayName, createdAt: createdAt), to: url)
        AppLog.info("Created initial metadata for \(baseName)", category: .sessions)
    }

    public func createInitialMetadata(
        baseName: String,
        displayName: String,
        createdAt: String,
        folderID: String?,
        source: RecordingSource
    ) throws {
        let url = saveDirectory.appending(path: "\(baseName).json")
        try saveMetadata(
            SessionMetadata(name: displayName, createdAt: createdAt, folderID: folderID, source: source),
            to: url
        )
        AppLog.info("Created initial metadata for \(baseName), source=\(source.rawValue)", category: .sessions)
    }

    public func updateRecordingMetadata(baseName: String, duration: Int, quality: String, videoURL: URL) throws {
        let metadataURL = saveDirectory.appending(path: "\(baseName).json")
        var metadata = loadMetadata(url: metadataURL)
        let size = (try? videoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Double.init) ?? 0
        metadata.recording = RecordingInfo(
            durationSeconds: duration,
            videoQuality: quality,
            videoPath: videoURL.lastPathComponent,
            microphoneAudioPath: "",
            videoSizeMB: (size / 1_048_576.0 * 100).rounded() / 100,
            microphoneSizeMB: 0
        )
        try saveMetadata(metadata, to: metadataURL)
        AppLog.info("Updated recording metadata for \(baseName)", category: .sessions)
    }

    public func updateSegmentedRecordingMetadata(
        baseName: String,
        update: SegmentedRecordingMetadataUpdate
    ) throws {
        let sortedSegments = update.segments.sorted { $0.index < $1.index }
        let metadataURL = saveDirectory.appending(path: "\(baseName).json")
        var metadata = loadMetadata(url: metadataURL)
        metadata.schemaVersion = 3
        metadata.recording = RecordingInfo(
            durationSeconds: update.duration,
            videoQuality: update.quality,
            videoPath: sortedSegments.first?.videoPath ?? "",
            microphoneAudioPath: sortedSegments.first?.microphoneAudioPath ?? "",
            videoSizeMB: megabytes(sortedSegments.reduce(Int64(0)) { $0 + $1.videoSizeBytes }),
            microphoneSizeMB: megabytes(sortedSegments.reduce(Int64(0)) { $0 + $1.microphoneSizeBytes }),
            segmented: true,
            limitProfileID: update.profile.rawValue,
            stopReason: update.stopReason,
            segments: sortedSegments
        )
        try saveMetadata(metadata, to: metadataURL)
        AppLog.info("Updated segmented recording metadata for \(baseName), parts=\(sortedSegments.count)", category: .sessions)
    }

    public func appendReportMetadata(baseName: String, report: ReportInfo) throws {
        let metadataURL = saveDirectory.appending(path: "\(baseName).json")
        var metadata = loadMetadata(url: metadataURL)
        var reports = metadata.reports ?? []
        reports.append(report)
        metadata.reports = reports
        try saveMetadata(metadata, to: metadataURL)
        AppLog.info("Appended report metadata for \(baseName), status=\(report.status)", category: .sessions)
    }

    public func upsertReportMetadata(baseName: String, report: ReportInfo) throws {
        let metadataURL = saveDirectory.appending(path: "\(baseName).json")
        var metadata = loadMetadata(url: metadataURL)
        var reports = metadata.reports ?? []
        if let index = reports.firstIndex(where: {
            $0.id == report.id || ($0.agentID == report.agentID && $0.createdAt == report.createdAt)
        }) {
            reports[index] = report
        } else {
            reports.append(report)
        }
        metadata.reports = reports
        try saveMetadata(metadata, to: metadataURL)
        AppLog.info("Updated report metadata for \(baseName), status=\(report.status)", category: .sessions)
    }

    public func loadReportText(url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    public func overwriteReportText(_ text: String, url: URL) throws {
        let directory = saveDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let reportURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard reportURL.deletingLastPathComponent() == directory,
              reportURL.pathExtension.lowercased() == "txt" else {
            throw ReportError.invalidPath
        }
        try text.write(to: reportURL, atomically: true, encoding: .utf8)
        AppLog.info("Updated report text at \(reportURL.lastPathComponent)", category: .sessions)
    }

    public func saveReportText(_ text: String, baseName: String, agentID: String) throws -> URL {
        let url = saveDirectory.appending(path: "\(baseName)_protocol_\(agentID).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        AppLog.info("Saved report text for \(baseName), agent=\(agentID)", category: .sessions)
        return url
    }

    public func saveReportText(_ text: String, baseName: String, agentID: String, reportID: String) throws -> URL {
        let safeAgentID = safeFileComponent(agentID)
        let safeReportID = safeFileComponent(reportID)
        let url = saveDirectory.appending(path: "\(baseName)_protocol_\(safeAgentID)_\(safeReportID).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        AppLog.info("Saved versioned report for \(baseName), agent=\(agentID)", category: .sessions)
        return url
    }

    public func updateRemoteMedia(baseName: String, manifest: RemoteMediaManifest?) throws {
        let metadataURL = saveDirectory.appending(path: "\(baseName).json")
        var metadata = loadMetadata(url: metadataURL)
        metadata.schemaVersion = 3
        metadata.remoteMedia = manifest
        try saveMetadata(metadata, to: metadataURL)
    }

    public func loadChat(baseName: String, reportID: String, modelAlias: String) -> ChatThread {
        let url = chatURL(baseName: baseName, reportID: reportID)
        guard let data = try? Data(contentsOf: url),
              let thread = try? JSONDecoder().decode(ChatThread.self, from: data) else {
            return ChatThread(reportID: reportID, modelAlias: modelAlias)
        }
        return thread
    }

    public func saveChat(_ thread: ChatThread, baseName: String) throws {
        let url = chatURL(baseName: baseName, reportID: thread.reportID)
        try writeJSON(thread, to: url)
    }

    public func chatURL(baseName: String, reportID: String) -> URL {
        saveDirectory.appending(path: "\(baseName)_chat_\(safeFileComponent(reportID)).json")
    }

    public func loadFolders() -> [RecordingFolder] {
        let url = foldersURL
        guard let data = try? Data(contentsOf: url),
              let folders = try? JSONDecoder().decode([RecordingFolder].self, from: data) else {
            return []
        }
        return folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public func createFolder(name: String) throws -> RecordingFolder {
        let normalizedName = try validatedFolderName(name, excludingID: nil)
        var folders = loadFolders()
        let folder = RecordingFolder(name: normalizedName)
        folders.append(folder)
        try saveFolders(folders)
        return folder
    }

    public func renameFolder(id: String, to name: String) throws {
        let normalizedName = try validatedFolderName(name, excludingID: id)
        var folders = loadFolders()
        guard let index = folders.firstIndex(where: { $0.id == id }) else {
            throw FolderError.missingFolder
        }
        folders[index].name = normalizedName
        try saveFolders(folders)
    }

    public func deleteFolder(id: String, moveSessionsToRoot: Bool) throws {
        if moveSessionsToRoot {
            for session in scanSessions() where session.metadata.folderID == id {
                try move(session: session, toFolderID: nil)
            }
        }
        var folders = loadFolders()
        folders.removeAll { $0.id == id }
        try saveFolders(folders)
    }

    private func loadMetadata(url: URL) -> SessionMetadata {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(SessionMetadata.self, from: data) else {
            return SessionMetadata()
        }
        return metadata
    }

    private func saveMetadata(_ metadata: SessionMetadata, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    private var foldersURL: URL {
        saveDirectory.appending(path: ".steno-folders.json")
    }

    private func saveFolders(_ folders: [RecordingFolder]) throws {
        try writeJSON(folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, to: foldersURL)
    }

    private func validatedFolderName(_ name: String, excludingID: String?) throws -> String {
        let normalized = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !normalized.isEmpty else {
            throw FolderError.invalidName
        }
        if loadFolders().contains(where: {
            $0.id != excludingID && $0.name.localizedCaseInsensitiveCompare(normalized) == .orderedSame
        }) {
            throw FolderError.duplicateName
        }
        return normalized
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func safeFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        return String(scalars).isEmpty ? "item" : String(scalars)
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    private func megabytes(_ bytes: Int64) -> Double {
        (Double(bytes) / 1_048_576.0 * 100).rounded() / 100
    }

}

private struct SessionBuilder {
    var baseName: String
    var directory: URL
    var videoURL: URL?
    var metadataURL: URL?
    var audioURLs: [URL] = []
    var segmentVideoURLs: [Int: URL] = [:]
    var segmentMicrophoneURLs: [Int: URL] = [:]
    var reportURLsByAgentID: [String: URL] = [:]
}

private extension String {
    func firstMatch(pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: self) else {
            return nil
        }
        return String(self[swiftRange])
    }

    func firstIntegerMatch(pattern: String) -> Int? {
        firstMatch(pattern: pattern).flatMap(Int.init)
    }
}
