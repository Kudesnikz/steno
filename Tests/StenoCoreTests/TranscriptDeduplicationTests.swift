@testable import StenoCore
import XCTest

final class TranscriptDeduplicationTests: XCTestCase {
    func testSuppressesMicrophoneEchoOfSystemAudio() {
        let system = TranscriptSegment(
            source: .system,
            startTimeSeconds: 10,
            endTimeSeconds: 12,
            text: "Please review the pull request"
        )
        let microphoneEcho = TranscriptSegment(
            source: .microphone,
            startTimeSeconds: 10.2,
            endTimeSeconds: 12.1,
            text: "please review the pull request"
        )

        let filtered = TranscriptSegmentDeduplicator.filterForAppend(
            candidates: [microphoneEcho],
            existingSegments: [system]
        )

        XCTAssertTrue(filtered.isEmpty)
    }

    func testKeepsMicrophoneOnlySpeech() {
        let microphone = TranscriptSegment(
            source: .microphone,
            startTimeSeconds: 20,
            endTimeSeconds: 22,
            text: "I will take the follow up"
        )

        let filtered = TranscriptSegmentDeduplicator.filterForAppend(
            candidates: [microphone],
            existingSegments: []
        )

        XCTAssertEqual(filtered, [microphone])
    }

    func testOverlapDuplicateDoesNotBreakMonotonicTimeline() {
        let first = TranscriptSegment(source: .system, startTimeSeconds: 53, endTimeSeconds: 55, text: "next topic")
        let overlap = TranscriptSegment(source: .system, startTimeSeconds: 53.1, endTimeSeconds: 55.1, text: "next topic")
        let next = TranscriptSegment(source: .system, startTimeSeconds: 55.2, endTimeSeconds: 57, text: "decision is approved")

        let filtered = TranscriptSegmentDeduplicator.filterForAppend(
            candidates: [overlap, next],
            existingSegments: [first]
        )

        XCTAssertEqual(filtered, [next])
        XCTAssertTrue(([first] + filtered).sortedSegmentsAreMonotonic)
    }

    func testDocumentSuppressesMicrophoneEchoWhenSystemArrivesLater() {
        let microphoneEcho = TranscriptSegment(
            source: .microphone,
            startTimeSeconds: 31,
            endTimeSeconds: 33,
            text: "the action item is assigned"
        )
        let system = TranscriptSegment(
            source: .system,
            startTimeSeconds: 30.8,
            endTimeSeconds: 33.1,
            text: "The action item is assigned"
        )
        var document = TranscriptDocument(
            baseName: "meeting",
            modelName: NativeSpeechDefaults.engineDisplayName,
            language: "system"
        )

        document.append([microphoneEcho])
        document.append([system])

        XCTAssertEqual(document.segments, [system])
    }
}

private extension Array where Element == TranscriptSegment {
    var sortedSegmentsAreMonotonic: Bool {
        let sorted = sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        return zip(sorted, sorted.dropFirst()).allSatisfy { previous, next in
            previous.startTimeSeconds <= next.startTimeSeconds
        }
    }
}
