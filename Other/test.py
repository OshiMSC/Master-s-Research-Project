import librosa
import numpy as np
import soundfile as sf

# -----------------------------
# 1. Load chirp
# -----------------------------
chirp_signal, sr = librosa.load('rescue_chirp_master.wav', sr=44100)

# Optional: make chirp slightly longer (recommended)
# chirp_signal = np.tile(chirp_signal, 2)

# -----------------------------
# 2. Load or generate noise
# -----------------------------
duration = 10.0

try:
    noise, _ = librosa.load('Wind/storm_noise.wav', sr=sr, duration=duration)
except:
    noise = np.random.uniform(-0.1, 0.1, int(sr * duration))

# Ensure correct length
if len(noise) < sr * duration:
    noise = np.pad(noise, (0, int(sr * duration) - len(noise)))
else:
    noise = noise[:int(sr * duration)]

combined = noise.copy()

# -----------------------------
# 3. SNR Mixing Function
# -----------------------------
def scale_signal_to_snr(signal, noise_segment, target_snr_db):
    """
    Scale signal to achieve target SNR (dB)
    SNR = 10 * log10(P_signal / P_noise)
    """

    # Compute power
    signal_power = np.mean(signal**2)
    noise_power = np.mean(noise_segment**2)

    if noise_power == 0:
        return signal

    # Convert SNR from dB to linear
    snr_linear = 10 ** (target_snr_db / 10)

    # Compute required scaling factor
    scale = np.sqrt((snr_linear * noise_power) / signal_power)

    return signal * scale

# -----------------------------
# 4. Insert Chirps with Target SNR
# -----------------------------
intervals = [1, 3, 5, 7, 9]

target_snr_db = -10   # 🔥 CHANGE THIS: 0, -5, -10, -15, -20

for start_time in intervals:
    start_sample = int(start_time * sr)
    end_sample = start_sample + len(chirp_signal)

    if end_sample < len(combined):
        noise_segment = combined[start_sample:end_sample]

        # Scale chirp to match SNR
        scaled_chirp = scale_signal_to_snr(
            chirp_signal,
            noise_segment,
            target_snr_db
        )

        combined[start_sample:end_sample] += scaled_chirp

# -----------------------------
# 5. Normalize (IMPORTANT)
# -----------------------------
combined = combined / np.max(np.abs(combined))

# -----------------------------
# 6. Save Output
# -----------------------------
output_name = f'cyclone_beacon_{target_snr_db}dB.wav'
sf.write(output_name, combined, sr)

print(f"✅ Created '{output_name}' with proper SNR control!")