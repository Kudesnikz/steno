import Foundation

public enum AIPromptBuilder {
    public static func meetingAnalysisPrompt(videoURL: URL) -> String {
        """
        Внимательно изучи прикрепленные файлы и пришли ответ в формате markdown, строго следуя System instructions.

        Дата встречи: \(meetingDate(from: videoURL)). Если тебе необходимо указывать имена участников - проверь правильность их написания в разных частях видео. Очень важно чтоб имена были корректными. Ответ без дополнительных комментариев.
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
}
