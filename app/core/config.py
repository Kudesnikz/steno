import os
import json

CONFIG_DIR = os.path.expanduser("~/.steno")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
OLD_CONFIG_FILE = os.path.expanduser("~/.recorder_app_config.json")

DEFAULT_CONFIG = {
    "api_key": "",
    "base_url": "https://gemini-warmup.galaypro.ru",
    "video_device_idx": "0",
    "video_device_name": "Main Screen",
    "model_name": "gemini-3-flash-preview",
    "save_dir": os.path.expanduser("~/Movies/ScreenRecordings"),
    "video_quality": "Medium",
    "show_recording_time": True,
    "volume_main": 1.0,
    "volume_mic": 1.0,
    "mute_main": False,
    "mute_mic": False,
    "used_tokens": 0,
    "last_request_tokens": 0,
    "active_agent_id": "default",
    "agents": [
        {
            "id": "default",
            "name": "Стандартный протокол",
            "prompt": "Ты — ИИ-ассистент для составления протоколов встреч. Твоя задача — проанализировать предоставленный медиафайл и вернуть ТОЛЬКО протокол в формате Markdown (оптимизированный для Confluence), строго без вступительных слов, приветствий и пояснений самой нейросети.\n\nИспользуй следующий шаблон:\n# Протокол встречи: [Сформулируй тему]\n**Дата:** [Дата из запроса]\n**Участники:** [Список имен или ролей]\n\n## 1. Саммари (Summary)\n[Краткое, структурированное содержание обсуждения без воды]\n\n## 2. Принятые решения\n* [Список конкретных решений]\n\n## 3. План действий (Action Items)\nОформи строго как таблицу:\n| Задача | Ответственный | Срок |\n| :--- | :--- | :--- |\n| [Описание задачи] | [Имя] | [Дедлайн или -] |"
        },
        {
            "id": "summary",
            "name": "Краткая выжимка",
            "prompt": "Сделай краткое саммари обсуждения в формате Markdown. Укажи только основные темы и ключевые выводы."
        }
    ]
}

class ConfigManager:
    @staticmethod
    def load():
        config = DEFAULT_CONFIG.copy()
        
        # Миграция файла со старого пути на новый
        if not os.path.exists(CONFIG_FILE) and os.path.exists(OLD_CONFIG_FILE):
            try:
                os.makedirs(CONFIG_DIR, exist_ok=True)
                import shutil
                shutil.move(OLD_CONFIG_FILE, CONFIG_FILE)
            except Exception as e:
                print(f"Error migrating config file: {e}")
                
        if os.path.exists(CONFIG_FILE):
            try:
                with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                    loaded_config = json.load(f)
                    
                    # Миграция старого конфига
                    if "prompt" in loaded_config and "agents" not in loaded_config:
                        old_prompt = loaded_config.pop("prompt")
                        loaded_config["agents"] = [
                            {
                                "id": "default",
                                "name": "Стандартный протокол",
                                "prompt": old_prompt
                            }
                        ]
                        loaded_config["active_agent_id"] = "default"
                    
                    config.update(loaded_config)
            except Exception as e:
                print(f"Error loading config: {e}")
        return config

    @staticmethod
    def save(config):
        try:
            os.makedirs(CONFIG_DIR, exist_ok=True)
            with open(CONFIG_FILE, "w", encoding="utf-8") as f:
                json.dump(config, f, indent=4, ensure_ascii=False)
        except Exception as e:
            print(f"Error saving config: {e}")

    @staticmethod
    def get_agent_by_id(config, agent_id):
        for agent in config.get("agents", []):
            if agent.get("id") == agent_id:
                return agent
        return None
