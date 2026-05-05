import Foundation

public struct RecordingAudioSidecarFile: Hashable, Sendable {
    public var url: URL
    public var startOffsetSeconds: Double
    public var durationSeconds: Double

    public init(url: URL, startOffsetSeconds: Double, durationSeconds: Double) {
        self.url = url
        self.startOffsetSeconds = startOffsetSeconds
        self.durationSeconds = durationSeconds
    }
}

public struct RecordingAudioSidecars: Hashable, Sendable {
    public var system: RecordingAudioSidecarFile?
    public var microphone: RecordingAudioSidecarFile?
    public var temporaryDirectory: URL

    public init(
        system: RecordingAudioSidecarFile?,
        microphone: RecordingAudioSidecarFile?,
        temporaryDirectory: URL
    ) {
        self.system = system
        self.microphone = microphone
        self.temporaryDirectory = temporaryDirectory
    }

    public var hasAudio: Bool {
        system != nil || microphone != nil
    }

    public func cleanup(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: temporaryDirectory)
    }
}
