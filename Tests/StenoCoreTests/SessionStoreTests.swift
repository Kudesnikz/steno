import Foundation
@testable import StenoCore
import XCTest

final class SessionStoreTests: XCTestCase {
    func testScansVideoMetadataProtocolAndAudioFiles() throws {
        let directory = try temporaryDirectory()
        let baseName = "Meet_24.06.2024_15:30:00"
        try Data("video".utf8).write(to: directory.appending(path: "\(baseName).mp4"))
        try Data("audio".utf8).write(to: directory.appending(path: "\(baseName)_tmp_mic.m4a"))
        try Data("# Report".utf8).write(to: directory.appending(path: "\(baseName)_protocol_default.txt"))
        try Data(#"{"name":"Custom name"}"#.utf8).write(to: directory.appending(path: "\(baseName).json"))

        let store = SessionStore(saveDirectory: directory)
        let sessions = store.scanSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].baseName, baseName)
        XCTAssertEqual(sessions[0].displayName, "Custom name")
        XCTAssertEqual(sessions[0].audioURLs.count, 1)
        XCTAssertEqual(sessions[0].reportURLsByAgentID["default"]?.lastPathComponent, "\(baseName)_protocol_default.txt")
    }

    func testRenamesByUpdatingMetadataJSON() throws {
        let directory = try temporaryDirectory()
        let baseName = "Meet_24.06.2024_15:30:00"
        try Data("video".utf8).write(to: directory.appending(path: "\(baseName).mp4"))

        let store = SessionStore(saveDirectory: directory)
        let session = try XCTUnwrap(store.scanSessions().first)

        try store.rename(session: session, to: "Renamed")
        let rescanned = store.scanSessions()
        XCTAssertEqual(rescanned.first?.displayName, "Renamed")
    }

    func testUpsertReportMetadataReplacesMatchingAgentAndCreatedAt() throws {
        let directory = try temporaryDirectory()
        let baseName = "Meet_24.06.2024_15:30:00"
        try Data("video".utf8).write(to: directory.appending(path: "\(baseName).mp4"))

        let store = SessionStore(saveDirectory: directory)
        let started = "2026-04-28T13:00:00Z"
        let inProgress = ReportInfo(
            agentID: "default",
            agentName: "Стандартный протокол",
            model: "gemini-3-flash-preview",
            createdAt: started,
            processingDurationSeconds: 10,
            tokens: ReportTokens(input: 0, output: 0, total: 0),
            outputPath: "",
            status: "uploading_media"
        )
        let success = ReportInfo(
            agentID: "default",
            agentName: "Стандартный протокол",
            model: "gemini-3-flash-preview",
            createdAt: started,
            processingDurationSeconds: 120,
            tokens: ReportTokens(input: 10, output: 20, total: 30),
            outputPath: "\(baseName)_protocol_default.txt",
            status: "success"
        )

        try store.upsertReportMetadata(baseName: baseName, report: inProgress)
        try store.upsertReportMetadata(baseName: baseName, report: success)

        let session = try XCTUnwrap(store.scanSessions().first)
        let reports = try XCTUnwrap(session.metadata.reports)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].status, "success")
        XCTAssertEqual(reports[0].tokens.total, 30)
        XCTAssertEqual(reports[0].outputPath, "\(baseName)_protocol_default.txt")
    }

    func testDeleteArtifactsRemovesOnlyMatchingBaseName() throws {
        let directory = try temporaryDirectory()
        let baseName = "Meet_24.06.2024_15:30:00"
        let otherBaseName = "Meet_24.06.2024_16:00:00"
        try Data("video".utf8).write(to: directory.appending(path: "\(baseName).mp4"))
        try Data("metadata".utf8).write(to: directory.appending(path: "\(baseName).json"))
        try Data("report".utf8).write(to: directory.appending(path: "\(baseName)_protocol_default.txt"))
        try Data("other".utf8).write(to: directory.appending(path: "\(otherBaseName).mp4"))

        let store = SessionStore(saveDirectory: directory)
        try store.deleteArtifacts(baseName: baseName)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "\(baseName).mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "\(baseName).json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "\(baseName)_protocol_default.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "\(otherBaseName).mp4").path))
    }

    func testFolderNamesAreTrimmedUniqueAndSessionsCanMoveBackToRoot() throws {
        let directory = try temporaryDirectory()
        let baseName = "Meet_24.06.2024_15:30:00"
        try Data("video".utf8).write(to: directory.appending(path: "\(baseName).mp4"))
        let store = SessionStore(saveDirectory: directory)
        try store.createInitialMetadata(
            baseName: baseName,
            displayName: "Meeting",
            createdAt: "2026-08-03T00:00:00Z",
            folderID: nil,
            source: .captured
        )

        let folder = try store.createFolder(name: "  Project  ")
        XCTAssertEqual(folder.name, "Project")
        XCTAssertThrowsError(try store.createFolder(name: "project"))

        let session = try XCTUnwrap(store.scanSessions().first)
        try store.move(session: session, toFolderID: folder.id)
        XCTAssertEqual(store.scanSessions().first?.metadata.folderID, folder.id)

        try store.deleteFolder(id: folder.id, moveSessionsToRoot: true)
        XCTAssertNil(store.scanSessions().first?.metadata.folderID)
        XCTAssertTrue(store.loadFolders().isEmpty)
    }

    func testVersionedReportsAndChatsStayBoundToReportID() throws {
        let directory = try temporaryDirectory()
        let baseName = "Meet_24.06.2024_15:30:00"
        try Data("video".utf8).write(to: directory.appending(path: "\(baseName).mp4"))
        let store = SessionStore(saveDirectory: directory)
        let firstURL = try store.saveReportText("first", baseName: baseName, agentID: "default", reportID: "report-1")
        let secondURL = try store.saveReportText("second", baseName: baseName, agentID: "default", reportID: "report-2")
        XCTAssertNotEqual(firstURL, secondURL)

        let thread = ChatThread(
            reportID: "report-1",
            modelAlias: "gemini-flash-lite-latest",
            messages: [ChatMessage(role: .user, text: "What was decided?")]
        )
        try store.saveChat(thread, baseName: baseName)
        XCTAssertEqual(
            store.loadChat(baseName: baseName, reportID: "report-1", modelAlias: thread.modelAlias),
            thread
        )
        XCTAssertTrue(
            store.loadChat(baseName: baseName, reportID: "report-2", modelAlias: thread.modelAlias).messages.isEmpty
        )
    }

    func testOverwriteReportTextUpdatesOnlyRequestedVersion() throws {
        let directory = try temporaryDirectory()
        let store = SessionStore(saveDirectory: directory)
        let firstURL = try store.saveReportText("first", baseName: "meeting", agentID: "default", reportID: "report-1")
        let secondURL = try store.saveReportText("second", baseName: "meeting", agentID: "default", reportID: "report-2")

        try store.overwriteReportText("edited", url: firstURL)

        XCTAssertEqual(try store.loadReportText(url: firstURL), "edited")
        XCTAssertEqual(try store.loadReportText(url: secondURL), "second")
    }

    func testOverwriteReportTextRejectsFilesOutsideSaveDirectory() throws {
        let directory = try temporaryDirectory()
        let outsideDirectory = try temporaryDirectory()
        let outsideURL = outsideDirectory.appending(path: "protocol.txt")
        try Data("original".utf8).write(to: outsideURL)
        let store = SessionStore(saveDirectory: directory)

        XCTAssertThrowsError(try store.overwriteReportText("edited", url: outsideURL))
        XCTAssertEqual(try String(contentsOf: outsideURL, encoding: .utf8), "original")
    }

    func testLegacyReportIDIsStableAcrossDecodes() throws {
        let payload = #"{"agent_id":"default","created_at":"2026-08-03T00:00:00Z","output_path":"old.txt"}"#
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let first = try JSONDecoder().decode(ReportInfo.self, from: data)
        let second = try JSONDecoder().decode(ReportInfo.self, from: data)
        XCTAssertEqual(first.id, second.id)
        XCTAssertTrue(first.id.hasPrefix("legacy-"))
    }

    func testOnlyLatestMetadataEntryCanUseAnOverwrittenLegacyReport() throws {
        let directory = try temporaryDirectory()
        let baseName = "Meet_24.06.2024_15:30:00"
        let outputPath = "\(baseName)_protocol_default.txt"
        try Data("video".utf8).write(to: directory.appending(path: "\(baseName).mp4"))
        try Data("latest".utf8).write(to: directory.appending(path: outputPath))
        let reports = [
            ReportInfo(
                id: "old", agentID: "default", agentName: "Default", model: "gemini-2.5-flash",
                createdAt: "2026-01-01T00:00:00Z", processingDurationSeconds: 1,
                tokens: ReportTokens(input: 1, output: 1, total: 2), outputPath: outputPath, status: "success"
            ),
            ReportInfo(
                id: "new", agentID: "default", agentName: "Default", model: "gemini-2.5-flash",
                createdAt: "2026-01-02T00:00:00Z", processingDurationSeconds: 1,
                tokens: ReportTokens(input: 1, output: 1, total: 2), outputPath: outputPath, status: "success"
            )
        ]
        let metadata = SessionMetadata(name: "Meeting", reports: reports)
        let encoder = JSONEncoder()
        try encoder.encode(metadata).write(to: directory.appending(path: "\(baseName).json"))

        let session = try XCTUnwrap(SessionStore(saveDirectory: directory).scanSessions().first)
        XCTAssertNil(session.reportURLsByReportID["old"])
        XCTAssertNotNil(session.reportURLsByReportID["new"])
        XCTAssertEqual(session.availableReports.map(\.id), ["new"])
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
