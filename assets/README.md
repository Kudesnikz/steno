# Steno Assets

Эта папка содержит ресурсы нативного Swift/macOS приложения.

## App Icon

`app_icon.icns` используется как иконка `.app` bundle. Скрипт сборки копирует файл в:

```text
dist/Steno.app/Contents/Resources/app_icon.icns
```

## Menu Bar Icons

Строка меню использует `NSStatusItem` и template PNG:

```text
menu_idleTemplate.png
menu_recordingTemplate.png
menu_processingTemplate.png
menu_errorTemplate.png
```

Требования:

* PNG с прозрачным фоном.
* Черная одноцветная фигура, без теней и градиентов.
* Размер `36x36` для Retina menu bar assets.
* Суффикс `Template` обязателен для понятного назначения файла.

В коде изображения дополнительно помечаются как `isTemplate = true`, поэтому macOS сама перекрашивает их под светлую/темную строку меню.
