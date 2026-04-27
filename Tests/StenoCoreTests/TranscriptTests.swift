import Foundation
@testable import StenoCore
import XCTest

final class TranscriptTests: XCTestCase {
    func testTranscriptMarkdownIncludesTimestampsSourcesAndText() {
        let document = TranscriptDocument(
            baseName: "Meet_24.06.2024_15:30:00",
            modelName: "ggml-tiny-q5_1",
            language: "ru",
            segments: [
                TranscriptSegment(source: .system, startTimeSeconds: 1.2, endTimeSeconds: 4.7, text: "Первый фрагмент"),
                TranscriptSegment(source: .microphone, startTimeSeconds: 5.0, endTimeSeconds: 6.1, text: "Ответ")
            ]
        )

        let markdown = document.timestampedMarkdown

        XCTAssertTrue(markdown.contains("Model: ggml-tiny-q5_1"))
        XCTAssertTrue(markdown.contains("[00:00:01-00:00:05] [System] Первый фрагмент"))
        XCTAssertTrue(markdown.contains("[00:00:05-00:00:07] [Microphone] Ответ"))
    }

    func testPromptAddsTranscriptOnlyWhenProvided() {
        let videoURL = URL(fileURLWithPath: "/tmp/Meet_24.06.2024_15:30:00.mp4")
        let withoutTranscript = AIPromptBuilder.meetingAnalysisPrompt(videoURL: videoURL)
        let withTranscript = AIPromptBuilder.meetingAnalysisPrompt(
            videoURL: videoURL,
            transcript: AITranscriptContext(text: "[00:00:01] hello", fileName: "Meet_transcript.md")
        )

        XCTAssertFalse(withoutTranscript.contains("локальная транскрибация Whisper"))
        XCTAssertTrue(withTranscript.contains("локальная транскрибация Whisper"))
        XCTAssertTrue(withTranscript.contains("[00:00:01] hello"))
    }

    func testBundledTinyWhisperModelIsAvailable() throws {
        let url = try WhisperModelLocator().modelURL(named: WhisperModelName.tinyQ5.rawValue)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, "ggml-tiny-q5_1.bin")
    }
}
