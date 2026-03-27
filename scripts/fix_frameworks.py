#!/usr/bin/env python3
"""fix_frameworks.py — исправляет структуру .framework бандлов для py2app + codesign.

СБ-6: переписан без os.chdir() — используем абсолютные пути для всех симлинков.
"""
import os
import shutil
import sys


def fix_framework(framework_path: str) -> None:
    """Восстанавливает структуру Versions/A + Current симлинк если она сломана."""
    framework_name = os.path.basename(framework_path).replace('.framework', '')
    versions_dir = os.path.join(framework_path, 'Versions')
    version_a_dir = os.path.join(versions_dir, 'A')

    if not os.path.exists(version_a_dir):
        return  # Структура Versions/A отсутствует — пропускаем

    current_symlink = os.path.join(versions_dir, 'Current')
    if os.path.islink(current_symlink) or os.path.exists(current_symlink):
        return  # Симлинк уже есть — структура корректна

    print(f"Fixing {framework_path}...")

    # 1. Переносим Resources из корня фреймворка в Versions/A/Resources
    root_resources = os.path.join(framework_path, 'Resources')
    version_a_resources = os.path.join(version_a_dir, 'Resources')
    if os.path.exists(root_resources) and not os.path.islink(root_resources):
        shutil.move(root_resources, version_a_resources)

    # 2. Переносим корневой бинарник в Versions/A если он там не находится
    root_binary = os.path.join(framework_path, framework_name)
    version_a_binary = os.path.join(version_a_dir, framework_name)
    if os.path.exists(root_binary) and not os.path.islink(root_binary):
        shutil.move(root_binary, version_a_binary)

    # 3. Создаём Versions/Current → A
    # СБ-6: НЕ используем os.chdir() — передаём абсолютный путь для target,
    # а относительное значение 'A' — это значение симлинка (так нужно для бандлов macOS).
    try:
        os.symlink('A', current_symlink)
    except FileExistsError:
        pass  # Гонка — уже создан другим процессом

    # 4. Создаём корневой симлинк на бинарник: FrameworkName → Versions/Current/FrameworkName
    current_binary = os.path.join(versions_dir, 'Current', framework_name)
    root_binary_link = os.path.join(framework_path, framework_name)
    if os.path.exists(current_binary):
        if os.path.exists(root_binary_link) or os.path.islink(root_binary_link):
            os.remove(root_binary_link)
        # Значение симлинка — относительный путь внутри бандла (требование macOS)
        os.symlink(f'Versions/Current/{framework_name}', root_binary_link)

    # 5. Создаём корневой симлинк на Resources: Resources → Versions/Current/Resources
    current_resources = os.path.join(versions_dir, 'Current', 'Resources')
    root_resources_link = os.path.join(framework_path, 'Resources')
    if os.path.exists(current_resources):
        if os.path.exists(root_resources_link) or os.path.islink(root_resources_link):
            os.remove(root_resources_link)
        os.symlink('Versions/Current/Resources', root_resources_link)


def main() -> None:
    app_path = sys.argv[1] if len(sys.argv) > 1 else 'dist/Steno.app'
    if not os.path.exists(app_path):
        print(f"App not found at {app_path}")
        sys.exit(1)

    count = 0
    for root, dirs, _ in os.walk(app_path):
        for d in dirs:
            if d.endswith('.framework'):
                fix_framework(os.path.join(root, d))
                count += 1

    print(f"Fixed frameworks structure for {count} frameworks.")


if __name__ == '__main__':
    main()
