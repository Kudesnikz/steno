# Changelog

## [2.1.0] - 2026-08-24

- Переведен production UI на Gemini latest aliases с Flash Lite Latest по умолчанию и миграцией старых model ID.
- Добавлены одноуровневые папки, drag-and-drop записей и безопасный импорт видео.
- Добавлены versioned-протоколы и постоянный чат по каждой версии протокола.
- Gemini Files сохраняются до TTL, переиспользуются между запросами и удаляются через долговечную очередь вместе с записью.
- Большие записи разбиваются на последовательные AI-части; добавлен map-reduce fallback для переполнения контекста.
- Разбиение больших записей вынесено в опциональную настройку и по умолчанию выключено.
- Протокол стал первым сообщением общей ленты чата; Copy доступен у протокола и каждого сообщения.
- Добавлен импорт видео перетаскиванием из Finder в Recordings или выбранную папку.
- Запись переведена на `SCStreamOutput`/`AVAssetWriter` с независимым mute микрофона и системного звука без разрыва таймлайна.
- Добавлен локальный учет Gemini usage и обработка `Retry-After`/`RetryInfo` без бессмысленных retry при `429`.

## [2.0.0] - 2026-04-30

### Native Swift Migration (The Big Rewrite)
* **Complete Rewrite:** Steno is now a native macOS application written in Swift 5.10+, eliminating all Python dependencies and the legacy runtime.
* **Modern UI:** Rebuilt the interface from scratch using SwiftUI and the latest Apple design patterns.
* **Performance:** Massive reduction in CPU and memory footprint compared to the previous Python-based versions.

### AI
* **Modular AI Providers:** Added support for multiple AI backends, including Google Gemini, AWS Bedrock, and OpenAI-compatible APIs (local LLMs, etc.).
* **Smart Reports:** Improved Markdown report generation with support for multiple AI "Agents" (custom prompts).
* **AI Connection Health:** Real-time connectivity check for AI providers directly in Settings.

### Recording & Processing
* **On-Device Recording:** Native implementation of screen and audio capture using Apple's latest ScreenCaptureKit and AVFoundation.
* **Monitor Selection:** Choose exactly which display to record.
* **Optimized Video Presets:** Fine-tuned video quality settings for the best balance between file size and readability.

### Data & Migration
* **Seamless Transition:** Built-in `LegacyMigrationService` that automatically converts your history and settings from Steno 1.x (Python) to the new native format.
* **SwiftData Support:** Future-proof data storage for sessions and configuration.

### Other Improvements
* **Universal Binary:** Native support for both Apple Silicon and Intel Macs.
* **New Status Bar Menu:** Redesigned system tray menu with real-time status indicators.
* **Enhanced Permissions:** Streamlined onboarding and system permission handling.

---
*Note: This release marks the transition from the legacy Python implementation (v1.7.0) to a fully native Swift architecture (v2.0.0).*
