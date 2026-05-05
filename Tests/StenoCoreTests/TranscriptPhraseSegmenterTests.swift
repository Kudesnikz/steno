@testable import StenoCore
import XCTest

final class TranscriptPhraseSegmenterTests: XCTestCase {
    func testCombinesWordTokensIntoTenSecondPhrases() {
        let tokens = (0..<12).map { index in
            TranscriptSegment(
                id: "token-\(index)",
                source: .microphone,
                startTimeSeconds: Double(index),
                endTimeSeconds: Double(index) + 0.4,
                text: "word\(index)"
            )
        }

        let phrases = TranscriptPhraseSegmenter.phrases(from: tokens)

        XCTAssertEqual(phrases.count, 2)
        XCTAssertEqual(
            phrases[0].text,
            "word0 word1 word2 word3 word4 word5 word6 word7 word8 word9"
        )
        XCTAssertEqual(phrases[0].startTimeSeconds, 0)
        XCTAssertEqual(phrases[0].endTimeSeconds, 9.4)
        XCTAssertEqual(phrases[1].text, "word10 word11")
    }

    func testSplitsPhraseOnLongPauseAndTerminalPunctuation() {
        let tokens = [
            TranscriptSegment(source: .system, startTimeSeconds: 0.0, endTimeSeconds: 0.2, text: "Hello"),
            TranscriptSegment(source: .system, startTimeSeconds: 0.3, endTimeSeconds: 0.4, text: "world."),
            TranscriptSegment(source: .system, startTimeSeconds: 0.5, endTimeSeconds: 0.7, text: "Next"),
            TranscriptSegment(source: .system, startTimeSeconds: 2.0, endTimeSeconds: 2.2, text: "phrase")
        ]

        let phrases = TranscriptPhraseSegmenter.phrases(from: tokens)

        XCTAssertEqual(phrases.map(\.text), ["Hello world.", "Next", "phrase"])
    }
}
