#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="${APP_NAME:-Steno}"
if [ -z "${PYTHON_BIN+x}" ]; then
  PYTHON_BIN="python3"
  PYTHON_BIN_IS_DEFAULT=1
else
  PYTHON_BIN_IS_DEFAULT=0
fi
ARCH="${1:-all}"
HOST_ARCH="$(uname -m)"

if [ "$ARCH" = "all" ]; then
    echo "--- Сборка для обеих архитектур (arm64 и x86_64) ---"
    "$0" arm64
    "$0" x86_64
    echo "--- Обе сборки успешно завершены! ---"
    exit 0
fi

case "$ARCH" in
  arm64|x86_64)
    ;;
  *)
    echo "Usage: $0 [arm64|x86_64|all]"
    exit 1
    ;;
esac

echo "--- Сборка ${APP_NAME} для ${ARCH} ---"

if [ "$PYTHON_BIN_IS_DEFAULT" -eq 1 ]; then
  if [ "$ARCH" = "arm64" ]; then
    echo "Готовим arm64 окружение (.venv)..."
    python3 -m venv .venv
    . .venv/bin/activate
    python -m pip install -U pip
    if [ "$HOST_ARCH" = "x86_64" ]; then
      echo "Кросс-компиляция: Устанавливаем базовые пакеты сборки для x86_64 хоста..."
      python -m pip install py2app setuptools wheel
      echo "Устанавливаем arm64 зависимости (через --target)..."
      grep -vE "^(py2app|setuptools)" requirements.txt > req_arm64.txt
      VENV_LIB_DIR=$(python -c "import site; print(site.getsitepackages()[0])")
      python -m pip install -r req_arm64.txt --only-binary=:all: --platform macosx_11_0_arm64 --target "$VENV_LIB_DIR" --upgrade
      rm req_arm64.txt
    else
      python -m pip install -r requirements.txt
    fi
    deactivate
    PYTHON_BIN=".venv/bin/python"
  elif [ "$ARCH" = "x86_64" ]; then
    echo "Готовим x86_64 окружение (.venv-x86)..."
    if [ "$HOST_ARCH" = "arm64" ]; then
      # СБ-5: Проверяем наличие Rosetta 2 — без неё arch -x86_64 не работает
      if ! /usr/bin/arch -x86_64 true 2>/dev/null; then
        echo "ОШИБКА: Rosetta 2 не установлена."
        echo "Установите Rosetta: softwareupdate --install-rosetta --agree-to-license"
        exit 1
      fi
      if [ -x ".venv-x86/bin/python" ] && ! file .venv-x86/bin/python | grep -q "x86_64"; then
        rm -rf .venv-x86
      fi
      arch -x86_64 /usr/bin/python3 -m venv .venv-x86
      arch -x86_64 zsh -lc ". .venv-x86/bin/activate && python -m pip install -U pip py2app setuptools wheel && python -m pip install -r requirements.txt"
    else
      python3 -m venv .venv-x86
      . .venv-x86/bin/activate
      python -m pip install -U pip py2app setuptools wheel
      python -m pip install -r requirements.txt
      deactivate
    fi
    PYTHON_BIN=".venv-x86/bin/python"
  fi
fi

FFMPEG_SOURCE=""
if [ "$ARCH" = "arm64" ]; then
  FFMPEG_SOURCE="bin/ffmpeg_arm64"
elif [ "$ARCH" = "x86_64" ]; then
  FFMPEG_SOURCE="bin/ffmpeg_x86_64"
fi

if [ -n "$FFMPEG_SOURCE" ]; then
  if [ -f "$FFMPEG_SOURCE" ] && [ ! -x "$FFMPEG_SOURCE" ]; then
    echo "Выдача прав на выполнение для $FFMPEG_SOURCE..."
    chmod +x "$FFMPEG_SOURCE"
  fi

  if [ ! -x "$FFMPEG_SOURCE" ]; then
    echo "Ошибка: не найден или недоступен для выполнения файл $FFMPEG_SOURCE"
    exit 1
  fi
  # Мы больше не копируем файл в bin/ffmpeg, так как setup.py сам подхватит нужный
  # cp -f "$FFMPEG_SOURCE" bin/ffmpeg
  # chmod +x bin/ffmpeg
  echo "Используем ffmpeg: $FFMPEG_SOURCE"
fi

rm -rf build dist

if [ "$ARCH" = "x86_64" ] && [ "$HOST_ARCH" = "arm64" ]; then
  if ! file "$PYTHON_BIN" | grep -q "x86_64"; then
    echo "Ошибка: $PYTHON_BIN не является x86_64 Python."
    echo "Удалите .venv-x86 и повторите сборку, либо задайте PYTHON_BIN с x86_64 интерпретатором."
    exit 1
  fi
  arch -x86_64 "$PYTHON_BIN" setup.py py2app --arch "$ARCH"
else
  "$PYTHON_BIN" setup.py py2app --arch "$ARCH"
fi

APP_PATH="dist/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Ошибка: не найдено приложение после сборки: $APP_PATH"
  exit 1
fi

# СБ-5: Верификация архитектуры итогового бинарника
MAIN_BINARY="$APP_PATH/Contents/MacOS/${APP_NAME}"
if [ -f "$MAIN_BINARY" ]; then
  if ! file "$MAIN_BINARY" | grep -qi "$ARCH"; then
    echo "ОШИБКА: Бинарник собран для неправильной архитектуры!"
    file "$MAIN_BINARY"
    exit 1
  fi
  echo "Архитектура бинарника проверена: OK (${ARCH})"
fi

DMG_NAME="${DMG_NAME:-${APP_NAME}-${ARCH}.dmg}"
APP_NAME="$APP_NAME" APP_PATH="$APP_PATH" DMG_NAME="$DMG_NAME" ./scripts/build_dmg.sh
DMG_EXIT_CODE=$?

# СБ-9: Удаляем dist/ ТОЛЬКО при успешном DMG.
# Если build_dmg.sh упал — бандл сохраняется в dist/ для отладки.
if [ $DMG_EXIT_CODE -ne 0 ]; then
  echo "Ошибка при создании DMG (код $DMG_EXIT_CODE).  .app-бандл сохранён в dist/ для отладки."
  exit $DMG_EXIT_CODE
fi

echo "Очистка временных папок сборки (build, dist, egg-info)..."
rm -rf build dist Steno.egg-info

echo "--- Готово: ${DMG_NAME} ---"
