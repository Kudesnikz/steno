import os
import time
import re
import logging
from datetime import datetime

from PyQt6.QtCore import QThread, pyqtSignal
from google import genai
from google.genai import types

from app.core.config import ConfigManager

logger = logging.getLogger("Steno.AIWorker")

def get_meeting_date(filename):
    basename = os.path.basename(filename)
    match = re.search(r"Meet_(\d{2}\.\d{2}\.\d{4})_", basename)
    if match: return match.group(1)
    
    try: return datetime.fromtimestamp(os.path.getmtime(filename)).strftime("%Y-%m-%d")
    except: pass
    
    try: return datetime.fromtimestamp(os.path.getctime(filename)).strftime("%Y-%m-%d")
    except: pass
    
    return datetime.now().strftime("%Y-%m-%d")

class AIWorker(QThread):
    # success, title, message, base_name, agent_id
    finished_signal = pyqtSignal(bool, str, str, str, str)

    def __init__(self, session_base_path, config, agent_id):
        super().__init__()
        self.session_base_path = session_base_path
        self.config = config
        self.agent_id = agent_id

    def run(self):
        try:
            logger.info(f"Starting AI processing for: {self.session_base_path} with agent {self.agent_id}")
            api_key = self.config.get("api_key")
            
            # Проверка ключа
            if not api_key:
                self.finished_signal.emit(False, "AI Error", "Нет API ключа. Настройте ключ в меню.", "", self.agent_id)
                return

            video_path = f"{self.session_base_path}.mp4"
            mic_audio_path = f"{self.session_base_path}_mic.m4a"
            base_name = os.path.basename(self.session_base_path)

            # Файлы
            files_to_upload_paths = [video_path]
            if os.path.exists(mic_audio_path):
                files_to_upload_paths.append(mic_audio_path)
            
            # Клиент
            client_kwargs = {"api_key": api_key}
            base_url = self.config.get("base_url", "").strip()
            if base_url:
                if not base_url.startswith(("http://", "https://")):
                    base_url = "https://" + base_url
                client_kwargs["http_options"] = {"baseUrl": base_url}
            
            client = genai.Client(**client_kwargs)
            
            # Загрузка
            uploaded_files = []
            for path in files_to_upload_paths:
                logger.info(f"Uploading {os.path.basename(path)}...")
                uploaded_files.append(client.files.upload(file=path))
            
            # Ожидание
            ready_files = []
            for uf in uploaded_files:
                logger.info(f"Waiting for processing: {uf.name}")
                while uf.state.name == "PROCESSING":
                    time.sleep(3)
                    uf = client.files.get(name=uf.name)
                
                if uf.state.name == "FAILED":
                    raise Exception(f"Google failed to process file {uf.name}")
                ready_files.append(uf)
            
            # Поиск агента
            agent = ConfigManager.get_agent_by_id(self.config, self.agent_id)
            if not agent:
                raise Exception(f"Agent with ID {self.agent_id} not found in config.")

            # Генерация
            logger.info(f"Generating content...")
            meeting_date = get_meeting_date(video_path)
            user_prompt = f"Составь протокол по прикрепленному файлу.\n\nДата встречи: {meeting_date}. Если тебе необходимо указывать имена участников - проверь правильность их написаня в разных частях видео. Очень важно чтоб имена были корректными."
            system_instruction = agent.get("prompt", "")
            contents = ready_files + [user_prompt]
            
            response = client.models.generate_content(
                model=self.config.get("model_name"),
                contents=contents,
                config=types.GenerateContentConfig(
                    http_options={"timeout": 600000},
                    system_instruction=system_instruction
                )
            )
            
            # Токены
            if response.usage_metadata:
                total_tokens = response.usage_metadata.total_token_count
                self.config["used_tokens"] = self.config.get("used_tokens", 0) + total_tokens
                self.config["last_request_tokens"] = total_tokens
                ConfigManager.save(self.config)

            # Сохранение с агентом
            txt_path = f"{self.session_base_path}_protocol_{self.agent_id}.txt"
            with open(txt_path, "w", encoding="utf-8") as f:
                f.write(response.text)
            
            # Удаление с облака
            for uf in ready_files:
                try: client.files.delete(name=uf.name)
                except: pass
            
            self.finished_signal.emit(True, "Готово!", f"Протокол сохранен: {os.path.basename(txt_path)}", base_name, self.agent_id)

        except Exception as e:
            logger.exception("AI Worker failed")
            base_n = os.path.basename(self.session_base_path) if hasattr(self, 'session_base_path') else ""
            self.finished_signal.emit(False, "AI Ошибка", str(e)[:100], base_n, self.agent_id)
