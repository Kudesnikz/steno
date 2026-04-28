import Foundation

/// A display that can be used as the source for ScreenCaptureKit recording.
public struct CaptureDisplay: Identifiable, Hashable, Sendable {
    public var id: String { displayID }

    public var displayID: String
    public var name: String
    public var width: Int
    public var height: Int
    public var isMain: Bool

    public init(displayID: String, name: String, width: Int, height: Int, isMain: Bool) {
        self.displayID = displayID
        self.name = name
        self.width = width
        self.height = height
        self.isMain = isMain
    }

    public var resolutionDescription: String {
        "\(width)x\(height)"
    }

    public var menuTitle: String {
        let mainMarker = isMain ? " · Main" : ""
        return "\(name) · \(resolutionDescription)\(mainMarker)"
    }
}

/// Resolves persisted display selections while keeping legacy defaults valid.
public enum CaptureDisplaySelection {
    public static let legacyDefaultDisplayID = "0"

    public static func selectedDisplay(configuredID: String, displays: [CaptureDisplay]) -> CaptureDisplay? {
        guard !displays.isEmpty else {
            return nil
        }
        if configuredID != legacyDefaultDisplayID,
           let display = displays.first(where: { $0.id == configuredID }) {
            return display
        }
        return displays.first(where: \.isMain) ?? displays.first
    }
}
