import re

with open('app/core/recorder.py', 'r') as f:
    text = f.read()

replacement = """        # Включаем AEC (Voice Processing)
        if hasattr(input_node, "setVoiceProcessingEnabled_error_"):
            success, err = input_node.setVoiceProcessingEnabled_error_(True, None)
            if not success:
                logger.warning(f"Voice Processing not enabled: {err}")
            else:
                try:
                    # Пытаемся отключить/минимизировать ducking (приглушение других приложений)
                    import AVFAudio
                    # 10 = AVAudioVoiceProcessingOtherAudioDuckingLevelMin
                    # 0 = Отключение (если поддерживается undocumented)
                    cfg = AVFAudio.AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking=True, duckingLevel=10)
                    input_node.setVoiceProcessingOtherAudioDuckingConfiguration_(cfg)
                    logger.info("Ducking configuration applied (Advanced=True, Level=10)")
                except Exception as e:
                    logger.warning(f"Could not configure ducking: {e}")"""

text = re.sub(
    r"        # Включаем AEC \(Voice Processing\)\n\s*if hasattr\(input_node, \"setVoiceProcessingEnabled_error_\"\):\n\s*success, err = input_node\.setVoiceProcessingEnabled_error_\(True, None\)\n\s*if not success:\n\s*logger\.warning\(f\"Voice Processing not enabled: \{err\}\"\)",
    replacement,
    text
)

with open('app/core/recorder.py', 'w') as f:
    f.write(text)
print("Updated recorder.py with ducking config")
