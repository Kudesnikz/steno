import traceback
try:
    import AVFAudio
    import AVFoundation as AVF
    import ctypes
    import ctypes.util
    import struct

    audio_toolbox = ctypes.cdll.LoadLibrary(ctypes.util.find_library('AudioToolbox'))
    AudioUnitSetProperty = audio_toolbox.AudioUnitSetProperty
    AudioUnitSetProperty.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32]
    AudioUnitSetProperty.restype = ctypes.c_int32

    engine = AVF.AVAudioEngine.alloc().init()
    inp = engine.inputNode()
    inp.setVoiceProcessingEnabled_error_(True, None)

    au_ptr = inp.audioUnit()
    au_address = au_ptr.pointerAsInteger
    au_void_p = ctypes.c_void_p(au_address)

    def try_set(prop_id, val_type, val):
        v = val_type(val)
        res = AudioUnitSetProperty(au_void_p, prop_id, 0, 0, ctypes.byref(v), ctypes.sizeof(v))
        err_str = "?"
        if res != 0:
            try: err_str = struct.pack('>I', res & 0xFFFFFFFF).decode('ascii', errors='ignore')
            except: pass
        print(f"Prop {prop_id} size {ctypes.sizeof(v)} type {val_type.__name__}: {res} ({err_str})")

    print("kAUVoiceIOProperty_DuckNonVoiceAudio (UInt32=0):")
    try_set(2108, ctypes.c_uint32, 0)
    print("kAUVoiceIOProperty_DuckNonVoiceAudio (UInt32=1):")
    try_set(2108, ctypes.c_uint32, 1)

    engine.stop()
except Exception as e:
    traceback.print_exc()
