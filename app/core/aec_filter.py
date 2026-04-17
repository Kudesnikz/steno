# Copyright 2020 ewan xu<ewan_xu@outlook.com>
# Licensed under the Apache License, Version 2.0 (the "License");
# (Modified for meetAssistant)

import numpy as np
from numpy.fft import rfft as fft
from numpy.fft import irfft as ifft
import wave
import struct

class PFDKF:
    """ Partitioned-Block-Based Frequency Domain Kalman Filter """
    def __init__(self, N, M, A=0.999, P_initial=1e+2, partial_constrain=True):
        self.N = N
        self.M = M
        self.N_freq = 1 + M
        self.N_fft = 2 * M
        self.A2 = A**2
        self.partial_constrain = partial_constrain
        self.p = 0

        self.x = np.zeros(shape=(2 * self.M), dtype=np.float32)
        self.P = np.full((self.N, self.N_freq), P_initial)
        # Using complex64 works well, but we'll stick to complex128 for precision here
        self.X = np.zeros((N, self.N_freq), dtype=complex)
        self.window = np.hanning(self.M)
        self.H = np.zeros((self.N, self.N_freq), dtype=complex)

    def filt(self, x, d):
        assert len(x) == self.M
        self.x[self.M:] = x
        X = fft(self.x)
        self.X[1:] = self.X[:-1]
        self.X[0] = X
        self.x[:self.M] = self.x[self.M:]
        Y = np.sum(self.H * self.X, axis=0)
        y = ifft(Y)[self.M:]
        e = d - y
        return e

    def update(self, e):
        e_fft = np.zeros(shape=(self.N_fft,), dtype=np.float32)
        e_fft[self.M:] = e * self.window
        E = fft(e_fft)
        X2 = np.sum(np.abs(self.X)**2, axis=0)
        Pe = 0.5 * self.P * X2 + np.abs(E)**2 / self.N
        mu = self.P / (Pe + 1e-10)
        self.P = self.A2 * (1 - 0.5 * mu * X2) * self.P + (1 - self.A2) * np.abs(self.H)**2
        G = mu * self.X.conj()
        self.H += E * G

        if self.partial_constrain:
            h = ifft(self.H[self.p])
            h[self.M:] = 0
            self.H[self.p] = fft(h)
            self.p = (self.p + 1) % self.N
        else:
            for p in range(self.N):
                h = ifft(self.H[p])
                h[self.M:] = 0
                self.H[p] = fft(h)

def process_aec(mic_frames, ref_frames, sample_rate=16000):
    """
    Применяет AEC (PFDKF) к двум аудиосигналами.
    mic_frames: numpy массив микрофона (голос + эхо)
    ref_frames: numpy массив reference signal (системный звук)
    """
    if len(mic_frames) == 0 or len(ref_frames) == 0:
        return mic_frames

    # Синхронизация длин
    min_len = min(len(mic_frames), len(ref_frames))
    x = ref_frames[:min_len].astype(np.float32)
    d = mic_frames[:min_len].astype(np.float32)

    # Нормализация
    max_d = np.max(np.abs(d))
    max_x = np.max(np.abs(x))
    if max_d == 0 or max_x == 0:
        return mic_frames
    
    # Чтобы фильтр не сошел с ума от разных амплитуд, приведем X к шкале D
    scale = np.sqrt(np.mean(d**2) + 1e-10) / np.sqrt(np.mean(x**2) + 1e-10)
    x = x * scale

    # Параметры фильтра (M=64 для 16kHz - это 256*64 = 16384 семпла ~ 1 сек хвост), N=8
    # Если задержка меньше, можно M=32
    M = 256
    N = 8
    
    ft = PFDKF(N, M, A=0.999, P_initial=1e+2, partial_constrain=True)
    num_block = len(x) // M

    e = np.zeros(num_block * M, dtype=np.float32)
    for n in range(num_block):
        x_n = x[n * M:(n + 1) * M]
        d_n = d[n * M:(n + 1) * M]
        e_n = ft.filt(x_n, d_n)
        ft.update(e_n)
        e[n * M:(n + 1) * M] = e_n

    # Возвращаем очищенный D
    return e
