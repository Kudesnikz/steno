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
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
