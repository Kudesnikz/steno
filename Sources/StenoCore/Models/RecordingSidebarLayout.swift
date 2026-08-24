import Foundation

struct RecordingSidebarLayout: Sendable {
    let folders: [RecordingFolder]
    let rootSessions: [MeetingSession]

    private let sessionsByFolderID: [String: [MeetingSession]]
    private let hasSessions: Bool

    init(folders: [RecordingFolder], sessions: [MeetingSession]) {
        self.folders = folders.sorted(by: Self.folderSort)
        rootSessions = sessions.filter { $0.metadata.folderID == nil }
        hasSessions = !sessions.isEmpty

        var groupedSessions: [String: [MeetingSession]] = [:]
        for session in sessions {
            guard let folderID = session.metadata.folderID else { continue }
            groupedSessions[folderID, default: []].append(session)
        }
        sessionsByFolderID = groupedSessions
    }

    var isEmpty: Bool {
        folders.isEmpty && !hasSessions
    }

    func sessions(in folder: RecordingFolder) -> [MeetingSession] {
        sessionsByFolderID[folder.id] ?? []
    }

    func moveDestinations(for session: MeetingSession) -> [RecordingFolder] {
        folders.filter { $0.id != session.metadata.folderID }
    }

    private static func folderSort(_ lhs: RecordingFolder, _ rhs: RecordingFolder) -> Bool {
        let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameComparison == .orderedSame {
            return lhs.id < rhs.id
        }
        return nameComparison == .orderedAscending
    }
}
