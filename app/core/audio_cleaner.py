import os
import subprocess
import logging
import numpy as np
from app.core.config import ConfigManager
from app.core.aec_filter import process_aec

logger = logging.getLogger(__name__)

class AudioCleaner:
    """Оркестратор постобработки: извлекает ref-audio, делает AEC, применяет DeepFilterNet, микширует."""
    
    def __init__(self):
        self.config = ConfigManager.load()
        self.is_cancelled = False

        
    def _get_bin_path(self, program: str) -> str:
        import platform
        base_path = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        arch = platform.machine().lower()
        suffix = "aarch64" if arch in ('arm64', 'aarch64') else "x86_64"
        if program == 'ffmpeg':
            suffix = "arm64" if arch in ('arm64', 'aarch64') else "x86_64"
            
        bin_path = os.path.join(base_path, "bin", f"{program}_{suffix}")
        if program == 'deep-filter':
            # binary uses aarch64 instead of arm64 sometimes, but we renamed it to deep-filter_arm64 in our script
            bin_path = os.path.join(base_path, "bin", f"{program}_{'arm64' if suffix == 'aarch64' else 'x86_64'}")
            
        if os.path.exists(bin_path):
            return bin_path
        return program # fallback to system PATH

    def process(self, video_path: str, mic_wav_path: str, output_path: str, progress_callback=None):
        """
        Выполняет полный цикл очистки аудио.
        progress_callback должен принимать(percent: float, status: str)
        """
        self.is_cancelled = False
        tmp_dir = os.path.dirname(mic_wav_path)
        
        ffmpeg = self._get_bin_path("ffmpeg")
        deep_filter = self._get_bin_path("deep-filter")
        
        use_aec = self.config.get("echo_cancellation_enabled", True)
        use_df = self.config.get("noise_reduction_enabled", False)
        
        sys_vol = self.config.get("sys_volume", 1.0)
        
        # Жёстко заданный коэффициент усиления микрофона на этапе обработки
        mic_vol = 1.2
        ref_wav = os.path.join(tmp_dir, "ref_16k.wav")
        mic_16k_wav = os.path.join(tmp_dir, "mic_16k.wav")
        mic_aec_wav = os.path.join(tmp_dir, "mic_aec.wav")
        mic_final_wav = os.path.join(tmp_dir, "mic_final.wav")
        
        try:
            logger.info(f"AudioCleaner.process(): video={video_path}, mic={mic_wav_path}, use_aec={use_aec}, use_df={use_df}")
            if not os.path.exists(mic_wav_path):
                logger.error(f"Mic WAV not found: {mic_wav_path}")
                return False
            logger.info(f"Mic WAV size: {os.path.getsize(mic_wav_path)} bytes")
            
            if progress_callback: progress_callback(10, ("Извлечение аудио потоков..." if use_aec or use_df else "Подготовка аудио..."))

            
            # Если нужно что-то чистить, конвертируем в 16k mono
            if use_aec or use_df:
                # Извлекаем reference
                subprocess.run([
                    ffmpeg, "-y", "-i", video_path, 
                    "-map", "0:a?", "-c:a", "pcm_s16le", "-ar", "16000", "-ac", "1", ref_wav
                ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                
                # Конвертим mic (он мб 44.1k/48k stereo)
                subprocess.run([
                    ffmpeg, "-y", "-i", mic_wav_path,
                    "-c:a", "pcm_s16le", "-ar", "16000", "-ac", "1", mic_16k_wav
                ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            
            current_mic = mic_16k_wav if (use_aec or use_df) else mic_wav_path

            # Шаг 1: AEC
            if use_aec and not self.is_cancelled:
                if progress_callback: progress_callback(30, "Подавление эха (AEC)...")
                if os.path.exists(ref_wav) and os.path.exists(mic_16k_wav):
                    import scipy.io.wavfile as wavfile
                    sr_mic, mic_data = wavfile.read(mic_16k_wav)
                    sr_ref, ref_data = wavfile.read(ref_wav)
                    if len(mic_data) > 0 and len(ref_data) > 0:
                        clean_data = process_aec(mic_data, ref_data, sample_rate=16000)
                        # Нормализация
                        clean_data = np.clip(clean_data, -32768, 32767).astype(np.int16)
                        wavfile.write(mic_aec_wav, 16000, clean_data)
                        current_mic = mic_aec_wav

            # Шаг 2: DeepFilterNet
            if use_df and not self.is_cancelled:
                if progress_callback: progress_callback(60, "Нейросетевая очистка шума...")
                out_dir = os.path.join(tmp_dir, "df_out")
                os.makedirs(out_dir, exist_ok=True)
                
                # deep-filter сохраняет файл с таким же именем в out_dir
                subprocess.run([
                    deep_filter, current_mic, "-o", out_dir
                ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                
                df_out_file = os.path.join(out_dir, os.path.basename(current_mic))
                if os.path.exists(df_out_file):
                    current_mic = df_out_file

            if self.is_cancelled:
                return False

            # Шаг 3: Микширование обратно в MP4
            if progress_callback: progress_callback(85, "Окончательное сведение...")
            
            # Проверяем, есть ли звук в видео
            has_sys_audio = os.path.exists(ref_wav) and os.path.getsize(ref_wav) > 44
            
            filter_complex = f"[1:a]volume={mic_vol}[mic]; "
            if has_sys_audio:
                filter_complex += f"[0:a]volume={sys_vol}[sys]; [sys][mic]amix=inputs=2:duration=first[a]"
            else:
                filter_complex += "[mic]anull[a]" # только микрофон
            
            tmp_video_path = output_path + ".tmp.mp4"
            cmd = [
                ffmpeg, "-y",
                "-i", video_path,
                "-i", current_mic,
                "-filter_complex", filter_complex,
                "-map", "0:v", "-map", "[a]",
                "-c:v", "copy",
                "-c:a", "aac", "-b:a", "192k",
                tmp_video_path
            ]
            subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            
            if os.path.exists(tmp_video_path):
                os.replace(tmp_video_path, output_path)
            
            if progress_callback: progress_callback(100, "Готово!")
            return True
            
        except Exception as e:
            logger.error(f"Error in AudioCleaner: {e}", exc_info=True)
            return False
        finally:
            # Cleanup temp files
            for f in [ref_wav, mic_16k_wav, mic_aec_wav, mic_final_wav]:
                if os.path.exists(f):
                    try: os.remove(f)
                    except: pass
            df_out_dir = os.path.join(tmp_dir, "df_out")
            if os.path.exists(df_out_dir):
                import shutil
                shutil.rmtree(df_out_dir, ignore_errors=True)
