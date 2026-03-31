import os
import re
import json
from datetime import datetime

class MeetingSession:
    def __init__(self, base_name, base_path):
        self.base_name = base_name
        self.base_path = base_path # Путь без расширения
        
        # Основные файлы
        self.video_path = f"{base_path}.mp4"
        self.mic_path = f"{base_path}_mic.m4a"
        self.json_path = f"{base_path}.json"
        
        # Динамический список аудиофайлов (m4a, mp3, wav, etc.)
        self.audio_files = []
        
        # Словарь протоколов вида { "agent_id": "путь_к_файлу" }
        self.protocols = {}
        
        self.custom_name = None
        # Расширенные метаданные
        self.recording_info = None  # dict или None
        self.reports_info = None    # list[dict] или None
        self._load_metadata()

    def _load_metadata(self):
        if os.path.exists(self.json_path):
            try:
                with open(self.json_path, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                    self.custom_name = data.get("name")
                    self.recording_info = data.get("recording")
                    self.reports_info = data.get("reports")
            except Exception:
                pass

    def rename(self, new_name):
        self.custom_name = new_name
        data = {}
        if os.path.exists(self.json_path):
            try:
                with open(self.json_path, 'r', encoding='utf-8') as f:
                    data = json.load(f)
            except Exception:
                pass
        
        data["name"] = new_name
        try:
            with open(self.json_path, 'w', encoding='utf-8') as f:
                json.dump(data, f, ensure_ascii=False, indent=4)
        except Exception:
            pass
        
    @property
    def has_video(self):
        return os.path.exists(self.video_path)

    @property
    def has_mic(self):
        # Оставляем для совместимости, но теперь лучше смотреть в self.audio_files
        return os.path.exists(self.mic_path)
    
    @property
    def display_name(self):
        if self.custom_name:
            return self.custom_name
            
        # Meet_24.06.2024_15:30:00 -> 24.06.2024 15:30:00
        match = re.search(r"Meet_(\d{2}\.\d{2}\.\d{4}_\d{2}:\d{2}:\d{2})", self.base_name)
        if match:
            return match.group(1).replace("_", " ")
        
        # Попробуем взять время изменения видеофайла, если парсинг не удался
        if self.has_video:
            try:
                dt = datetime.fromtimestamp(os.path.getmtime(self.video_path))
                return dt.strftime("%d.%m.%Y %H:%M:%S")
            except Exception:
                pass
        return self.base_name

    @property
    def total_size_mb(self):
        total_size = 0
        try:
            if self.has_video:
                total_size += os.path.getsize(self.video_path)
            if self.has_mic:
                total_size += os.path.getsize(self.mic_path)
            for af in self.audio_files:
                if os.path.exists(af) and af != self.mic_path:
                    total_size += os.path.getsize(af)
            for pf in self.protocols.values():
                if os.path.exists(pf):
                    total_size += os.path.getsize(pf)
        except Exception:
            pass
        return total_size / (1024 * 1024)
        
    def add_protocol(self, agent_id, filepath):
        self.protocols[agent_id] = filepath


class SessionManager:
    def __init__(self, save_dir):
        self.save_dir = save_dir
        
    def scan_sessions(self):
        """
        Сканирует папку и возвращает список объектов MeetingSession, 
        отсортированный по дате создания (новые сверху).
        """
        if not os.path.exists(self.save_dir):
            return []
            
        sessions_map = {}
        
        # Сканируем все файлы
        for filename in os.listdir(self.save_dir):
            if filename.startswith("Meet_") and not filename.startswith("._"): # игнор мак-файлов
                
                # Парсим базовое имя
                # Файлы могут быть:
                # Meet_XXX.mp4
                # Meet_XXX_mic.m4a
                # Meet_XXX_protocol_YYY.txt
                
                match = re.match(r"(Meet_\d{2}\.\d{2}\.\d{4}_\d{2}:\d{2}:\d{2})", filename)
                if not match:
                    # Попробуем старый формат без времени, если был
                    match = re.match(r"(Meet_\d{2}\.\d{2}\.\d{4})", filename)
                    if not match:
                        continue
                        
                base_name = match.group(1)
                
                if base_name not in sessions_map:
                    base_path = os.path.join(self.save_dir, base_name)
                    sessions_map[base_name] = MeetingSession(base_name, base_path)
                    
                # Если это протокол, добавим его
                protocol_match = re.search(rf"{re.escape(base_name)}_protocol_(.+)\.txt$", filename)
                if protocol_match:
                    agent_id = protocol_match.group(1)
                    sessions_map[base_name].add_protocol(agent_id, os.path.join(self.save_dir, filename))
                    
                # Старые протоколы без агента (из предыдущей версии)
                if filename == f"{base_name}_protocol.txt":
                    sessions_map[base_name].add_protocol("default", os.path.join(self.save_dir, filename))
                
                # Поиск аудиофайлов (микрофонов и дополнительных)
                if filename.endswith(".m4a") or filename.endswith(".mp3") or filename.endswith(".wav"):
                    if filename.startswith(base_name):
                        sessions_map[base_name].audio_files.append(os.path.join(self.save_dir, filename))
                    
        # Фильтруем те, где есть видео
        valid_sessions = [s for s in sessions_map.values() if s.has_video]
        
        # Сортируем по дате изменения видео (новые сверху)
        valid_sessions.sort(key=lambda s: os.path.getmtime(s.video_path), reverse=True)
        
        return valid_sessions

    def delete_session(self, base_name):
        """
        Удаляет все файлы, относящиеся к сессии (начинающиеся с base_name).
        """
        if not os.path.exists(self.save_dir):
            return

        for filename in os.listdir(self.save_dir):
            if filename.startswith(base_name):
                file_path = os.path.join(self.save_dir, filename)
                try:
                    os.remove(file_path)
                except Exception as e:
                    # print(f"Failed to delete file {file_path}: {e}") # Use logger in future
                    pass 

