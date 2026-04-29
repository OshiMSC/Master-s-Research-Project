import librosa
import numpy as np
import soundfile as sf

# 1. Load your master chirp (the 0.5s sweep)
chirp_signal, sr = librosa.load('rescue_chirp_master.wav', sr=44100)

# 2. Create 10 seconds of background noise
# If you have storm_noise.wav, we load it; otherwise we make 'white noise'
try:
    noise, _ = librosa.load('Wind/storm_noise.wav', sr=sr, duration=10.0)
except:
    noise = np.random.uniform(-0.1, 0.1, sr * 10) 

# 3. Create the Repeating Pattern (The 'Beacon')
combined = noise.copy()

# We will repeat the chirp at 1s, 3s, 5s, 7s, and 9s
intervals = [1, 3, 5, 7, 9]

for start_time in intervals:
    start_sample = int(start_time * sr)
    end_sample = start_sample + len(chirp_signal)
    
    # Check bounds
    if end_sample < len(combined):
        # We add the chirp at 5% volume (-26dB approx) to simulate distance
        combined[start_sample:end_sample] += (chirp_signal * 0.05)

# 4. Save the "Beacon" Simulation
sf.write('cyclone_beacon_simulation.wav', combined, sr)
print("✅ Created 'cyclone_beacon_simulation.wav' with a repeating rescue signal!")