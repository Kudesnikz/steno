@preconcurrency import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit

/// Loads the current ScreenCaptureKit display list and maps it to stable UI choices.
public struct CaptureDisplayService: Sendable {
    public init() {}

    public func availableDisplays() async -> [CaptureDisplay] {
        do {
            let content = try await SCShareableContent.current
            let screenDescriptors = await Self.screenDescriptorsByDisplayID()

            return content.displays.enumerated().map { index, display in
                let descriptor = screenDescriptors[display.displayID]
                return CaptureDisplay(
                    displayID: String(display.displayID),
                    name: descriptor?.name ?? "Monitor \(index + 1)",
                    width: display.width,
                    height: display.height,
                    isMain: descriptor?.isMain ?? (index == 0)
                )
            }
        } catch {
            AppLog.warning("Failed to load capture displays: \(error.localizedDescription)", category: .recording)
            return []
        }
    }

    @MainActor
    private static func screenDescriptorsByDisplayID() -> [CGDirectDisplayID: ScreenDescriptor] {
        var descriptors: [CGDirectDisplayID: ScreenDescriptor] = [:]
        let mainScreen = NSScreen.main

        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            descriptors[CGDirectDisplayID(number.uint32Value)] = ScreenDescriptor(
                name: screen.localizedName,
                isMain: screen == mainScreen
            )
        }

        return descriptors
    }
}

private struct ScreenDescriptor: Sendable {
    var name: String
    var isMain: Bool
}
