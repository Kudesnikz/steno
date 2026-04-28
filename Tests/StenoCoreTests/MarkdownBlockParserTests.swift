@testable import StenoCore
import XCTest

final class MarkdownBlockParserTests: XCTestCase {
    func testParsesHeadingsListsAndTables() {
        let blocks = MarkdownBlockParser.parse(
            """
            # Главное

            **Суть:** коротко.

            - Первый пункт
            - **Второй** пункт

            | Действие | Ответственный |
            | :--- | :--- |
            | Сделать | Иван |
            """
        )

        XCTAssertEqual(
            blocks,
            [
                .heading(level: 1, text: "Главное"),
                .paragraph("**Суть:** коротко."),
                .unorderedList(["Первый пункт", "**Второй** пункт"]),
                .table(headers: ["Действие", "Ответственный"], rows: [["Сделать", "Иван"]])
            ]
        )
    }

    func testParsesCodeFenceWithoutLanguage() {
        let blocks = MarkdownBlockParser.parse(
            """
            ```
            let value = 1
            ```
            """
        )

        XCTAssertEqual(blocks, [.codeBlock(language: nil, code: "let value = 1")])
    }

    func testParsesOrderedListAndBlockquote() {
        let blocks = MarkdownBlockParser.parse(
            """
            1. One
            2. Two

            > Important
            > Context
            """
        )

        XCTAssertEqual(
            blocks,
            [
                .orderedList(["One", "Two"]),
                .blockquote("Important\nContext")
            ]
        )
    }
}
