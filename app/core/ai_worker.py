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

# КРИТ-1: максимальное ожидание и retry-константы
_POLL_INTERVAL_SECS = 0.1   # шаг опроса cancel-флага
_POLL_STEPS = 30             # 30 × 0.1 с = 3 сек между запросами к API
_MAX_RETRIES = 3             # retry для generate_content
_RETRY_BASE_SECS = 5         # экспоненциальный backoff: 5, 10, 20 сек


def get_meeting_date(filename):
    basename = os.path.basename(filename)
    match = re.search(r"Meet_(\d{2}\.\d{2}\.\d{4})_", basename)
    if match:
        return match.group(1)

    try:
        return datetime.fromtimestamp(os.path.getmtime(filename)).strftime("%Y-%m-%d")
    except Exception as e:
        logger.debug(f"Failed to get mtime for {filename}: {e}")

    try:
        return datetime.fromtimestamp(os.path.getctime(filename)).strftime("%Y-%m-%d")
    except Exception as e:
        logger.debug(f"Failed to get ctime for {filename}: {e}")

    return datetime.now().strftime("%Y-%m-%d")


class AIWorker(QThread):
    # success, title, message, base_name, agent_id, tokens_used
    finished_signal = pyqtSignal(bool, str, str, str, str, int)

    def __init__(self, session_base_path, config, agent_id):
        super().__init__()
        self.session_base_path = session_base_path
        self.config = config
        self.agent_id = agent_id
        # КРИТ-1: флаг отмены — устанавливается из главного потока
        self._is_cancelled = False

    def cancel(self) -> None:
        """Запрашивает корректное завершение воркера. Thread-safe."""
        self._is_cancelled = True
        logger.info("AIWorker: cancellation requested")

    def _sleep_cancellable(self, total_secs: float) -> bool:
        """Спит total_secs, но проверяет флаг отмены каждые 0.1 с.
        
        Returns:
            True — спали нормально, False — была запрошена отмена.
        """
        steps = int(total_secs / _POLL_INTERVAL_SECS)
        for _ in range(steps):
            if self._is_cancelled:
                return False
            time.sleep(_POLL_INTERVAL_SECS)
        return True

    def run(self):
        # УТ-4: uploaded_files определяем ДО try — чтобы finally смог очистить
        # файлы даже при ошибке во время загрузки
        uploaded_files = []
        client = None
        total_tokens = 0

        try:
            logger.info(f"Starting AI processing: {self.session_base_path} / agent {self.agent_id}")
            api_key = self.config.get("api_key")

            if not api_key:
                self.finished_signal.emit(
                    False, "AI Error", "Нет API ключа. Настройте ключ в меню.", "", self.agent_id, 0
                )
                return

            # КРИТ-1: проверяем cancel перед длинной операцией
            if self._is_cancelled:
                return

            video_path = f"{self.session_base_path}.mp4"
            mic_audio_path = f"{self.session_base_path}_mic.m4a"
            base_name = os.path.basename(self.session_base_path)

            files_to_upload_paths = [video_path]
            if os.path.exists(mic_audio_path):
                files_to_upload_paths.append(mic_audio_path)

            client_kwargs = {"api_key": api_key}
            base_url = self.config.get("base_url", "").strip()
            if base_url:
                if not base_url.startswith(("http://", "https://")):
                    base_url = "https://" + base_url
                client_kwargs["http_options"] = {"base_url": base_url}

            client = genai.Client(**client_kwargs)

            # --- Загрузка файлов ---
            for path in files_to_upload_paths:
                if self._is_cancelled:
                    return
                logger.info(f"Uploading {os.path.basename(path)}...")
                uploaded_files.append(client.files.upload(path=path))

            # --- Ожидание обработки (с поддержкой cancel) ---
            ready_files = []
            for uf in uploaded_files:
                logger.info(f"Waiting for processing: {uf.name}")
                while uf.state == "PROCESSING":
                    # КРИТ-1: мелкие шаги вместо time.sleep(3)
                    if not self._sleep_cancellable(_POLL_STEPS * _POLL_INTERVAL_SECS):
                        logger.info("AIWorker: cancelled while waiting for processing")
                        return
                    uf = client.files.get(name=uf.name)

                if uf.state == "FAILED":
                    raise Exception(f"Google failed to process file {uf.name}")
                ready_files.append(uf)

            if self._is_cancelled:
                return

            # --- Поиск агента ---
            agent = ConfigManager.get_agent_by_id(self.config, self.agent_id)
            if not agent:
                raise Exception(f"Agent with ID {self.agent_id} not found in config.")

            # --- Генерация с retry (АРХ-2) ---
            logger.info("Generating content...")
            meeting_date = get_meeting_date(video_path)
            user_prompt = (
                "Составь протокол по прикрепленному файлу.\n\n"
                f"Дата встречи: {meeting_date}. "
                "Если тебе необходимо указывать имена участников - проверь правильность их написания "
                "в разных частях видео. Очень важно чтоб имена были корректными. "
                "Ответ должен быть в формате Markdown, без дополнительных комментариев от себя."
            )
            system_instruction = agent.get("prompt", "")
            file_parts = [
                types.Part.from_uri(file_uri=uf.uri, mime_type=uf.mime_type)
                for uf in ready_files
            ]
            contents = file_parts + [user_prompt]

            response = None
            last_error = None
            for attempt in range(_MAX_RETRIES):
                if self._is_cancelled:
                    return
                try:
                    response = client.models.generate_content(
                        model=self.config.get("model_name"),
                        contents=contents,
                        config=types.GenerateContentConfig(
                            system_instruction=system_instruction
                        ),
                    )
                    break  # успех
                except Exception as e:
                    last_error = e
                    is_rate_limit = any(
                        tag in str(e) for tag in ("429", "RESOURCE_EXHAUSTED", "quota")
                    )
                    if attempt < _MAX_RETRIES - 1 and is_rate_limit:
                        delay = _RETRY_BASE_SECS * (2 ** attempt)
                        logger.warning(
                            f"Rate limit hit (attempt {attempt + 1}/{_MAX_RETRIES}), "
                            f"retrying in {delay}s..."
                        )
                        if not self._sleep_cancellable(delay):
                            return
                    else:
                        raise  # не rate-limit или исчерпали retries

            if response is None:
                raise Exception(f"generate_content failed after {_MAX_RETRIES} attempts: {last_error}")

            # --- Токены ---
            if response.usage_metadata:
                total_tokens = response.usage_metadata.total_token_count

            # --- Сохранение ---
            txt_path = f"{self.session_base_path}_protocol_{self.agent_id}.txt"
            if not response.text:
                raise Exception("AI вернул пустой ответ (response.text is None)")

            with open(txt_path, "w", encoding="utf-8") as f:
                f.write(response.text)

            self.finished_signal.emit(
                True, "Готово!",
                f"Протокол сохранен: {os.path.basename(txt_path)}",
                base_name, self.agent_id, total_tokens,
            )

        except Exception as e:
            logger.exception("AI Worker failed")
            base_n = os.path.basename(self.session_base_path) if hasattr(self, "session_base_path") else ""
            self.finished_signal.emit(False, "AI Ошибка", str(e)[:200], base_n, self.agent_id, 0)

        finally:
            # УТ-4: удаляем ВСЕ загруженные файлы (не только "ready"),
            # чтобы не оставлять мусор в Gemini Cloud при ошибке/отмене.
            if client and uploaded_files:
                for uf in uploaded_files:
                    try:
                        client.files.delete(name=uf.name)
                    except Exception as e:
                        logger.warning(f"Failed to delete uploaded file {uf.name}: {e}")
