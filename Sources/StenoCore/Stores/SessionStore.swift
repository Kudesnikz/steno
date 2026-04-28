import Foundation

public struct SessionStore {
    public let fileManager: FileManager
    public var saveDirectory: URL

    public init(saveDirectory: URL, fileManager: FileManager = .default) {
        self.saveDirectory = saveDirectory
        self.fileManager = fileManager
    }

    public func scanSessions() -> [MeetingSession] {
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
            let protocolPattern = "^\(NSRegularExpression.escapedPattern(for: baseName))_protocol_(.+)\\.txt$"
            if fileName == "\(baseName).mp4" {
                builder.videoURL = url
            } else if fileName == "\(baseName).json" {
                builder.metadataURL = url
            } else if fileName == "\(baseName)_transcript.json" {
                builder.transcriptURL = url
            } else if fileName == "\(baseName)_transcript.md" {
                builder.transcriptMarkdownURL = url
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
            guard let videoURL = builder.videoURL else {
                return nil
            }
            let modifiedAt = (try? videoURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let metadataURL = builder.metadataURL ?? saveDirectory.appending(path: "\(builder.baseName).json")
            let metadata = loadMetadata(url: metadataURL)
            return MeetingSession(
                baseName: builder.baseName,
                baseURL: saveDirectory.appending(path: builder.baseName),
                videoURL: videoURL,
                metadataURL: metadataURL,
                transcriptURL: builder.transcriptURL,
                transcriptMarkdownURL: builder.transcriptMarkdownURL,
                audioURLs: builder.audioURLs.sorted { $0.lastPathComponent < $1.lastPathComponent },
                reportURLsByAgentID: builder.reportURLsByAgentID,
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

    public func delete(session: MeetingSession) throws {
        try deleteArtifacts(baseName: session.baseName)
    }

    public func deleteArtifacts(baseName: String) throws {
        guard let items = try? fileManager.contentsOfDirectory(at: saveDirectory, includingPropertiesForKeys: nil) else {
            AppLog.warning("Cannot delete artifacts; directory unavailable", category: .sessions)
            return
        }
        for item in items where item.lastPathComponent.hasPrefix(baseName) {
            try? fileManager.removeItem(at: item)
        }
        AppLog.info("Deleted artifacts for \(baseName)", category: .sessions)
    }

    public func createInitialMetadata(baseName: String, displayName: String, createdAt: String) throws {
        let url = saveDirectory.appending(path: "\(baseName).json")
        try saveMetadata(SessionMetadata(name: displayName, createdAt: createdAt), to: url)
        AppLog.info("Created initial metadata for \(baseName)", category: .sessions)
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

    public func updateTranscriptionMetadata(
        baseName: String,
        status: TranscriptionStatus,
        modelName: String,
        language: String,
        segmentCount: Int,
        error: String? = nil
    ) throws {
        let metadataURL = saveDirectory.appending(path: "\(baseName).json")
        var metadata = loadMetadata(url: metadataURL)
        metadata.transcription = TranscriptionInfo(
            status: status,
            modelName: modelName,
            language: language,
            transcriptPath: "\(baseName)_transcript.json",
            markdownPath: "\(baseName)_transcript.md",
            segmentCount: segmentCount,
            error: error
        )
        try saveMetadata(metadata, to: metadataURL)
        AppLog.info("Updated transcription metadata for \(baseName), status=\(status.rawValue)", category: .sessions)
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
        if let index = reports.firstIndex(where: { $0.agentID == report.agentID && $0.createdAt == report.createdAt }) {
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

    public func saveReportText(_ text: String, baseName: String, agentID: String) throws -> URL {
        let url = saveDirectory.appending(path: "\(baseName)_protocol_\(agentID).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        AppLog.info("Saved report text for \(baseName), agent=\(agentID)", category: .sessions)
        return url
    }

    public func loadTranscript(url: URL) throws -> TranscriptDocument {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TranscriptDocument.self, from: data)
    }

    public func loadTranscriptMarkdown(url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    public func saveTranscript(_ transcript: TranscriptDocument, baseName: String) throws -> (jsonURL: URL, markdownURL: URL) {
        let jsonURL = saveDirectory.appending(path: "\(baseName)_transcript.json")
        let markdownURL = saveDirectory.appending(path: "\(baseName)_transcript.md")
        try saveTranscriptDocument(transcript, jsonURL: jsonURL, markdownURL: markdownURL)
        AppLog.info("Saved transcript for \(baseName), segments=\(transcript.segments.count)", category: .sessions)
        return (jsonURL, markdownURL)
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

    private func saveTranscriptDocument(_ transcript: TranscriptDocument, jsonURL: URL, markdownURL: URL) throws {
        try fileManager.createDirectory(at: jsonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(transcript)
        try data.write(to: jsonURL, options: .atomic)
        try transcript.timestampedMarkdown.write(to: markdownURL, atomically: true, encoding: .utf8)
    }
}

private struct SessionBuilder {
    var baseName: String
    var directory: URL
    var videoURL: URL?
    var metadataURL: URL?
    var transcriptURL: URL?
    var transcriptMarkdownURL: URL?
    var audioURLs: [URL] = []
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
}
