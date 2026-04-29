import librosa
import numpy as np
import matplotlib.pyplot as plt
from scipy.signal import correlate, find_peaks

# 1. Load the 'Master Chirp' (Template) and the 'Simulation' (Target)
template, sr = librosa.load('rescue_chirp_master.wav', sr=44100)
noisy_audio, _ = librosa.load('cyclone_beacon_simulation.wav', sr=44100)

# 2. Cross-Correlation
# This is the 'Brain' of the project. It scans the noisy audio for the template.
print("Scanning audio for rescue signals...")
correlation = correlate(noisy_audio, template, mode='valid')

# 3. Normalize the result so it is between 0 and 1
correlation = np.abs(correlation)
correlation /= np.max(correlation)

# 4. Peak Detection
# We look for where the correlation is high (e.g., above 0.5)
# 'distance' ensures we don't count the same chirp twice
peaks, properties = find_peaks(correlation, height=0.4, distance=sr*1)

# 5. Output the Results
print("-" * 30)
print(f"FOUND {len(peaks)} POTENTIAL VICTIMS!")
for i, peak in enumerate(peaks):
    timestamp = peak / sr
    print(f" Detection {i+1}: {timestamp:.2f} seconds")
print("-" * 30)

# 6. Visualize the Spikes (The Proof)
plt.figure(figsize=(12, 4))
plt.plot(np.linspace(0, len(noisy_audio)/sr, len(correlation)), correlation)
plt.axhline(y=0.4, color='r', linestyle='--', label='Detection Threshold')
plt.title('Automatic Detection Spikes (Cross-Correlation Result)')
plt.xlabel('Time (seconds)')
plt.ylabel('Match Strength')
plt.legend()
plt.show()