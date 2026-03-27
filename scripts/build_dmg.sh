#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Настройки путей
APP_NAME="${APP_NAME:-Steno}"
APP_PATH="${APP_PATH:-dist/${APP_NAME}.app}"
DMG_NAME="${DMG_NAME:-${APP_NAME}.dmg}"
BACKGROUND_PATH="${BACKGROUND_PATH:-assets/install.tiff}"

echo "--- Начинаем сборку $APP_NAME ---"

# 1. Проверка наличия приложения
if [ ! -d "$APP_PATH" ]; then
    echo "Ошибка: Файл $APP_PATH не найден!"
    exit 1
fi

# 2. Подготовка и подпись приложения сертификатом Apple
echo "1. Подготовка структуры и подпись приложения..."

# Исправление структуры фреймворков (особенно для PyQt6)
python3 scripts/fix_frameworks.py "$APP_PATH"

# Сначала даем права на выполнение всем бинарникам внутри
find "$APP_PATH" -type f -name "ffmpeg*" -exec chmod +x {} \;
find "$APP_PATH" -type f -name "*.so" -exec chmod +x {} \;
find "$APP_PATH" -type f -name "*.dylib" -exec chmod +x {} \;

# СБ-3: Используем ad-hoc подпись вместо Mac Developer.
# Mac Developer цертификат блокируется Gatekeeper на машинах пользователей.
# Ad-hoc ("-") позволяет запуск после однократной разрешающей операции в настройках.
# Для полнои дистрибуции — заменить на сертификат "Developer ID Application".
SIGN_IDENTITY="-"

# Подписываем внутренние компоненты (фреймворки, библиотеки, бинарники)
echo "Подписываем внутренние компоненты..."
find "$APP_PATH" -type d -name "*.framework" -exec codesign --force --sign "$SIGN_IDENTITY" {} \;
find "$APP_PATH" -type f -name "*.so" -exec codesign --force --sign "$SIGN_IDENTITY" {} \;
find "$APP_PATH" -type f -name "*.dylib" -exec codesign --force --sign "$SIGN_IDENTITY" {} \;
find "$APP_PATH" -type f -name "ffmpeg*" -exec codesign --force --sign "$SIGN_IDENTITY" {} \;

# Подписываем основной бандл с entitlements
echo "Подписываем основной бандл..."
codesign --force --sign "$SIGN_IDENTITY" --entitlements entitlements.plist "$APP_PATH"

# 3. Удаление старого DMG, если он существует
if [ -f "$DMG_NAME" ]; then
    echo "Удаляем старый $DMG_NAME..."
    rm "$DMG_NAME"
fi

# 4. Создание DMG при помощи create-dmg
echo "2. Создаем установщик DMG..."

# Создаем файл инструкции для пользователя внутри dist, чтобы он попал в DMG
cat <<EOF > dist/ИНСТРУКЦИЯ_ПО_УСТАНОВКЕ.txt
Если приложение "Steno.app" не открывается после копирования:

1. Откройте программу "Терминал" (через Spotlight или в папке Программы/Утилиты).
2. Скопируйте и вставьте туда следующую команду:
   xattr -cr /Applications/Steno.app
3. Нажмите Enter.

После этого приложение запустится без ошибок.
Это необходимо, так как приложение распространяется без платного сертификата Apple.
EOF

create-dmg \
  --volname "$APP_NAME" \
  --background "$BACKGROUND_PATH" \
  --window-pos 200 120 \
  --window-size 512 364 \
  --icon-size 128 \
  --icon "${APP_NAME}.app" 140 170 \
  --hide-extension "${APP_NAME}.app" \
  --app-drop-link 370 170 \
  "$DMG_NAME" \
  "dist/"

echo "--- Сборка завершена! Файл: $DMG_NAME ---"
