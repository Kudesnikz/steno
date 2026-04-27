#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "--- Очистка проекта ---"

rm -rf build/
rm -rf dist/
rm -f *.dmg

echo "--- Очистка завершена ---"
