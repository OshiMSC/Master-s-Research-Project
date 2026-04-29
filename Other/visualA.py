import librosa
import librosa.display
import matplotlib.pyplot as plt
import numpy as np

file_to_load = 'cyclone_beacon_simulation.wav'
data, sr = librosa.load(file_to_load, sr=44100)

plt.figure(figsize=(14, 6))

# Use Mel-Spectrogram — same as your CNN input
mel = librosa.feature.melspectrogram(
    y=data, sr=sr,
    n_mels=128,
    fmax=4000       # zoom to 0–4000 Hz
)
mel_db = librosa.power_to_db(mel, ref=np.max)

img = librosa.display.specshow(
    mel_db, sr=sr,
    x_axis='time',
    y_axis='mel',
    fmax=4000,
    cmap='magma'
)

plt.title('CycloneSOS — Mel-Spectrogram: Chirp vs Cyclone Noise')
plt.colorbar(img, format='%+2.0f dB')
plt.xlabel('Time (seconds)')
plt.ylabel('Frequency (Mel scale)')
plt.tight_layout()
plt.show()