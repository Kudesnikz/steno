#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "--- Очистка проекта ---"

rm -rf build/
rm -rf dist/
rm -rf .venv/
rm -rf .venv-x86/
rm -rf __pycache__/
find . -type d -name __pycache__ -exec rm -rf {} +
rm -f *.dmg
rm -rf Steno.egg-info

echo "--- Очистка завершена ---"
