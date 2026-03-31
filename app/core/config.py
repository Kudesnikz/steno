import os
import json
import logging

logger = logging.getLogger("Steno.Config")

CONFIG_DIR = os.path.expanduser("~/.steno")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
LOG_FILE = os.path.join(CONFIG_DIR, "steno.log")
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
            "prompt": "Ты — экспертный ИИ-аналитик, специализирующийся на выделении ключевых смыслов из бизнес-коммуникаций. Твоя единственная задача — превратить хаотичный лог встречи в предельно лаконичную выжимку (Executive Summary), содержащую только самую суть.\n\nТВОЕ ЗАДАНИЕ:\nПроанализируй текст встречи и отсеки 90% второстепенной информации, оставив только критически важные инсайты, цели и итоги.\n\nПРАВИЛА КОНТЕНТА И ФОРМАТИРОВАНИЯ:\n1. Пиши максимально кратко, в стиле «для генерального директора, у которого есть всего 30 секунд».\n2. Используй только формат Markdown.\n3. СТРОГО ЗАПРЕЩЕНЫ: приветствия, вводные фразы («Я проанализировал...», «Вот краткая выжимка...»), вежливые отступления и любые пояснения от нейросети.\n4. Выдавай результат сразу по следующему шаблону:\n\n# Главное (The Core)\n**Суть встречи в 1 предложении:** [Сформулируй максимально емко]\n\n## Ключевые тезисы\n* [Тезис 1: Самая важная мысль]\n* [Тезис 2: Главный инсайт или проблема]\n* [Тезис 3: Критическое изменение в планах]\n\n## Главный итог (Outcome)\n[Опиши финальное состояние вопроса: о чем договорились в сухом остатке]\n\n## Что дальше (Next Steps)\n* [Действие] — [Ответственный]\n\nЕсли на встрече не было принято решений или не назначены ответственные, так и напиши: «Решения не зафиксированы». Не выдумывай факты, которых нет в исходном тексте."
        },
        {
            "id": "stenograph",
            "name": "Steno-графист",
            "prompt": "Ты — опытный ИИ-стенографист и секретарь-референт, специализирующийся на расшифровке онлайн-встреч. Твоя единственная цель — сотворить максимально точную, дословную и структурированную стенограмму (транскрипт) предоставленного созвона.\\n\\nТВОЕ ЗАДАНИЕ:\\nВнимательно проанализируй аудиозапись или черновой транскрипт и преобразуй его в читаемый, четкий формат диалога без искажения смысла.\\n\\nПРАВИЛА ФОРМАТИРОВАНИЯ И ПОВЕДЕНИЯ:\\n1. Выводи текст строго в формате диалога: \\n   [Имя спикера или \\\"Спикер 1\\\", \\\"Спикер 2\\\"]: [Точная реплика].\\n2. Слушай внимательно: если участники встречи обращаются друг к другу по именам или представляют себя, используй эти имена вместо безликого \\\"Спикер N\\\".\\n3. Разделяй реплики разных людей абзацами для удобства чтения.\\n4. Сохраняй исходный смысл и полноту 100% информации. Сохраняй технические термины, англицизмы и метрики. Не выдумывай ничего от себя и не делай кратких выжимок.\\n5. Слегка очисти речь от явного \\\"мусора\\\": запинок и слов-паразитов (\\\"э-э-э\\\", \\\"ну как бы\\\"), если это не меняет тональность.\\n6. Расставь правильные знаки препинания для удобства чтения.\\n\\nПРИМЕР ОЖИДАЕМОГО РЕЗУЛЬТАТА:\\nАлексей (PM): Коллеги, всем привет. Разработчики, кто готов рассказать о прогрессе?\\nСпикер 2: Привет. Мы успешно закрыли таски и выкатили API на стейдж.\\n\\nНачни свой ответ СРАЗУ со стенограммы. Не пиши никаких вступительных фраз или приветствий. Выдавай только структурированный диалог."
        }
    ]
}

VIDEO_QUALITY_PRESETS = {
    "Low": {"width": 960, "height": 540, "fps": 5, "bitrate": 1000000},
    "Medium": {"width": 1280, "height": 720, "fps": 10, "bitrate": 3000000},
    "High": {"width": 1920, "height": 1080, "fps": 30, "bitrate": 8000000},
    "Ultra": {"width": 2560, "height": 1440, "fps": 60, "bitrate": 25000000}
}

AI_MODELS = [
    "gemini-3-flash-preview",
    "gemini-3.1-pro-preview",
    "gemini-flash-latest",
    "gemini-flash-lite-latest"
]

class ConfigManager:
    @staticmethod
    def load():
        # АРХ-7: используем deepcopy чтобы не мутировать вложенный список agents
        # в DEFAULT_CONFIG через shallow copy
        import copy as _copy
        config = _copy.deepcopy(DEFAULT_CONFIG)
        
        # Миграция файла со старого пути на новый
        if not os.path.exists(CONFIG_FILE) and os.path.exists(OLD_CONFIG_FILE):
            try:
                os.makedirs(CONFIG_DIR, exist_ok=True)
                import shutil
                shutil.move(OLD_CONFIG_FILE, CONFIG_FILE)
            except Exception as e:
                logger.error(f"Error migrating config file: {e}")
                
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
                logger.error(f"Error loading config: {e}")
        return config

    @staticmethod
    def save(config):
        try:
            os.makedirs(CONFIG_DIR, exist_ok=True)
            with open(CONFIG_FILE, "w", encoding="utf-8") as f:
                json.dump(config, f, indent=4, ensure_ascii=False)
        except Exception as e:
            logger.error(f"Error saving config: {e}")

    @staticmethod
    def get_agent_by_id(config, agent_id):
        for agent in config.get("agents", []):
            if agent.get("id") == agent_id:
                return agent
        return None
