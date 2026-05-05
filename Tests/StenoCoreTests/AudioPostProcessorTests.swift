import Foundation
@testable import StenoCore
import XCTest

final class AudioPostProcessorTests: XCTestCase {
    func testReplaceAudioArgumentsMixSystemAndMicrophoneSidecars() {
        let postProcessor = AudioPostProcessor()
        let sidecars = RecordingAudioSidecars(
            system: RecordingAudioSidecarFile(
                url: URL(fileURLWithPath: "/tmp/system.caf"),
                startOffsetSeconds: 0,
                durationSeconds: 10
            ),
            microphone: RecordingAudioSidecarFile(
                url: URL(fileURLWithPath: "/tmp/microphone.caf"),
                startOffsetSeconds: 0.25,
                durationSeconds: 9
            ),
            temporaryDirectory: URL(fileURLWithPath: "/tmp/sidecars")
        )

        let args = postProcessor.replaceAudioArguments(
            videoURL: URL(fileURLWithPath: "/tmp/input.mp4"),
            sidecars: sidecars,
            outputURL: URL(fileURLWithPath: "/tmp/output.mp4")
        )

        XCTAssertEqual(args.filter { $0 == "-i" }.count, 3)
        XCTAssertTrue(args.contains("/tmp/system.caf"))
        XCTAssertTrue(args.contains("/tmp/microphone.caf"))
        XCTAssertTrue(args.contains("0:v:0"))
        XCTAssertFalse(args.contains("0:a"))
        XCTAssertTrue(args.contains { value in
            value.contains("[1:a]anull[sys]") &&
                value.contains("[2:a]adelay=250:all=1[mic]") &&
                value.contains("[sys][mic]amix=inputs=2")
        })
    }

    func testReplaceAudioArgumentsCanUseSingleMicrophoneSidecar() {
        let postProcessor = AudioPostProcessor()
        let sidecars = RecordingAudioSidecars(
            system: nil,
            microphone: RecordingAudioSidecarFile(
                url: URL(fileURLWithPath: "/tmp/microphone.caf"),
                startOffsetSeconds: 0,
                durationSeconds: 9
            ),
            temporaryDirectory: URL(fileURLWithPath: "/tmp/sidecars")
        )

        let args = postProcessor.replaceAudioArguments(
            videoURL: URL(fileURLWithPath: "/tmp/input.mp4"),
            sidecars: sidecars,
            outputURL: URL(fileURLWithPath: "/tmp/output.mp4")
        )

        XCTAssertEqual(args.filter { $0 == "-i" }.count, 2)
        XCTAssertTrue(args.contains("/tmp/microphone.caf"))
        XCTAssertTrue(args.contains { value in
            value.contains("[0:a]anull[orig]") &&
            value.contains("[1:a]anull[mic]") &&
                value.contains("[orig][mic]amix=inputs=2")
        })
    }
}
