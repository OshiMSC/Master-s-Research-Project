import librosa
import numpy as np
import soundfile as sf  # <--- This is the line that was missing!

# 1. Load the noise and the chirp
try:
    # Make sure these filenames match exactly what you have in your folder
    noise, sr = librosa.load('Wind/storm_noise.wav', sr=44100)
    chirp_signal, _ = librosa.load('rescue_chirp_master.wav', sr=44100)
    
    print("📂 Files loaded successfully.")

    # 2. Place the chirp inside the noise
    # We will put it 1 second into the recording
    start_sample = int(1.0 * sr) 
    end_sample = start_sample + len(chirp_signal)

    # 3. Mixing
    combined = noise.copy()
    # We make the chirp very quiet (0.05) to simulate a distant victim
    combined[start_sample:end_sample] += (chirp_signal * 0.05)

    # 4. Save the simulation
    sf.write('cyclone_simulation.wav', combined, sr)
    print("🌪️ SUCCESS! 'cyclone_simulation.wav' created.")
    print("You can now run the Spectrogram code (Step 4) to see the signal.")

except Exception as e:
    print(f"❌ An error occurred: {e}")