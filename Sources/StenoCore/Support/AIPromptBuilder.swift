import Foundation

public enum AIPromptBuilder {
    public static let transcriptCharacterLimit = 60_000

    public static func meetingAnalysisPrompt(videoURL: URL, transcript: AITranscriptContext? = nil) -> String {
        let basePrompt = """
        Внимательно изучи прикрепленные файлы и пришли ответ в формате markdown, строго следуя System instructions.

        Дата встречи: \(meetingDate(from: videoURL)). Если тебе необходимо указывать имена участников - проверь правильность их написания в разных частях видео. Очень важно чтоб имена были корректными. Ответ без дополнительных комментариев.
        """

        guard let transcript else {
            return basePrompt
        }

        return """
        \(basePrompt)

        Дополнительно ниже приложена локальная транскрибация Whisper с таймкодами из файла \(transcript.fileName). Используй ее как вспомогательный источник: сверяй спорные места с видео, не считай транскрипт абсолютной истиной, но используй таймкоды для структуры, решений, участников и action items.

        ```text
        \(trimmedTranscript(transcript.text))
        ```
        """
    }

    public static func meetingDate(from videoURL: URL) -> String {
        let fileName = videoURL.lastPathComponent
        if let range = fileName.range(of: #"Meet_(\d{2}\.\d{2}\.\d{4})_"#, options: .regularExpression) {
            let raw = String(fileName[range])
            return raw.replacingOccurrences(of: "Meet_", with: "").replacingOccurrences(of: "_", with: "")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func trimmedTranscript(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > transcriptCharacterLimit else {
            return trimmed
        }
        let index = trimmed.index(trimmed.startIndex, offsetBy: transcriptCharacterLimit)
        return String(trimmed[..<index]) + "\n\n[Transcript truncated to \(transcriptCharacterLimit) characters.]"
    }
}
