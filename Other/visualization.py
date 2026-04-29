import librosa
import librosa.display
import matplotlib.pyplot as plt
import numpy as np

# 1. Load the mixed 'noisy' file (using the Beacon one we just made)
file_to_load = 'cyclone_beacon_simulation.wav' # Or 'cyclone_simulation.wav'
data, sr = librosa.load(file_to_load, sr=44100)

plt.figure(figsize=(12, 6))

# 2. Create the Spectrogram
# n_fft determines the vertical resolution; 2048 is good for detail
D = librosa.amplitude_to_db(np.abs(librosa.stft(data, n_fft=2048)), ref=np.max)

# 3. Display it
img = librosa.display.specshow(D, sr=sr, x_axis='time', y_axis='hz', cmap='magma')

plt.title('Acoustic Beacon Detection: Victim Signal vs Cyclone Noise')

# 4. ZOOM IN: This is important! 
# We zoom to 0Hz - 4000Hz to see our 1kHz-2.5kHz chirp clearly
plt.ylim(0, 4000) 

plt.colorbar(img, format='%+2.0f dB')
plt.xlabel('Time (seconds)')
plt.ylabel('Frequency (Hz)')
plt.tight_layout()
plt.show()