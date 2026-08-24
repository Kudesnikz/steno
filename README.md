# Steno — AI Meeting Assistant

<div align="center">
  <h3>Ваш персональный секретарь для онлайн-встреч</h3>
  <br>

  [![Скачать сборку (DMG)](https://img.shields.io/badge/📥_Скачать_Steno-DMG_Release-blue?style=for-the-badge)](https://github.com/Kudesnikz/steno/releases/latest)
</div>

---

**Steno** — это современное и легковесное приложение для macOS, созданное для записи онлайн-встреч и их последующего анализа с помощью video-capable AI моделей. Приложение не только сохраняет аудио и видео, но и автоматически генерирует структурированные протоколы встреч по вашим правилам, используя встроенную систему "Агентов".

## 💼 Ключевые возможности

*   **Нативная запись без драйверов:** Приложение использует механизмы macOS (`ScreenCaptureKit`, `AVFoundation`) для записи экрана и звука встречи без сторонних расширений ядра или виртуальных кабелей.
*   **Встроенный мультимедиа-плеер:** Нативный `AVPlayerView` позволяет просматривать сохраненные `.mp4` записи прямо в приложении.
*   **Система Агентов (Промптов):** Создавайте разных ИИ-ассистентов ("Агентов") для любых типов встреч. Например: "Подробный протокол для Confluence", "Краткое саммари для Telegram", "Выделение только задач (Action Items)".
*   **Оконный интерфейс в стиле Apple Notes:** Интуитивно понятное управление записями и просмотр сгенерированных протоколов с рендерингом Markdown (таблицы, списки, форматирование текста) в светлой системной теме.
*   **Gemini latest без ручных обновлений:** Production-интерфейс предлагает `gemini-pro-latest`, `gemini-flash-latest` и `gemini-flash-lite-latest` (по умолчанию). Клиенты других провайдеров остаются в архитектуре, но скрыты.
*   **Папки и импорт:** Записи можно раскладывать по одноуровневым папкам drag-and-drop и импортировать из других приложений без изменения исходного файла.
*   **Чат по записи:** У каждой версии протокола есть отдельная сохраняемая история вопросов и ответов. Gemini File URI переиспользуется до TTL, а запись перезагружается только перед следующим запросом после истечения срока.
*   **Длинные записи:** В Settings можно опционально включить разбиение AI-копии видео при превышении 400 MiB или 40 минут; настройка по умолчанию выключена, оригинал всегда остается неизменным.
*   **Управляемый звук:** Микрофон и системный звук можно включать и выключать до и во время записи без разрыва таймлайна — выключенный источник заменяется тишиной.
*   **Удобный Онбординг:** При первом запуске Steno проведет через настройку разрешений и ввод API-ключа Google Gemini.
*   **Фоновый режим и Нативный таймер:** Записывайте встречи и запускайте генерацию протоколов напрямую из строки меню (System Tray). При старте записи иконка превращается в нативный растягивающийся таймер времени записи, который идеально вписывается в интерфейс macOS.

## 🚀 Инструкция по использованию

### 1. Установка и Первая настройка
1. Скачайте актуальную `.dmg` сборку приложения по [этой ссылке](https://github.com/sergeygalay/meetAssistant/releases/latest).
2. Откройте образ и перетащите `Steno.app` в папку "Программы" (Applications).
3. Запустите приложение. Появится экран **Онбординга**, который поможет:
   * Дать разрешения на **Запись экрана** и доступ к **Микрофону**.
   * Ввести ваш API ключ от Google Gemini (получить можно в [Google AI Studio](https://aistudio.google.com/)).

> ⚠️ **Важно:** Если при первом запуске возникает ошибка (например, предупреждение от macOS), откройте Терминал и выполните следующую команду:
> ```bash
> xattr -cr /Applications/Steno.app
> ```

### 2. Настройки (Settings)
1. Кликните по иконке **Шестеренки** в верхней панели или выберите "Settings..." в меню трея.
2. Во вкладке **Общие (General)**: 
   * Выберите желаемое качество видео (Low, Medium, High, Ultra).
   * Выберите Gemini alias: Pro Latest, Flash Latest или Flash Lite Latest. Flash Lite Latest используется по умолчанию.
   * Посмотрите локальный учет запросов и токенов Steno. Точный остаток квоты Google через API недоступен; ссылка на AI Studio находится рядом.
   * Включите или отключите опцию **Отображать время записи** в строке меню.
   * (Опционально) Настройте Base URL, если используете прокси или региональный endpoint.
3. Во вкладке **Агенты (Agents)**: 
   * Добавляйте, удаляйте или редактируйте промпты, по которым ИИ будет писать для вас протоколы.

### 3. Запись встречи
1. Нажмите кнопку **Record** (красный круг) в главном окне приложения или в меню трея. Иконка в трее изменится на динамический таймер записи, растягивающийся по мере увеличения времени (например, " 00:01:25 ").
2. Проведите встречу.
3. Нажмите **Stop** (квадрат) в приложении, либо нажмите на сам таймер в строке меню и выберите "Stop Recording". Запись `.mp4` автоматически сохранится в локальную папку (по умолчанию `~/Movies/ScreenRecordings`).

### 4. Генерация протокола и Плеер
1. В левой панели выберите нужную встречу (сессию).
2. На верхней панели выберите желаемого "Агента" (например, "Краткая выжимка").
3. Нажмите кнопку **Generate** (Молния) и дождитесь окончания обработки. Сгенерированный протокол откроется в новой вкладке.
4. Чтобы просмотреть запись, переключитесь на вкладку **"▶️ Плеер"**.
5. В панели протокола переключитесь на **«Чат»**, чтобы задавать вопросы по записи. Зеленый индикатор означает, что повторная загрузка файла пока не нужна.

---

## 🛠 Техническая часть

Steno в ветке `native_ui` мигрирован на нативный **Swift** без зависимости от Python runtime.

### Технологический стек

*   **Язык:** Swift 6 / SwiftPM, Strict Concurrency.
*   **UI:** SwiftUI, нативный `NSStatusItem` для строки меню, небольшой AppKit bridge для системных macOS API.
*   **State:** MVVM на `@Observable`.
*   **Запись:** `ScreenCaptureKit`, `AVFoundation`, `CoreMedia`.
*   **AI:** Production workflow на Gemini Files API и `generateContent`; dormant-клиенты OpenAI-compatible и Bedrock сохранены компилируемыми за внутренним feature gate.
*   **Persistence:** JSON-файлы в `~/.steno` и папке записей.
*   **Логи:** `os.Logger` плюс файл `~/.steno/steno.log`.
*   **Тесты:** XCTest.
*   **Lint:** SwiftLint через Swift Package Manager.

### Структура проекта

*   [`Package.swift`](Package.swift) — SwiftPM manifest.
*   [`Sources/Steno/`](Sources/Steno/) — точка входа macOS-приложения.
*   [`Sources/StenoCore/Models/`](Sources/StenoCore/Models/) — `Codable` модели конфигурации и сессий.
*   [`Sources/StenoCore/Stores/`](Sources/StenoCore/Stores/) — файловое хранение конфигурации и сессий.
*   [`Sources/StenoCore/Services/`](Sources/StenoCore/Services/) — запись экрана, AI clients/catalog, permissions, legacy migration.
*   [`Sources/StenoCore/ViewModels/`](Sources/StenoCore/ViewModels/) — `@Observable` view model.
*   [`Sources/StenoCore/Views/`](Sources/StenoCore/Views/) — SwiftUI views.
*   [`Sources/StenoCore/Support/`](Sources/StenoCore/Support/) — logging, paths, formatters.
*   [`Tests/StenoCoreTests/`](Tests/StenoCoreTests/) — XCTest.
*   [`bin/`](bin/) — bundled `ffmpeg` binaries for AI media preparation.
*   [`assets/`](assets/) — app icon и template-иконки строки меню.

### Сборка и запуск

Требования:

*   Xcode 26.4.1+.
*   Активный toolchain:
    ```bash
    sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
    sudo xcodebuild -license accept
    ```

Проверка:

```bash
./script/lint.sh
swift test
```

Сборка и запуск `.app`:

```bash
./script/build_and_run.sh
```

Сборка без запуска:

```bash
./script/build_and_run.sh build
```

Сборка Universal DMG:

```bash
./script/build_dmg.sh
```

Очистка локальных build artifacts:

```bash
./script/clean.sh
```

Результат:

```text
dist/Steno.app
dist/Steno-2.1.0-universal.dmg
```

### Логи

Файловые логи:

```bash
tail -f ~/.steno/steno.log
```

Unified logs:

```bash
/usr/bin/log stream --info --style compact --predicate 'subsystem == "com.sergeygalay.steno"'
```

Crash reports:

```bash
ls -lt ~/Library/Logs/DiagnosticReports/Steno-*.ips
```

### Подпись и распространение

Локальная сборка подписывается ad-hoc (`SIGN_IDENTITY=-`) с Hardened Runtime.
Для публичного распространения нужно использовать Developer ID:

```bash
SIGN_IDENTITY="Developer ID Application: <TEAM>" ./script/build_dmg.sh
```

Нотаризация пока не автоматизирована.

---
*Сделано для продуктивных встреч.*
