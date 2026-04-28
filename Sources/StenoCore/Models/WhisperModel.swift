import Foundation

public enum WhisperModelInstallState: String, Codable, Hashable, Sendable {
    case bundled
    case downloaded
    case remote

    public var displayName: String {
        switch self {
        case .bundled:
            "Bundled"
        case .downloaded:
            "Downloaded"
        case .remote:
            "Remote"
        }
    }
}

public struct WhisperModelDescriptor: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var fileName: String
    public var displayName: String
    public var family: String
    public var quantization: String
    public var language: String
    public var sizeBytes: Int64
    public var sha256: String?
    public var installState: WhisperModelInstallState

    public init(
        id: String,
        fileName: String,
        displayName: String,
        family: String,
        quantization: String,
        language: String,
        sizeBytes: Int64,
        sha256: String?,
        installState: WhisperModelInstallState
    ) {
        self.id = id
        self.fileName = fileName
        self.displayName = displayName
        self.family = family
        self.quantization = quantization
        self.language = language
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.installState = installState
    }

    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)?download=true")!
    }

    public var isInstalled: Bool {
        installState == .bundled || installState == .downloaded
    }

    public var canDelete: Bool {
        installState == .downloaded
    }

    public var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

public struct WhisperModelDownloadState: Hashable, Sendable {
    public var modelID: String
    public var isDownloading: Bool

    public init(modelID: String = "", isDownloading: Bool = false) {
        self.modelID = modelID
        self.isDownloading = isDownloading
    }
}
