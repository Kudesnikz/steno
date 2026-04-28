import Foundation
@testable import StenoCore
import XCTest

final class TranscriptTests: XCTestCase {
    func testTranscriptMarkdownIncludesTimestampsSourcesAndText() {
        let document = TranscriptDocument(
            baseName: "Meet_24.06.2024_15:30:00",
            modelName: WhisperDefaults.defaultModelID,
            language: "ru",
            segments: [
                TranscriptSegment(source: .system, startTimeSeconds: 1.2, endTimeSeconds: 4.7, text: "Первый фрагмент"),
                TranscriptSegment(source: .microphone, startTimeSeconds: 5.0, endTimeSeconds: 6.1, text: "Ответ")
            ]
        )

        let markdown = document.timestampedMarkdown

        XCTAssertTrue(markdown.contains("Model: \(WhisperDefaults.defaultModelID)"))
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

    func testBundledDefaultWhisperModelIsAvailable() throws {
        let url = try WhisperModelLocator().modelURL(named: WhisperDefaults.defaultModelID)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, "\(WhisperDefaults.defaultModelID).bin")
    }
}
