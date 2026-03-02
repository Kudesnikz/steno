import os
import subprocess
import threading
import numpy as np
import sounddevice as sd
import time
from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QPushButton, QLabel, 
    QSlider, QScrollArea, QFrame, QSizePolicy, QGridLayout
)
from PyQt6.QtCore import Qt, QTimer, pyqtSignal, QObject, QEvent
from PyQt6.QtGui import QImage, QPixmap
import qtawesome as qta


# --- Движок плеера ---

class PlayerEngine(QObject):
    frame_ready = pyqtSignal(QImage)
    time_updated = pyqtSignal(float)
    duration_updated = pyqtSignal(float)

    def __init__(self, video_path, audio_paths):
        super().__init__()
        self.video_path = video_path
        self.audio_paths = audio_paths  # Список путей (видео идет первым или отдельно)
        
        # Настройки видео
        self.fps = 30.0
        self.v_width = 854
        self.v_height = 480
        self.frame_size = self.v_width * self.v_height * 3
        
        # Настройки аудио
        self.sample_rate = 44100
        self.channels = 2
        self.chunk_size = 2048
        
        # Состояние
        self.is_playing = False
        self.is_paused = False
        self.audio_time = 0.0
        self.video_frame = 0
        self.duration = self._get_duration(video_path)
        
        # Громкости и Mute (по индексам: 0 - основное видео, 1..N - доп. аудио)
        self.volumes = [1.0] * (len(audio_paths) + 1)
        self.mutes = [False] * (len(audio_paths) + 1)
        
        # Процессы
        self.video_proc = None
        self.audio_procs = []
        
        # Потоки
        self.audio_thread = None
        self.video_thread = None
        self.stop_event = threading.Event()
        
        # Аудио поток вывода
        self.sd_stream = None

    def _get_ffmpeg_path(self):
        # Ищем ffmpeg в bin/ffmpeg относительно текущей директории
        # Use os.path.dirname(os.path.abspath(__file__)) to get correct path even in .app bundle
        import sys
        if getattr(sys, 'frozen', False):
             # For PyInstaller/py2app
             base_path = sys._MEIPASS if hasattr(sys, '_MEIPASS') else os.path.dirname(os.path.abspath(sys.argv[0]))
             # In .app bundle resources are usually in Contents/Resources
             if 'Contents/MacOS' in base_path:
                  base_path = os.path.abspath(os.path.join(base_path, "../Resources"))
        else:
             # For development
             base_path = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../"))

        ffmpeg_bin = os.path.join(base_path, "bin", "ffmpeg")
        
        if os.path.exists(ffmpeg_bin):
            try:
                # Проверяем, рабочий ли бинарник (на маке может упасть из-за dyld)
                subprocess.run([ffmpeg_bin, "-version"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
                return ffmpeg_bin
            except Exception:
                pass
        return "ffmpeg" # fallback on system path

    def _get_duration(self, filepath):
        if not filepath or not os.path.exists(filepath):
            return 0.0
        try:
            cmd = [self._get_ffmpeg_path(), "-i", filepath]
            out = subprocess.run(cmd, stderr=subprocess.PIPE, text=True)
            for line in out.stderr.split('\n'):
                if "Duration:" in line:
                    time_str = line.split("Duration:")[1].split(",")[0].strip()
                    h, m, s = time_str.split(":")
                    return float(h) * 3600 + float(m) * 60 + float(s)
        except Exception as e:
            pass # Logger not available in this scope, but ignoring is fine here for duration check
        return 0.0

    def start(self, start_time=0.0):
        self.stop()
        self.stop_event.clear()
        self.audio_time = start_time
        self.video_frame = int(start_time * self.fps)
        self.is_playing = True
        self.is_paused = False
        
        ffmpeg_bin = self._get_ffmpeg_path()
        
        # Запуск видео-процесса
        if self.video_path and os.path.exists(self.video_path):
            v_cmd = [
                ffmpeg_bin, 
                "-ss", str(start_time),
                "-i", self.video_path,
                "-f", "image2pipe",
                "-pix_fmt", "rgb24",
                "-r", str(self.fps),
                "-s", f"{self.v_width}x{self.v_height}",
                "-vcodec", "rawvideo",
                "-loglevel", "quiet",
                "-"
            ]
            self.video_proc = subprocess.Popen(v_cmd, stdout=subprocess.PIPE, bufsize=self.frame_size * 10)
        
        # Запуск аудио-процессов
        all_audios = [self.video_path] + self.audio_paths
        for i, audio_file in enumerate(all_audios):
            if not audio_file or not os.path.exists(audio_file):
                self.audio_procs.append(None)
                continue
            
            # Добавляем компенсацию задержки для дополнительных аудио (микрофоны, i >= 1)
            # Если звук микрофона запаздывает на 0.3с, мы сдвигаем его старт вперед,
            # чтобы он начал играть с 0.3с и "догнал" основное видео.
            current_start = start_time
            if i >= 1:
                current_start = start_time + 0.35
                
            a_cmd = [
                ffmpeg_bin,
                "-ss", str(current_start),
                "-i", audio_file,
                "-f", "s16le",
                "-ac", str(self.channels),
                "-ar", str(self.sample_rate),
                "-loglevel", "quiet",
                "-"
            ]
            proc = subprocess.Popen(a_cmd, stdout=subprocess.PIPE, bufsize=self.chunk_size * self.channels * 2 * 10)
            self.audio_procs.append(proc)
            
        # Запуск аудио-стрима
        try:
            self.sd_stream = sd.OutputStream(
                samplerate=self.sample_rate, 
                channels=self.channels, 
                dtype='int16'
            )
            self.sd_stream.start()
        except Exception as e:
            # print("Ошибка запуска sounddevice:", e) # Removed print, logger not easily available here inside Engine
            self.sd_stream = None

        # Запуск потоков
        self.audio_thread = threading.Thread(target=self._audio_loop, daemon=True)
        self.audio_thread.start()
        
        self.video_thread = threading.Thread(target=self._video_loop, daemon=True)
        self.video_thread.start()

    def stop(self):
        self.is_playing = False
        self.stop_event.set()
        
        if self.sd_stream:
            try:
                self.sd_stream.stop()
                self.sd_stream.close()
            except:
                pass
            self.sd_stream = None
            
        if self.video_proc:
            self.video_proc.kill()
            self.video_proc = None
            
        for proc in self.audio_procs:
            if proc:
                proc.kill()
        self.audio_procs.clear()
        
        if self.audio_thread and self.audio_thread.is_alive():
            self.audio_thread.join(timeout=0.5)
        if self.video_thread and self.video_thread.is_alive():
            self.video_thread.join(timeout=0.5)

    def toggle_pause(self):
        if not self.is_playing:
            self.start(self.audio_time)
            return True # is playing now
            
        self.is_paused = not self.is_paused
        return not self.is_paused # return true if playing

    def seek(self, time_sec):
        # Чтобы сделать seek, нам нужно перезапустить процессы
        was_paused = self.is_paused
        was_playing = self.is_playing
        
        if was_playing:
            self.start(time_sec)
            self.is_paused = was_paused
            self.time_updated.emit(self.audio_time)
        else:
            self.audio_time = time_sec
            self.time_updated.emit(self.audio_time)
            # Извлекаем 1 кадр для превью
            self._extract_preview(time_sec)

    def _extract_preview(self, time_sec):
        if not self.video_path or not os.path.exists(self.video_path):
            return
        cmd = [
            self._get_ffmpeg_path(), "-ss", str(time_sec), "-i", self.video_path,
            "-vframes", "1", "-f", "image2pipe", "-pix_fmt", "rgb24",
            "-s", f"{self.v_width}x{self.v_height}", "-vcodec", "rawvideo", "-loglevel", "quiet", "-"
        ]
        try:
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if len(proc.stdout) >= self.frame_size:
                img = QImage(proc.stdout[:self.frame_size], self.v_width, self.v_height, self.v_width * 3, QImage.Format.Format_RGB888)
                self.frame_ready.emit(img.copy())
        except Exception as e:
            pass # print("Preview extraction error:", e)

    def _audio_loop(self):
        bytes_per_sample = 2 * self.channels # 16bit = 2 bytes
        read_bytes = self.chunk_size * bytes_per_sample
        empty_chunk = np.zeros((self.chunk_size, self.channels), dtype=np.int16)
        
        while not self.stop_event.is_set():
            if self.is_paused:
                time.sleep(0.05)
                continue
                
            chunks_to_mix = []
            eof_count = 0
            
            for i, proc in enumerate(self.audio_procs):
                if proc is None:
                    continue
                    
                try:
                    raw_data = proc.stdout.read(read_bytes)
                except:
                    raw_data = b''
                    
                if len(raw_data) < read_bytes:
                    eof_count += 1
                    
                if len(raw_data) > 0:
                    # Pad if needed
                    if len(raw_data) < read_bytes:
                        raw_data += b'\x00' * (read_bytes - len(raw_data))
                        
                    arr = np.frombuffer(raw_data, dtype=np.int16).reshape(-1, self.channels)
                    
                    # Применяем громкость
                    if self.mutes[i]:
                        vol = 0.0
                    else:
                        vol = self.volumes[i]
                        
                    if vol != 1.0:
                        arr = (arr * vol).astype(np.int16)
                        
                    chunks_to_mix.append(arr)
                    
            if not chunks_to_mix:
                if eof_count >= len([p for p in self.audio_procs if p is not None]):
                    self.stop_event.set() # Все кончилось
                    self.is_playing = False # Mark as stopped
                else:
                    time.sleep(0.01)
                continue
                
            # Микшируем
            if len(chunks_to_mix) == 1:
                mixed = chunks_to_mix[0]
            else:
                # Конвертируем в int32 для предотвращения переполнения
                mixed32 = np.sum([c.astype(np.int32) for c in chunks_to_mix], axis=0)
                mixed = np.clip(mixed32, -32768, 32767).astype(np.int16)
                
            if self.sd_stream:
                try:
                    self.sd_stream.write(mixed)
                except sd.PortAudioError:
                    pass
                    
            # Обновляем время
            self.audio_time += self.chunk_size / self.sample_rate
            self.time_updated.emit(self.audio_time)

    def _video_loop(self):
        if not self.video_proc:
            return
            
        while not self.stop_event.is_set():
            if self.is_paused:
                time.sleep(0.03)
                continue
                
            target_frame = int(self.audio_time * self.fps)
            
            if self.video_frame < target_frame:
                try:
                    raw_frame = self.video_proc.stdout.read(self.frame_size)
                    if len(raw_frame) == self.frame_size:
                        self.video_frame += 1
                        # Отправляем кадр только если догнали
                        if self.video_frame >= target_frame - 1:
                            img = QImage(raw_frame, self.v_width, self.v_height, self.v_width * 3, QImage.Format.Format_RGB888)
                            self.frame_ready.emit(img.copy())
                    else:
                        time.sleep(0.01)
                except Exception:
                    time.sleep(0.01)
            else:
                time.sleep(0.01)

# --- UI Компоненты ---

class AudioTrackMixer(QFrame):
    volume_changed = pyqtSignal(int, float) # track_index, volume (0.0 - 1.0)
    mute_toggled = pyqtSignal(int, bool)    # track_index, is_muted

    def __init__(self, track_index, title):
        super().__init__()
        self.track_index = track_index
        self.is_muted = False
        
        self.setStyleSheet("""
            QFrame {
                background: #f5f5f7;
                border-radius: 8px;
                padding: 4px;
                margin-bottom: 4px;
            }
        """)
        
        layout = QHBoxLayout(self)
        layout.setContentsMargins(10, 8, 10, 8)
        
        # Название
        self.lbl_title = QLabel(title)
        self.lbl_title.setMinimumWidth(100)
        self.lbl_title.setStyleSheet("font-weight: 500; color: #1d1d1f;")
        layout.addWidget(self.lbl_title)
        
        # Кнопка Mute
        self.btn_mute = QPushButton()
        self.btn_mute.setIcon(qta.icon('fa5s.volume-up', color='#1d1d1f'))
        self.btn_mute.setFixedSize(32, 32)
        self.btn_mute.setCheckable(True)
        self.btn_mute.setStyleSheet("""
            QPushButton {
                background: transparent;
                border: none;
                border-radius: 16px;
            }
            QPushButton:hover { background: #e5e5ea; }
            QPushButton:checked { background: #ff3b30; }
        """)
        self.btn_mute.clicked.connect(self._on_mute_clicked)
        layout.addWidget(self.btn_mute)
        
        # Слайдер громкости
        self.slider = QSlider(Qt.Orientation.Horizontal)
        self.slider.setRange(0, 100)
        self.slider.setValue(100)
        self.slider.setStyleSheet("""
            QSlider::groove:horizontal {
                border-radius: 2px;
                height: 4px;
                background: #d2d2d7;
            }
            QSlider::handle:horizontal {
                background: #ffffff;
                border: 1px solid #d2d2d7;
                width: 16px;
                height: 16px;
                margin: -6px 0;
                border-radius: 8px;
            }
            QSlider::sub-page:horizontal {
                background: #007aff;
                border-radius: 2px;
            }
        """)
        self.slider.valueChanged.connect(self._on_volume_changed)
        layout.addWidget(self.slider)

    def _on_mute_clicked(self, checked):
        self.is_muted = checked
        icon = 'fa5s.volume-mute' if checked else 'fa5s.volume-up'
        color = '#ffffff' if checked else '#1d1d1f'
        self.btn_mute.setIcon(qta.icon(icon, color=color))
        self.mute_toggled.emit(self.track_index, checked)

    def _on_volume_changed(self, value):
        self.volume_changed.emit(self.track_index, value / 100.0)

    def set_volume(self, vol_float):
        self.slider.blockSignals(True)
        self.slider.setValue(int(vol_float * 100))
        self.slider.blockSignals(False)

    def set_mute(self, is_muted):
        self.btn_mute.blockSignals(True)
        self.btn_mute.setChecked(is_muted)
        icon = 'fa5s.volume-mute' if is_muted else 'fa5s.volume-up'
        color = '#ffffff' if is_muted else '#1d1d1f'
        self.btn_mute.setIcon(qta.icon(icon, color=color))
        self.is_muted = is_muted
        self.btn_mute.blockSignals(False)


class PlayerWidget(QWidget):
    config_changed = pyqtSignal(str, object)  # key, value

    def __init__(self, session, initial_config=None):
        super().__init__()
        self.session = session
        self.initial_config = initial_config or {}
        self.is_sliding = False
        
        # Собираем доп аудиофайлы
        # Если self.session.audio_files не существует, используем только mic_path
        self.extra_audio = getattr(session, "audio_files", [])
        if not self.extra_audio and session.has_mic:
            self.extra_audio = [session.mic_path]
            
        self.engine = PlayerEngine(session.video_path, self.extra_audio)
        self.engine.frame_ready.connect(self._update_frame)
        self.engine.time_updated.connect(self._update_time)
        
        self.setup_ui()
        
        # Извлекаем превью 0-й секунды
        QTimer.singleShot(100, lambda: self.engine.seek(0))

    def setup_ui(self):
        main_layout = QVBoxLayout(self)
        main_layout.setContentsMargins(0, 0, 0, 0)
        main_layout.setSpacing(0)
        
        # --- Видео область ---
        self.video_container = QWidget()
        self.video_container.setStyleSheet("background-color: #000000;")
        self.video_container.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        v_layout = QVBoxLayout(self.video_container)
        v_layout.setContentsMargins(0, 0, 0, 0)
        
        self.video_label = QLabel()
        self.video_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.video_label.setMinimumSize(1, 1)
        self.video_label.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        v_layout.addWidget(self.video_label)
        
        main_layout.addWidget(self.video_container, stretch=1)
        
        # --- Панель управления плеером ---
        ctrl_panel = QWidget()
        ctrl_panel.setStyleSheet("background-color: #ffffff; border-top: 1px solid #d2d2d7;")
        ctrl_layout = QVBoxLayout(ctrl_panel)
        ctrl_layout.setContentsMargins(16, 12, 16, 12)
        ctrl_layout.setSpacing(8)
        
        # Таймлайн (Slider + Время)
        time_layout = QHBoxLayout()
        self.lbl_time = QLabel("00:00 / 00:00")
        self.lbl_time.setStyleSheet("color: #1d1d1f;")
        
        self.timeline = QSlider(Qt.Orientation.Horizontal)
        self.timeline.setRange(0, int(self.engine.duration))
        self.timeline.sliderPressed.connect(self._on_timeline_pressed)
        self.timeline.sliderReleased.connect(self._on_timeline_released)
        self.timeline.sliderMoved.connect(self._on_timeline_moved)
        self.timeline.setStyleSheet("""
            QSlider::groove:horizontal { border-radius: 2px; height: 4px; background: #e5e5ea; }
            QSlider::handle:horizontal { background: #007aff; width: 12px; height: 12px; margin: -4px 0; border-radius: 6px; }
            QSlider::sub-page:horizontal { background: #007aff; border-radius: 2px; }
        """)
        
        time_layout.addWidget(self.timeline)
        time_layout.addWidget(self.lbl_time)
        ctrl_layout.addLayout(time_layout)
        
        # Кнопки (Play)
        btn_layout = QHBoxLayout()
        self.btn_play = QPushButton()
        self.btn_play.setIcon(qta.icon('fa5s.play', color='#1d1d1f'))
        self.btn_play.setFixedSize(40, 40)
        self.btn_play.setStyleSheet("QPushButton { border: none; border-radius: 20px; background: #f5f5f7; } QPushButton:hover { background: #e5e5ea; }")
        self.btn_play.clicked.connect(self._toggle_play)
        btn_layout.addStretch()
        btn_layout.addWidget(self.btn_play)
        btn_layout.addStretch()
        ctrl_layout.addLayout(btn_layout)
        
        main_layout.addWidget(ctrl_panel)
        
        # --- Микшер ---
        mixer_scroll = QScrollArea()
        mixer_scroll.setWidgetResizable(True)
        mixer_scroll.setFrameShape(QFrame.Shape.NoFrame)
        mixer_scroll.setFixedHeight(160)
        
        mixer_container = QWidget()
        mixer_container.setStyleSheet("background-color: #ffffff;")
        self.mixer_layout = QVBoxLayout(mixer_container)
        self.mixer_layout.setContentsMargins(16, 8, 16, 8)
        self.mixer_layout.setSpacing(0)
        
        # Добавляем дорожку для видео (индекс 0)
        v_track = AudioTrackMixer(0, "Основное видео")
        
        # Установка начальных значений для видео
        v_vol = self.initial_config.get("volume_main", 1.0)
        v_mute = self.initial_config.get("mute_main", False)
        v_track.set_volume(v_vol)
        v_track.set_mute(v_mute)
        self.engine.volumes[0] = v_vol
        self.engine.mutes[0] = v_mute

        v_track.volume_changed.connect(self._set_volume)
        v_track.mute_toggled.connect(self._set_mute)
        self.mixer_layout.addWidget(v_track)
        
        # Добавляем дорожки для доп файлов (индексы 1..N)
        # Для всех микрофонов используем одни настройки volume_mic / mute_mic
        mic_vol = self.initial_config.get("volume_mic", 1.0)
        mic_mute = self.initial_config.get("mute_mic", False)

        for i, filepath in enumerate(self.extra_audio, start=1):
            name = os.path.basename(filepath)
            track = AudioTrackMixer(i, name)

            track.set_volume(mic_vol)
            track.set_mute(mic_mute)
            
            # Применяем к движку, если индекс в пределах массива
            if i < len(self.engine.volumes):
                self.engine.volumes[i] = mic_vol
                self.engine.mutes[i] = mic_mute

            track.volume_changed.connect(self._set_volume)
            track.mute_toggled.connect(self._set_mute)
            self.mixer_layout.addWidget(track)
            
        self.mixer_layout.addStretch()
        mixer_scroll.setWidget(mixer_container)
        main_layout.addWidget(mixer_scroll)
        
        self._update_time_label(0)

        # Сохраняем текущий кадр для ресайза
        self.current_frame = None
        self.video_container.installEventFilter(self)

    def eventFilter(self, source, event):
        if source == self.video_container and event.type() == QEvent.Type.Resize:
            if self.current_frame:
                self._display_frame(self.current_frame)
        return super().eventFilter(source, event)

    def _format_time(self, seconds):
        s = int(seconds)
        m = s // 60
        s = s % 60
        h = m // 60
        m = m % 60
        if h > 0:
            return f"{h:02d}:{m:02d}:{s:02d}"
        return f"{m:02d}:{s:02d}"

    def _update_time_label(self, current_sec):
        cur = self._format_time(current_sec)
        tot = self._format_time(self.engine.duration)
        self.lbl_time.setText(f"{cur} / {tot}")

    def _update_frame(self, image):
        self.current_frame = image.copy()
        self._display_frame(self.current_frame)

    def _display_frame(self, image):
        if image is None:
            return
            
        pixmap = QPixmap.fromImage(image)
        w = self.video_container.width()
        h = self.video_container.height()
        
        if w > 0 and h > 0:
            # Масштабируем с сохранением пропорций
            scaled = pixmap.scaled(
                w, h,
                Qt.AspectRatioMode.KeepAspectRatio,
                Qt.TransformationMode.SmoothTransformation
            )
            self.video_label.setPixmap(scaled)

    def _update_time(self, time_sec):
        if not self.is_sliding:
            self.timeline.blockSignals(True)
            self.timeline.setValue(int(time_sec))
            self.timeline.blockSignals(False)
            self._update_time_label(time_sec)
        
        # Check if playback stopped (due to EOF)
        if not self.engine.is_playing and not self.engine.is_paused and time_sec >= self.engine.duration - 0.5:
             self.btn_play.setIcon(qta.icon('fa5s.play', color='#1d1d1f'))

    def _on_timeline_pressed(self):
        self.is_sliding = True

    def _on_timeline_moved(self, value):
        self._update_time_label(value)

    def _on_timeline_released(self):
        self.is_sliding = False
        val = self.timeline.value()
        self.engine.seek(val)

    def _toggle_play(self):
        is_playing = self.engine.toggle_pause()
        icon = 'fa5s.pause' if is_playing else 'fa5s.play'
        self.btn_play.setIcon(qta.icon(icon, color='#1d1d1f'))

    def _set_volume(self, track_index, vol):
        if track_index < len(self.engine.volumes):
            self.engine.volumes[track_index] = vol
        
        # Сохраняем в конфиг
        if track_index == 0:
            self.config_changed.emit("volume_main", vol)
        else:
            self.config_changed.emit("volume_mic", vol)

    def _set_mute(self, track_index, is_muted):
        if track_index < len(self.engine.mutes):
            self.engine.mutes[track_index] = is_muted
            
        # Сохраняем в конфиг
        if track_index == 0:
            self.config_changed.emit("mute_main", is_muted)
        else:
            self.config_changed.emit("mute_mic", is_muted)

    def closeEvent(self, event):
        self.engine.stop()
        super().closeEvent(event)
