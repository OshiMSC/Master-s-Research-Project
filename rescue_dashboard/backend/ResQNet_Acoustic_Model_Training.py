"""
ResQNet — Acoustic Signal Classifier (Fixed Training)
======================================================
Trains CNN to detect:
  Class 0: Background noise
  Class 1: Emergency whistle (2000-4500Hz sustained tone)
  Class 2: SOS Morse (... --- ... timing pattern)

Fix: signals are generated cleanly then noise added at
controlled SNR so model sees clear difference between classes.

Run:
  pip install tensorflow librosa --break-system-packages
  python ResQNet_Acoustic_Model_Training.py
"""

import numpy as np
import json
import time
from pathlib import Path

SAMPLE_RATE  = 22050
DURATION     = 1.0
SAMPLES      = int(SAMPLE_RATE * DURATION)
N_MELS       = 64
HOP_LENGTH   = 256
N_FFT        = 1024
N_PER_CLASS  = 800   # more samples = better training
EPOCHS       = 60
BATCH_SIZE   = 32

CLASSES = {0: 'background', 1: 'emergency_whistle', 2: 'sos_morse'}

print("ResQNet — Acoustic Classifier Training (Fixed)")
print("=" * 60)

# ══════════════════════════════════════════════════════════════
# SIGNAL GENERATORS
# ══════════════════════════════════════════════════════════════

def add_noise(signal, snr_db):
    """Add noise at exact SNR in dB."""
    sig_rms   = np.sqrt(np.mean(signal**2)) + 1e-10
    noise_rms = sig_rms / (10 ** (snr_db / 20))
    noise     = np.random.normal(0, noise_rms, len(signal))
    return (signal + noise).astype(np.float32)


def gen_background():
    """
    Pure background noise — NO tonal content.
    Mix of white noise, pink noise, low frequency rumble.
    """
    kind = np.random.randint(0, 3)
    if kind == 0:
        # White noise
        audio = np.random.normal(0, 1.0, SAMPLES)
    elif kind == 1:
        # Pink noise via FFT shaping
        f = np.fft.rfftfreq(SAMPLES)
        f[0] = 1
        s = np.random.randn(len(f)) + 1j * np.random.randn(len(f))
        s = s / np.sqrt(f)
        audio = np.fft.irfft(s, n=SAMPLES)
    else:
        # Low frequency rumble (below 500Hz)
        audio = np.zeros(SAMPLES, dtype=np.float32)
        for _ in range(np.random.randint(2, 5)):
            freq  = np.random.uniform(50, 500)
            t     = np.arange(SAMPLES) / SAMPLE_RATE
            audio = audio + np.sin(2 * np.pi * freq * t) * np.random.uniform(0.1, 0.5)

    # Normalise to consistent level
    audio = audio / (np.max(np.abs(audio)) + 1e-8) * 0.5
    return audio.astype(np.float32)


def gen_emergency_whistle():
    """
    Clean whistle tone at 2000-4500Hz, sustained.
    High amplitude relative to noise — clearly distinct.
    """
    t    = np.arange(SAMPLES) / SAMPLE_RATE
    freq = np.random.uniform(2200, 4200)

    # Natural wobble ±20-50Hz at 3-8Hz rate
    wobble     = np.random.uniform(20, 50)
    wobble_rate = np.random.uniform(3, 8)
    freq_t     = freq + wobble * np.sin(2 * np.pi * wobble_rate * t)

    # Phase accumulation for correct frequency modulation
    phase = np.cumsum(2 * np.pi * freq_t / SAMPLE_RATE)
    audio = np.sin(phase)

    # Add 2nd harmonic (real whistles have overtones)
    if np.random.random() > 0.4:
        audio = audio + 0.3 * np.sin(2 * phase)
    audio = audio / np.max(np.abs(audio))  # normalise to full amplitude

    # Duration: 0.5-1.0 seconds (must be sustained)
    dur   = np.random.uniform(0.5, 1.0)
    dur_s = int(dur * SAMPLE_RATE)
    start = np.random.randint(0, max(1, SAMPLES - dur_s))
    end   = min(start + dur_s, SAMPLES)

    # Envelope
    windowed = np.zeros(SAMPLES, dtype=np.float32)
    fade     = min(int(0.02 * SAMPLE_RATE), (end-start)//2)
    env      = np.ones(end-start, dtype=np.float32)
    env[:fade]  = np.linspace(0, 1, fade)
    env[-fade:] = np.linspace(1, 0, fade)
    windowed[start:end] = audio[start:end] * env * 0.9

    # Add noise at HIGH SNR (signal clearly dominant)
    snr = np.random.uniform(15, 30)  # was 8-25, now higher = cleaner signal
    return add_noise(windowed, snr)


def gen_sos_morse():
    """
    SOS morse pattern: ... --- ...
    Tone at 600-1500Hz (clearly below whistle range).
    Silence gaps between dots/dashes are distinctive.
    """
    # SOS pattern: on_ms, off_ms pairs
    unit   = np.random.uniform(80, 120)  # ms per dot
    dot    = int(unit)
    dash   = int(unit * 3)
    gap    = int(unit)       # between symbols
    lgap   = int(unit * 3)   # between letters

    pattern = [
        # S: dot dot dot
        (dot, gap), (dot, gap), (dot, lgap),
        # O: dash dash dash
        (dash, gap), (dash, gap), (dash, lgap),
        # S: dot dot dot
        (dot, gap), (dot, gap), (dot, gap),
    ]

    tone_freq = np.random.uniform(600, 1500)
    audio     = np.zeros(SAMPLES, dtype=np.float32)
    t         = np.arange(SAMPLES) / SAMPLE_RATE
    tone      = np.sin(2 * np.pi * tone_freq * t).astype(np.float32)

    pos = int(np.random.uniform(0, 0.05) * SAMPLE_RATE)  # small random offset
    for on_ms, off_ms in pattern:
        on_s  = int(on_ms * SAMPLE_RATE / 1000)
        off_s = int(off_ms * SAMPLE_RATE / 1000)
        end   = min(pos + on_s, SAMPLES)
        if pos < SAMPLES:
            seg  = end - pos
            fade = min(int(0.005 * SAMPLE_RATE), seg // 2)
            env  = np.ones(seg, dtype=np.float32)
            if fade > 0:
                env[:fade]  = np.linspace(0, 1, fade)
                env[-fade:] = np.linspace(1, 0, fade)
            audio[pos:end] = tone[pos:end] * env * 0.9
        pos += on_s + off_s
        if pos >= SAMPLES:
            break

    snr = np.random.uniform(15, 30)
    return add_noise(audio, snr)


# ══════════════════════════════════════════════════════════════
# MEL SPECTROGRAM
# ══════════════════════════════════════════════════════════════

def to_melspec(audio):
    import librosa
    mel    = librosa.feature.melspectrogram(
        y=audio.astype(np.float32),
        sr=SAMPLE_RATE, n_mels=N_MELS,
        n_fft=N_FFT, hop_length=HOP_LENGTH)
    mel_db = librosa.power_to_db(mel, ref=np.max)
    mel_n  = (mel_db - mel_db.min()) / (mel_db.max() - mel_db.min() + 1e-8)
    return mel_n.astype(np.float32)


# ══════════════════════════════════════════════════════════════
# VALIDATE SIGNALS ARE DISTINGUISHABLE
# ══════════════════════════════════════════════════════════════

def validate_signals():
    print("Validating signal generators...")
    import librosa

    freqs = librosa.mel_frequencies(
        n_mels=N_MELS, fmin=0, fmax=SAMPLE_RATE//2)
    whistle_mask = (freqs >= 2000) & (freqs <= 4500)
    sos_mask     = (freqs >= 500)  & (freqs <= 1500)

    bg_mels  = np.array([to_melspec(gen_background())     for _ in range(20)])
    wh_mels  = np.array([to_melspec(gen_emergency_whistle()) for _ in range(20)])
    sos_mels = np.array([to_melspec(gen_sos_morse())       for _ in range(20)])

    print(f"\n  Band energy comparison (higher = stronger signal in that band):")
    print(f"  {'Class':<20} {'Whistle band':>14} {'SOS band':>10} {'Overall':>10}")
    print(f"  {'-'*56}")
    for name, mels in [('background', bg_mels),
                       ('whistle', wh_mels),
                       ('sos_morse', sos_mels)]:
        wb = float(np.mean(mels[:, whistle_mask]))
        sb = float(np.mean(mels[:, sos_mask]))
        ov = float(np.mean(mels))
        print(f"  {name:<20} {wb:>14.4f} {sb:>10.4f} {ov:>10.4f}")

    # Check if classes are separable
    wh_wb  = float(np.mean(wh_mels[:, whistle_mask]))
    bg_wb  = float(np.mean(bg_mels[:, whistle_mask]))
    ratio  = wh_wb / (bg_wb + 1e-8)
    print(f"\n  Whistle/Background energy ratio in whistle band: {ratio:.2f}x")
    if ratio > 2.0:
        print("  ✓ Signals are clearly distinguishable — training should work")
    else:
        print("  ⚠ Signals may be too similar — check generator parameters")
    print()


# ══════════════════════════════════════════════════════════════
# GENERATE DATASET
# ══════════════════════════════════════════════════════════════

def generate_dataset():
    generators = {
        0: gen_background,
        1: gen_emergency_whistle,
        2: gen_sos_morse,
    }
    X, y = [], []
    for cls, gen in generators.items():
        name = CLASSES[cls]
        print(f"  Generating {N_PER_CLASS} × '{name}'...")
        for i in range(N_PER_CLASS):
            mel = to_melspec(gen())
            X.append(mel)
            y.append(cls)
            if (i+1) % 200 == 0:
                pct = int((i+1)/N_PER_CLASS*20)
                print(f"\r    [{'█'*pct}{'░'*(20-pct)}] {i+1}/{N_PER_CLASS}", end='', flush=True)
        print(f"\r    [{'█'*20}] {N_PER_CLASS}/{N_PER_CLASS} ✓")

    X = np.array(X)[..., np.newaxis]
    y = np.array(y)
    print(f"\n  Shape: {X.shape}  Labels: {np.bincount(y)}")
    return X, y


# ══════════════════════════════════════════════════════════════
# TRAIN
# ══════════════════════════════════════════════════════════════

def train(X, y):
    import tensorflow as tf
    from tensorflow import keras
    from tensorflow.keras import layers

    print(f"\n  TF {tf.__version__}  Input: {X.shape[1:]}")

    # Shuffle + split
    idx     = np.random.permutation(len(X))
    X, y    = X[idx], y[idx]
    split   = int(0.8 * len(X))
    X_tr, X_v = X[:split], X[split:]
    y_tr, y_v = y[:split], y[split:]
    print(f"  Train: {len(X_tr)}  Val: {len(X_v)}")

    # Model
    inp = keras.Input(shape=X_tr.shape[1:])
    x   = layers.Conv2D(32, (3,3), padding='same')(inp)
    x   = layers.BatchNormalization()(x)
    x   = layers.Activation('relu')(x)
    x   = layers.MaxPooling2D((2,2))(x)
    x   = layers.Dropout(0.15)(x)

    x   = layers.Conv2D(64, (3,3), padding='same')(x)
    x   = layers.BatchNormalization()(x)
    x   = layers.Activation('relu')(x)
    x   = layers.MaxPooling2D((2,2))(x)
    x   = layers.Dropout(0.15)(x)

    x   = layers.Conv2D(128, (3,3), padding='same')(x)
    x   = layers.BatchNormalization()(x)
    x   = layers.Activation('relu')(x)
    x   = layers.GlobalAveragePooling2D()(x)

    x   = layers.Dense(128, activation='relu')(x)
    x   = layers.Dropout(0.3)(x)
    out = layers.Dense(3, activation='softmax')(x)

    model = keras.Model(inp, out)
    model.compile(
        optimizer=keras.optimizers.Adam(0.001),
        loss='sparse_categorical_crossentropy',
        metrics=['accuracy'])

    model.summary()

    cbs = [
        keras.callbacks.EarlyStopping(
            patience=12, restore_best_weights=True,
            monitor='val_accuracy', min_delta=0.005),
        keras.callbacks.ReduceLROnPlateau(
            factor=0.5, patience=5, min_lr=1e-5, verbose=1),
    ]

    history = model.fit(
        X_tr, y_tr,
        validation_data=(X_v, y_v),
        epochs=EPOCHS, batch_size=BATCH_SIZE,
        callbacks=cbs, verbose=1)

    loss, acc = model.evaluate(X_v, y_v, verbose=0)
    print(f"\n  ✓ Val accuracy: {acc*100:.1f}%  loss: {loss:.4f}")

    if acc < 0.70:
        print("  ⚠ Accuracy below 70% — check validate_signals() output")
    elif acc < 0.85:
        print("  ✓ Acceptable — increase N_PER_CLASS for better results")
    else:
        print("  ✓ Good accuracy — ready for deployment")

    # Save
    model.save('rescue_acoustic_model.h5')
    print(f"  ✓ Saved: rescue_acoustic_model.h5")

    # TFLite
    try:
        converter = tf.lite.TFLiteConverter.from_keras_model(model)
        converter.optimizations = [tf.lite.Optimize.DEFAULT]
        tflite = converter.convert()
        with open('rescue_acoustic_model.tflite', 'wb') as f:
            f.write(tflite)
        print(f"  ✓ Saved: rescue_acoustic_model.tflite ({len(tflite)//1024}KB)")
    except Exception as e:
        print(f"  TFLite: {e}")

    with open('acoustic_classes.json', 'w') as f:
        json.dump({str(k): v for k, v in CLASSES.items()}, f, indent=2)
    print(f"  ✓ Saved: acoustic_classes.json")

    return model


# ══════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════

if __name__ == "__main__":
    validate_signals()

    print("Generating dataset...")
    t0   = time.time()
    X, y = generate_dataset()
    print(f"Done in {time.time()-t0:.1f}s\n")

    print("Training...")
    model = train(X, y)

    print("\n" + "="*60)
    print("DONE — copy these to rescue_dashboard/backend/:")
    print("  rescue_acoustic_model.tflite")
    print("  acoustic_classes.json")