"""
CycloneSOS — Script 03: Data Augmentation
==========================================
Mixes distress sounds with storm noise at 5 SNR levels.
This simulates real disaster conditions where the victim's
distress sounds are partially buried in storm noise.

SNR Levels:
  0 dB   → signal and noise equal power    (easy)
  -5 dB  → noise slightly stronger         (medium)
  -10 dB → noise 3x stronger              (hard)
  -15 dB → noise 5x stronger              (very hard)
  -20 dB → noise 10x stronger             (extreme)

HOW TO RUN:
  python 03_augment_data.py

OUTPUT:
  datasets/augmented/
    distress_snr0/     ← distress mixed at 0 dB SNR
    distress_snr-5/    ← distress mixed at -5 dB SNR
    distress_snr-10/   ← distress mixed at -10 dB SNR
    distress_snr-15/   ← distress mixed at -15 dB SNR
    distress_snr-20/   ← distress mixed at -20 dB SNR
    background_noisy/  ← background with storm variation
"""

import os
import numpy as np
import librosa
import soundfile as sf
from tqdm import tqdm
import random

# ── Config ────────────────────────────────────────────────
TARGET_SR      = 22050
CLIP_DURATION  = 3.0
SNR_LEVELS     = [0, -5, -10, -15, -20]   # dB
BASE           = os.path.dirname(os.path.abspath(__file__))
DATASETS       = os.path.join(BASE, "datasets")
DISTRESS_DIR   = os.path.join(DATASETS, "processed", "distress")
BACKGROUND_DIR = os.path.join(DATASETS, "processed", "background")
AUGMENTED_DIR  = os.path.join(DATASETS, "augmented")

# Create output folders
for snr in SNR_LEVELS:
    os.makedirs(os.path.join(AUGMENTED_DIR, f"distress_snr{snr}"), exist_ok=True)
os.makedirs(os.path.join(AUGMENTED_DIR, "background_noisy"), exist_ok=True)

random.seed(42)
np.random.seed(42)


def load_audio(filepath):
    """Load a standardised audio file as numpy array."""
    try:
        audio, _ = librosa.load(filepath, sr=TARGET_SR, mono=True)
        target_len = int(TARGET_SR * CLIP_DURATION)
        if len(audio) >= target_len:
            audio = audio[:target_len]
        else:
            audio = np.pad(audio, (0, target_len - len(audio)))
        return audio.astype(np.float32)
    except Exception as e:
        return None


def mix_at_snr(signal, noise, snr_db):
    """
    Mix signal and noise at a specific SNR level.

    SNR (dB) = 10 * log10(signal_power / noise_power)

    To achieve target SNR, we scale the noise:
      noise_scaled = noise * sqrt(signal_power / (noise_power * 10^(SNR/10)))

    Args:
        signal  : distress audio array (float32)
        noise   : storm noise array (float32)
        snr_db  : target Signal-to-Noise Ratio in dB

    Returns:
        mixed audio array (float32)
    """
    # Calculate power of signal and noise
    signal_power = np.mean(signal ** 2)
    noise_power  = np.mean(noise ** 2)

    if noise_power == 0 or signal_power == 0:
        return signal

    # Calculate scale factor for noise to achieve target SNR
    # SNR = signal_power / scaled_noise_power
    # scaled_noise_power = signal_power / 10^(SNR/10)
    target_noise_power = signal_power / (10 ** (snr_db / 10))
    noise_scale        = np.sqrt(target_noise_power / noise_power)
    scaled_noise       = noise * noise_scale

    # Mix
    mixed = signal + scaled_noise

    # Normalise to prevent clipping
    max_val = np.max(np.abs(mixed))
    if max_val > 0:
        mixed = mixed / max_val * 0.9

    return mixed.astype(np.float32)


def augment_distress_files():
    """Mix every distress clip with storm noise at all 5 SNR levels."""
    print("\n── Augmenting Distress Sounds ──────────────────")

    distress_files = [f for f in os.listdir(DISTRESS_DIR)
                      if f.endswith('.wav')]
    background_files = [f for f in os.listdir(BACKGROUND_DIR)
                        if f.endswith('.wav')]

    if not distress_files:
        print("  ❌ No distress files found")
        print(f"     Run 02_extract_classes.py first")
        return 0

    if not background_files:
        print("  ❌ No background/noise files found")
        print(f"     Run 02_extract_classes.py first")
        return 0

    print(f"  Distress files   : {len(distress_files)}")
    print(f"  Background files : {len(background_files)}")
    print(f"  SNR levels       : {SNR_LEVELS}")
    print(f"  Total output     : {len(distress_files) * len(SNR_LEVELS)} augmented clips")

    total_created = 0

    for snr in SNR_LEVELS:
        output_dir = os.path.join(AUGMENTED_DIR, f"distress_snr{snr}")
        count      = 0

        for dist_file in tqdm(distress_files,
                              desc=f"  SNR {snr:+3d} dB"):
            dist_path = os.path.join(DISTRESS_DIR, dist_file)
            signal    = load_audio(dist_path)
            if signal is None:
                continue

            # Pick a random noise file
            noise_file = random.choice(background_files)
            noise_path = os.path.join(BACKGROUND_DIR, noise_file)
            noise      = load_audio(noise_path)
            if noise is None:
                continue

            # Also add a random time offset to the noise
            # for variety (simulate different storm moments)
            offset = random.randint(0, max(0, len(noise) - int(TARGET_SR * CLIP_DURATION)))
            noise  = noise[offset:offset + int(TARGET_SR * CLIP_DURATION)]
            if len(noise) < int(TARGET_SR * CLIP_DURATION):
                noise = np.pad(noise, (0, int(TARGET_SR * CLIP_DURATION) - len(noise)))

            # Mix at target SNR
            mixed = mix_at_snr(signal, noise, snr)

            # Save
            base_name   = os.path.splitext(dist_file)[0]
            output_name = f"{base_name}_snr{snr}_{count:04d}.wav"
            output_path = os.path.join(output_dir, output_name)
            sf.write(output_path, mixed, TARGET_SR, subtype='PCM_16')

            count         += 1
            total_created += 1

        print(f"    ✓ SNR {snr:+3d} dB : {count} clips created")

    return total_created


def augment_background_files():
    """
    Add slight amplitude variation to background files
    to increase diversity — simulates different storm intensities.
    """
    print("\n── Augmenting Background Sounds ────────────────")

    background_files = [f for f in os.listdir(BACKGROUND_DIR)
                        if f.endswith('.wav')]

    if not background_files:
        print("  ❌ No background files found")
        return 0

    output_dir = os.path.join(AUGMENTED_DIR, "background_noisy")
    count      = 0

    # Copy originals + create 3 variations per file
    for bg_file in tqdm(background_files,
                        desc="  Background augment"):
        bg_path = os.path.join(BACKGROUND_DIR, bg_file)
        audio   = load_audio(bg_path)
        if audio is None:
            continue

        # Original copy
        sf.write(os.path.join(output_dir, f"bg_orig_{count:04d}.wav"),
                 audio, TARGET_SR, subtype='PCM_16')
        count += 1

        # 3 amplitude variations
        for v, scale in enumerate([0.6, 0.8, 1.0]):
            varied = audio * scale
            sf.write(os.path.join(output_dir,
                                   f"bg_var{v}_{count:04d}.wav"),
                     varied.astype(np.float32), TARGET_SR, subtype='PCM_16')
            count += 1

    print(f"  ✓ Background augmented: {count} clips")
    return count


def verify_augmentation():
    """Verify SNR is correct in a sample of augmented files."""
    print("\n── Verifying SNR Accuracy ──────────────────────")

    distress_files = [f for f in os.listdir(DISTRESS_DIR)
                      if f.endswith('.wav')]
    background_files = [f for f in os.listdir(BACKGROUND_DIR)
                        if f.endswith('.wav')]

    if not distress_files or not background_files:
        print("  ⚠ Cannot verify — no source files found")
        return

    signal = load_audio(os.path.join(DISTRESS_DIR, distress_files[0]))
    noise  = load_audio(os.path.join(BACKGROUND_DIR, background_files[0]))

    if signal is None or noise is None:
        return

    print(f"  Verifying SNR accuracy on sample files:")
    print(f"  {'Target SNR':<15} {'Actual SNR':<15} {'Difference'}")
    print("  " + "-"*45)

    for snr_target in SNR_LEVELS:
        mixed         = mix_at_snr(signal, noise, snr_target)

        # Measure actual SNR in the mixed signal
        noise_scaled  = mixed - signal
        sig_power     = np.mean(signal ** 2)
        noise_power   = np.mean(noise_scaled ** 2)

        if noise_power > 0 and sig_power > 0:
            actual_snr = 10 * np.log10(sig_power / noise_power)
            diff       = abs(actual_snr - snr_target)
            status     = "✓" if diff < 1.0 else "⚠"
            print(f"  {snr_target:+5d} dB         {actual_snr:+7.2f} dB       {diff:.2f} dB  {status}")


# ── Main ──────────────────────────────────────────────────
if __name__ == "__main__":
    print("\n" + "★"*55)
    print("  CycloneSOS — Data Augmentation")
    print("  Mixing distress sounds with storm noise")
    print("★"*55)

    dist_count = augment_distress_files()
    bg_count   = augment_background_files()
    verify_augmentation()

    print("\n" + "="*55)
    print("  AUGMENTATION COMPLETE")
    print("="*55)
    print(f"  Augmented distress clips  : {dist_count}")
    print(f"  Augmented background clips: {bg_count}")
    print(f"  Total augmented clips     : {dist_count + bg_count}")

    for snr in SNR_LEVELS:
        d = os.path.join(AUGMENTED_DIR, f"distress_snr{snr}")
        n = len([f for f in os.listdir(d) if f.endswith('.wav')]) if os.path.exists(d) else 0
        print(f"    distress_snr{snr:<4}: {n} files")

    bg_dir = os.path.join(AUGMENTED_DIR, "background_noisy")
    bg_n   = len([f for f in os.listdir(bg_dir) if f.endswith('.wav')]) if os.path.exists(bg_dir) else 0
    print(f"    background_noisy : {bg_n} files")

    print("\n  Next step: python 04_build_manifest.py")
