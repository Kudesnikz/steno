# Changelog

## Native Swift Migration

* Replaced the legacy implementation with a native Swift macOS app.
* Added SwiftPM targets for `Steno`, `StenoCore`, and `StenoCoreTests`.
* Added strict Swift concurrency checking.
* Rebuilt the UI with SwiftUI and MVVM using `@Observable`.
* Added a native `NSStatusItem` menu bar controller with template PNG assets.
* Implemented screen and microphone recording through Apple frameworks.
* Implemented Gemini API calls through `URLSession` and `Codable`.
* Added file-backed configuration/session stores and legacy data migration.
* Added XCTest coverage for config and session storage.
* Added Universal macOS build and DMG packaging scripts.
* Removed legacy runtime sources, packaging files, and tests from the repository.
