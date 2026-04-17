import AVFAudio
import AVFoundation as AVF
import ctypes
import ctypes.util
import traceback

try:
    audio_toolbox = ctypes.cdll.LoadLibrary(ctypes.util.find_library('AudioToolbox'))

    AudioUnitSetProperty = audio_toolbox.AudioUnitSetProperty
    AudioUnitSetProperty.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_uint32,
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.c_uint32
    ]
    AudioUnitSetProperty.restype = ctypes.c_int32

    engine = AVF.AVAudioEngine.alloc().init()
    inp = engine.inputNode()
    inp.setVoiceProcessingEnabled_error_(True, None)

    au_ptr = inp.audioUnit()
    # It might be a method, so call it if it's callable
    if callable(getattr(au_ptr, 'pointerAsInteger', None)):
        au_address = au_ptr.pointerAsInteger()
    else:
        au_address = getattr(au_ptr, 'pointerAsInteger', 0)
        
    print("Address:", hex(au_address))
    au_void_p = ctypes.c_void_p(au_address)

    disable_ducking = ctypes.c_uint32(0)
    res = AudioUnitSetProperty(
        au_void_p,
        2108, # kAUVoiceIOProperty_DuckNonVoiceAudio
        0, # kAudioUnitScope_Global
        0,
        ctypes.byref(disable_ducking),
        ctypes.sizeof(disable_ducking)
    )
    print("AudioUnitSetProperty result:", res)
    engine.stop()
except Exception as e:
    traceback.print_exc()
