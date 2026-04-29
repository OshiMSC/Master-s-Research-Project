import librosa
import librosa.display
import matplotlib.pyplot as plt
import numpy as np

def make_mel(file, fmax=4000):
    data, sr = librosa.load(file, sr=44100)
    mel = librosa.feature.melspectrogram(
        y=data, sr=sr, n_mels=128, fmax=fmax
    )
    return librosa.power_to_db(mel, ref=np.max), sr

fig, axes = plt.subplots(1, 3, figsize=(18, 5))

# Panel 1 — pure storm noise only
mel1, sr = make_mel('Wind/storm_noise.wav')
librosa.display.specshow(mel1, sr=sr, ax=axes[0],
    x_axis='time', y_axis='mel', fmax=4000, cmap='magma')
axes[0].set_title('Storm noise only (label = 0)')
axes[0].set_ylabel('Frequency (Hz)')

# Panel 2 — chirp mixed with storm
mel2, sr = make_mel('cyclone_beacon_simulation.wav')
img = librosa.display.specshow(mel2, sr=sr, ax=axes[1],
    x_axis='time', y_axis='mel', fmax=4000, cmap='magma')
axes[1].set_title('Chirp + storm noise (label = 1)')
axes[1].set_ylabel('')

# Panel 3 — pure chirp alone
mel3, sr = make_mel('rescue_chirp_master.wav')
librosa.display.specshow(mel3, sr=sr, ax=axes[2],
    x_axis='time', y_axis='mel', fmax=4000, cmap='magma')
axes[2].set_title('Chirp signal alone (reference)')
axes[2].set_ylabel('')


fig.colorbar(img, ax=axes, format='%+2.0f dB')
fig.suptitle('CycloneSOS — Signal vs Noise Analysis', fontsize=14)
plt.tight_layout()
plt.savefig('spectrogram_comparison.png', dpi=150, bbox_inches='tight')
plt.show()