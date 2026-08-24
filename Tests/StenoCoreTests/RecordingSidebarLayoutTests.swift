import Foundation
@testable import StenoCore
import XCTest

final class RecordingSidebarLayoutTests: XCTestCase {
    func testFoldersAreSortedAboveRootSessionsAndEmptyFoldersRemainAvailable() {
        let alpha = RecordingFolder(id: "alpha", name: "Alpha")
        let zulu = RecordingFolder(id: "zulu", name: "zulu")
        let root = makeSession(id: "root", folderID: nil)
        let foldered = makeSession(id: "foldered", folderID: zulu.id)

        let layout = RecordingSidebarLayout(
            folders: [zulu, alpha],
            sessions: [root, foldered]
        )

        XCTAssertEqual(layout.folders.map(\.id), [alpha.id, zulu.id])
        XCTAssertEqual(layout.rootSessions.map(\.id), [root.id])
        XCTAssertTrue(layout.sessions(in: alpha).isEmpty)
        XCTAssertEqual(layout.sessions(in: zulu).map(\.id), [foldered.id])
        XCTAssertFalse(layout.isEmpty)
    }

    func testMoveDestinationsAreSortedAndExcludeCurrentFolder() {
        let beta = RecordingFolder(id: "beta", name: "Beta")
        let alpha = RecordingFolder(id: "alpha", name: "Alpha")
        let root = makeSession(id: "root", folderID: nil)
        let inAlpha = makeSession(id: "in-alpha", folderID: alpha.id)

        let layout = RecordingSidebarLayout(
            folders: [beta, alpha],
            sessions: [root, inAlpha]
        )

        XCTAssertEqual(layout.moveDestinations(for: root).map(\.id), [alpha.id, beta.id])
        XCTAssertEqual(layout.moveDestinations(for: inAlpha).map(\.id), [beta.id])
    }

    func testLayoutIsEmptyOnlyWhenThereAreNoFoldersOrSessions() {
        XCTAssertTrue(RecordingSidebarLayout(folders: [], sessions: []).isEmpty)

        let emptyFolder = RecordingFolder(id: "empty", name: "Empty")
        XCTAssertFalse(RecordingSidebarLayout(folders: [emptyFolder], sessions: []).isEmpty)

        let orphanedSession = makeSession(id: "orphaned", folderID: "missing-folder")
        XCTAssertFalse(RecordingSidebarLayout(folders: [], sessions: [orphanedSession]).isEmpty)
    }

    private func makeSession(id: String, folderID: String?) -> MeetingSession {
        let baseURL = URL(fileURLWithPath: "/tmp/\(id)")
        return MeetingSession(
            baseName: id,
            baseURL: baseURL,
            videoURL: baseURL.appendingPathExtension("mp4"),
            metadataURL: baseURL.appendingPathExtension("json"),
            audioURLs: [],
            reportURLsByAgentID: [:],
            metadata: SessionMetadata(name: id, folderID: folderID),
            modifiedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
