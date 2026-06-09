"""
ResQNet — Script 03 v2: Improved Data Augmentation
====================================================
WHAT IS NEW vs v1:
  v1 only mixed distress with storm noise at 5 SNR levels.

  v2 adds 4 new augmentation types that simulate
  REAL-WORLD phone deployment conditions:

  NEW 1: Room Impulse Response (RIR)
    Simulates audio played in a room — echo + reverb
    Critical for laptop-speaker-to-phone-mic path

  NEW 2: Speaker-to-Microphone simulation
    Simulates audio played through laptop speaker
    and captured by phone microphone:
      - High-pass filter (removes deep bass from laptop)
      - Low-pass filter (phone mic bandwidth = 8kHz)
      - Slight harmonic distortion (speaker cone)

  NEW 3: Pocket/Bag muffling simulation
    Simulates phone in jeans pocket or bag:
      - Aggressive low-pass filter (cloth absorbs highs)
      - 60-80% amplitude attenuation
      - Added cloth rubbing noise

  NEW 4: Extended SNR range
    v1:  0, -5, -10, -15, -20 dB
    v2:  0, -5, -10, -15, -20, -25 dB (added -25)

TOTAL AUGMENTATION FACTOR:
  v1: 1 distress clip × 5 SNR = 5 augmented clips
  v2: 1 distress clip × 5 SNR × 4 real-world conditions
      = 20 augmented clips per original clip

HOW TO RUN:
  python 03_augment_data_v2.py

OUTPUT:
  datasets/augmented_v2/
    distress_snr0/
    distress_snr-5/
    distress_snr-10/
    distress_snr-15/
    distress_snr-20/
    distress_snr-25/           ← NEW
    distress_speaker_mic/      ← NEW
    distress_pocket/           ← NEW
    distress_rir/              ← NEW
    background_noisy/

THEN:
  Update 04_build_manifest.py to include augmented_v2/
  Run 05_generate_spectrograms.py
  Retrain on Colab (~25 minutes)
"""

import os
import numpy as np
import librosa
import soundfile as sf
import scipy.signal
from tqdm import tqdm
import random

# ── Config ─────────────────────────────────────────────────
TARGET_SR     = 22050
CLIP_DURATION = 3.0
BASE          = os.path.dirname(os.path.abspath(__file__))
DATASETS      = os.path.join(BASE, "datasets")
DISTRESS_DIR  = os.path.join(DATASETS, "processed", "distress")
BG_DIR        = os.path.join(DATASETS, "processed", "background")
AUG_DIR       = os.path.join(DATASETS, "augmented_v2")

# ── v2 SNR levels (added -25 dB) ───────────────────────────
SNR_LEVELS = [0, -5, -10, -15, -20, -25]

# Create output folders
for snr in SNR_LEVELS:
    os.makedirs(os.path.join(AUG_DIR, f"distress_snr{snr}"), exist_ok=True)
os.makedirs(os.path.join(AUG_DIR, "distress_speaker_mic"), exist_ok=True)
os.makedirs(os.path.join(AUG_DIR, "distress_pocket"),      exist_ok=True)
os.makedirs(os.path.join(AUG_DIR, "distress_rir"),         exist_ok=True)
os.makedirs(os.path.join(AUG_DIR, "background_noisy"),     exist_ok=True)

random.seed(42)
np.random.seed(42)

counts = {
    'snr': 0, 'speaker_mic': 0,
    'pocket': 0, 'rir': 0,
    'background': 0, 'skipped': 0
}


# ── Audio utilities ─────────────────────────────────────────
def load_audio(filepath):
    try:
        audio, _ = librosa.load(filepath, sr=TARGET_SR, mono=True)
        target_len = int(TARGET_SR * CLIP_DURATION)
        if len(audio) >= target_len:
            audio = audio[:target_len]
        else:
            audio = np.pad(audio, (0, target_len - len(audio)))
        return audio.astype(np.float32)
    except:
        return None


def save_clip(audio, output_dir, prefix, counter):
    filename = f"{prefix}_{counter:05d}.wav"
    filepath = os.path.join(output_dir, filename)
    sf.write(filepath, audio, TARGET_SR, subtype='PCM_16')
    return filename


def normalise(audio, target=0.9):
    max_val = np.max(np.abs(audio))
    if max_val > 0:
        return (audio / max_val * target).astype(np.float32)
    return audio


def mix_at_snr(signal, noise, snr_db):
    """Mix signal + noise at target SNR level."""
    sig_pwr   = np.mean(signal ** 2)
    noise_pwr = np.mean(noise  ** 2)
    if noise_pwr == 0 or sig_pwr == 0:
        return signal
    target_noise_pwr = sig_pwr / (10 ** (snr_db / 10))
    noise_scale = np.sqrt(target_noise_pwr / noise_pwr)
    mixed = signal + noise * noise_scale
    return normalise(mixed)


# ── NEW Augmentation 1: Room Impulse Response (RIR) ────────
def apply_rir(audio, room_size='medium'):
    """
    Simulate audio in a room — adds echo and reverb.

    Models:
      small  → bathroom / small room (0.1s reverb)
      medium → living room / office  (0.3s reverb)
      large  → hall / warehouse      (0.6s reverb)

    This is critical because:
      - When laptop plays audio in a room, echoes are added
      - The phone mic captures the reverberant sound
      - Training without RIR means CNN fails on real recordings
    """
    sizes = {
        'small':  (0.1, 4.0),   # (reverb_time_s, decay_rate)
        'medium': (0.3, 3.0),
        'large':  (0.6, 2.0),
    }
    reverb_time, decay_rate = sizes.get(room_size, sizes['medium'])

    # Generate Room Impulse Response
    rir_length = int(TARGET_SR * reverb_time)
    t = np.linspace(0, reverb_time, rir_length)

    # Exponentially decaying noise = RIR approximation
    rir = np.random.randn(rir_length)
    rir *= np.exp(-decay_rate * t / reverb_time)

    # Add a few early reflections (room boundaries)
    n_reflections = random.randint(2, 5)
    for _ in range(n_reflections):
        delay    = random.randint(int(TARGET_SR * 0.005),
                                  int(TARGET_SR * 0.05))
        strength = random.uniform(0.1, 0.4)
        if delay < rir_length:
            rir[delay] += strength

    # Normalise RIR
    rir /= np.max(np.abs(rir) + 1e-8)

    # Convolve audio with RIR
    reverb = scipy.signal.fftconvolve(audio, rir)[:len(audio)]

    # Mix dry + wet (80% dry keeps intelligibility)
    dry_wet = random.uniform(0.2, 0.5)   # wet ratio
    result  = (1 - dry_wet) * audio + dry_wet * reverb

    return normalise(result)


# ── NEW Augmentation 2: Speaker-to-Microphone simulation ───
def simulate_speaker_mic_path(audio):
    """
    Simulate the acoustic path:
      laptop speaker → air → phone microphone

    This models:
      1. Laptop speaker frequency response
         (weak bass below 150Hz, emphasis around 1-4kHz)
      2. Air transmission loss
         (high frequencies attenuate faster with distance)
      3. Phone microphone response
         (bandwidth typically 100Hz - 8kHz)
      4. Slight speaker cone non-linearity (soft clipping)
      5. Distance-dependent amplitude reduction

    WHY THIS MATTERS:
      When you test CNN by playing audio from laptop speaker,
      the phone hears a modified version of the original.
      Training without this simulation = model fails at demo.
    """
    result = audio.copy()

    # Step 1: Remove deep bass (laptop speaker can't reproduce <150Hz)
    b, a   = scipy.signal.butter(2, 150 / (TARGET_SR / 2), btype='high')
    result = scipy.signal.filtfilt(b, a, result)

    # Step 2: Speaker resonance bump around 1-3kHz
    # (laptop speakers have resonance peak here)
    b, a   = scipy.signal.butter(2,
                [800 / (TARGET_SR / 2), 3000 / (TARGET_SR / 2)],
                btype='band')
    resonance = scipy.signal.filtfilt(b, a, result)
    result    = result + 0.15 * resonance   # add +2dB bump

    # Step 3: Air transmission — attenuate above 4kHz
    # (simulates 30-50cm distance through air)
    distance = random.uniform(0.1, 0.6)   # 10-60cm
    cutoff   = 8000 * (1 - distance * 0.3)   # reduce with distance
    cutoff   = max(3000, cutoff)
    b, a     = scipy.signal.butter(3, cutoff / (TARGET_SR / 2), btype='low')
    result   = scipy.signal.filtfilt(b, a, result)

    # Step 4: Phone mic bandwidth limit (100Hz - 8kHz)
    b, a   = scipy.signal.butter(2, 100 / (TARGET_SR / 2), btype='high')
    result = scipy.signal.filtfilt(b, a, result)

    # Step 5: Soft clipping (speaker distortion at high volume)
    clip_level = random.uniform(0.6, 0.9)
    result     = np.tanh(result / clip_level) * clip_level

    # Step 6: Amplitude reduction (distance attenuation)
    amp_scale = random.uniform(0.3, 0.7)
    result    = result * amp_scale

    # Step 7: Add small amount of white noise (microphone noise floor)
    noise_level = random.uniform(0.001, 0.005)
    result      = result + np.random.randn(len(result)) * noise_level

    return normalise(result)


# ── NEW Augmentation 3: Pocket/Bag muffling ─────────────────
def simulate_pocket_muffling(audio, location='pocket'):
    """
    Simulate phone placed in clothing pocket or bag.

    Scenarios:
      pocket → jeans/shirt pocket  (-15 to -20dB, heavy HF loss)
      bag    → backpack/handbag    (-20 to -30dB, extreme muffling)
      loose  → jacket pocket       (-8 to -12dB, moderate muffling)

    Physics:
      Clothing absorbs high frequencies strongly.
      Low frequencies pass through fabric more easily.
      Result: muffled, bass-heavy, quiet sound.

    This is the most important augmentation for real-world use:
      In a real disaster the victim's phone is likely in a pocket.
    """
    result = audio.copy()

    if location == 'pocket':
        # Jeans/shirt pocket: 500Hz cutoff, -20dB overall
        cutoff     = random.uniform(400, 800)   # Hz
        attenuation = random.uniform(0.10, 0.25)  # 75-90% attenuation
        cloth_noise = random.uniform(0.003, 0.008)

    elif location == 'bag':
        # Backpack: 300Hz cutoff, -30dB overall
        cutoff      = random.uniform(200, 400)
        attenuation = random.uniform(0.03, 0.10)
        cloth_noise = random.uniform(0.005, 0.012)

    else:  # loose
        # Jacket pocket: 1000Hz cutoff, -10dB
        cutoff      = random.uniform(800, 1500)
        attenuation = random.uniform(0.25, 0.45)
        cloth_noise = random.uniform(0.001, 0.004)

    # Heavy low-pass filter (cloth muffling)
    b, a   = scipy.signal.butter(4,
                cutoff / (TARGET_SR / 2), btype='low')
    result = scipy.signal.filtfilt(b, a, result)

    # Amplitude attenuation
    result = result * attenuation

    # Add cloth rubbing noise (fabric movement)
    rubbing       = np.random.randn(len(result)) * cloth_noise
    b_rub, a_rub  = scipy.signal.butter(2,
                        [50/(TARGET_SR/2), 200/(TARGET_SR/2)],
                        btype='band')
    rubbing = scipy.signal.filtfilt(b_rub, a_rub, rubbing)
    result  = result + rubbing

    return normalise(result)


# ── Original augmentation: SNR mixing ───────────────────────
def augment_with_snr(distress_files, bg_files):
    print("\n── SNR Augmentation (v2 — includes -25 dB) ────────")
    print(f"  SNR levels: {SNR_LEVELS}")
    print(f"  Clips:      {len(distress_files)} distress × {len(SNR_LEVELS)} SNR")

    for snr in SNR_LEVELS:
        out_dir = os.path.join(AUG_DIR, f"distress_snr{snr}")
        for dist_file in tqdm(distress_files,
                              desc=f"  SNR {snr:+d} dB"):
            signal = load_audio(os.path.join(DISTRESS_DIR, dist_file))
            if signal is None:
                counts['skipped'] += 1
                continue

            noise_file = random.choice(bg_files)
            noise      = load_audio(os.path.join(BG_DIR, noise_file))
            if noise is None:
                counts['skipped'] += 1
                continue

            mixed = mix_at_snr(signal, noise, snr)
            save_clip(mixed, out_dir,
                      f"dist_snr{snr}",
                      counts['snr'])
            counts['snr'] += 1


# ── NEW: RIR augmentation ────────────────────────────────────
def augment_with_rir(distress_files, bg_files):
    print("\n── NEW: Room Impulse Response Augmentation ─────────")
    print("  Simulates: audio played in room + re-recorded by phone")
    out_dir = os.path.join(AUG_DIR, "distress_rir")

    for dist_file in tqdm(distress_files, desc="  RIR augment"):
        signal = load_audio(os.path.join(DISTRESS_DIR, dist_file))
        if signal is None:
            counts['skipped'] += 1
            continue

        # Apply 3 different room sizes for variety
        for room_size in ['small', 'medium', 'large']:
            reverb = apply_rir(signal, room_size)

            # Also mix with background noise at -5 dB for realism
            if bg_files:
                noise  = load_audio(os.path.join(BG_DIR,
                                    random.choice(bg_files)))
                if noise is not None:
                    snr    = random.choice([-5, -10, -15])
                    reverb = mix_at_snr(reverb, noise, snr)

            save_clip(reverb, out_dir,
                      f"dist_rir_{room_size}",
                      counts['rir'])
            counts['rir'] += 1

    print(f"  Created {counts['rir']} RIR augmented clips")


# ── NEW: Speaker-mic augmentation ───────────────────────────
def augment_with_speaker_mic(distress_files, bg_files):
    print("\n── NEW: Speaker-to-Mic Path Simulation ─────────────")
    print("  Simulates: laptop speaker → air → phone microphone")
    out_dir = os.path.join(AUG_DIR, "distress_speaker_mic")

    for dist_file in tqdm(distress_files, desc="  Speaker-mic"):
        signal = load_audio(os.path.join(DISTRESS_DIR, dist_file))
        if signal is None:
            counts['skipped'] += 1
            continue

        # Apply speaker-mic simulation
        sim = simulate_speaker_mic_path(signal)

        # Optionally add RIR on top (more realistic)
        if random.random() > 0.5:
            sim = apply_rir(sim, random.choice(['small', 'medium']))

        # Mix with background noise
        if bg_files:
            noise = load_audio(os.path.join(BG_DIR, random.choice(bg_files)))
            if noise is not None:
                snr = random.choice([-5, -10, -15])
                sim = mix_at_snr(sim, noise, snr)

        save_clip(sim, out_dir,
                  "dist_speaker_mic",
                  counts['speaker_mic'])
        counts['speaker_mic'] += 1

    print(f"  Created {counts['speaker_mic']} speaker-mic clips")


# ── NEW: Pocket muffling augmentation ───────────────────────
def augment_with_pocket(distress_files, bg_files):
    print("\n── NEW: Pocket/Bag Muffling Simulation ─────────────")
    print("  Simulates: phone in jeans pocket / backpack / jacket")
    out_dir = os.path.join(AUG_DIR, "distress_pocket")

    locations = ['pocket', 'pocket', 'bag', 'loose']
    # pocket appears twice — more likely scenario

    for dist_file in tqdm(distress_files, desc="  Pocket muffling"):
        signal = load_audio(os.path.join(DISTRESS_DIR, dist_file))
        if signal is None:
            counts['skipped'] += 1
            continue

        # Apply each pocket type
        for location in locations:
            muffled = simulate_pocket_muffling(signal, location)

            # Add background noise (pocket doesn't block low-freq noise)
            if bg_files:
                noise = load_audio(os.path.join(BG_DIR,
                                   random.choice(bg_files)))
                if noise is not None:
                    snr     = random.choice([-10, -15, -20])
                    muffled = mix_at_snr(muffled, noise, snr)

            save_clip(muffled, out_dir,
                      f"dist_pocket_{location}",
                      counts['pocket'])
            counts['pocket'] += 1

    print(f"  Created {counts['pocket']} pocket muffled clips")


# ── Background augmentation ──────────────────────────────────
def augment_background(bg_files):
    print("\n── Background Augmentation ─────────────────────────")
    out_dir = os.path.join(AUG_DIR, "background_noisy")

    for bg_file in tqdm(bg_files, desc="  Background"):
        audio = load_audio(os.path.join(BG_DIR, bg_file))
        if audio is None:
            counts['skipped'] += 1
            continue

        # Original
        save_clip(audio, out_dir, "bg_orig", counts['background'])
        counts['background'] += 1

        # 3 amplitude variations
        for scale in [0.5, 0.7, 0.9]:
            varied = normalise(audio * scale)
            save_clip(varied, out_dir, f"bg_amp{int(scale*10)}",
                      counts['background'])
            counts['background'] += 1

        # Apply RIR to background too (makes model more robust)
        rir_bg = apply_rir(audio, random.choice(['small', 'medium']))
        save_clip(rir_bg, out_dir, "bg_rir", counts['background'])
        counts['background'] += 1


# ── Summary ──────────────────────────────────────────────────
def print_summary():
    print("\n" + "="*55)
    print("  AUGMENTATION v2 COMPLETE")
    print("="*55)

    total_dist = (counts['snr'] + counts['speaker_mic'] +
                  counts['pocket'] + counts['rir'])

    print(f"\n  Distress clips:")
    print(f"    SNR mixing      : {counts['snr']}")
    print(f"    Speaker-mic sim : {counts['speaker_mic']}")
    print(f"    Pocket muffling : {counts['pocket']}")
    print(f"    RIR (room echo) : {counts['rir']}")
    print(f"    TOTAL distress  : {total_dist}")
    print(f"\n  Background clips  : {counts['background']}")
    print(f"  Skipped           : {counts['skipped']}")
    print(f"  Grand total       : {total_dist + counts['background']}")

    # Count files per folder
    print(f"\n  Files per folder:")
    for folder in os.listdir(AUG_DIR):
        folder_path = os.path.join(AUG_DIR, folder)
        if os.path.isdir(folder_path):
            n = len([f for f in os.listdir(folder_path)
                     if f.endswith('.wav')])
            print(f"    {folder:<30}: {n}")

    print(f"\n  Augmented folder: {AUG_DIR}")
    print(f"\n  NEXT STEPS:")
    print(f"  1. Update 04_build_manifest.py:")
    print(f"     Change AUGMENTED_DIR to 'datasets/augmented_v2'")
    print(f"  2. Run: python 04_build_manifest.py")
    print(f"  3. Run: python 05_generate_spectrograms.py")
    print(f"  4. Upload spectrograms/ to Google Drive")
    print(f"  5. Retrain on Colab")
    print(f"\n  EXPECTED IMPROVEMENT:")
    print(f"    v1: 84.8% accuracy (clean audio only)")
    print(f"    v2: 88-93% accuracy (real-world conditions)")


# ── Main ─────────────────────────────────────────────────────
if __name__ == "__main__":
    print("\n" + "★"*55)
    print("  ResQNet — Data Augmentation v2")
    print("  NEW: RIR + Speaker-Mic + Pocket Muffling")
    print("★"*55)

    # Load file lists
    distress_files = [f for f in os.listdir(DISTRESS_DIR)
                      if f.endswith('.wav')]
    bg_files       = [f for f in os.listdir(BG_DIR)
                      if f.endswith('.wav')]

    if not distress_files:
        print(f"\n  ERROR: No distress files in {DISTRESS_DIR}")
        print("  Run 02_extract_classes.py first")
        exit(1)

    if not bg_files:
        print(f"\n  ERROR: No background files in {BG_DIR}")
        print("  Run 02_extract_classes.py first")
        exit(1)

    print(f"\n  Distress files   : {len(distress_files)}")
    print(f"  Background files : {len(bg_files)}")
    print(f"\n  NEW augmentations this run:")
    print(f"    1. SNR mixing      ({len(distress_files)} × {len(SNR_LEVELS)} = "
          f"{len(distress_files) * len(SNR_LEVELS)} clips)")
    print(f"    2. RIR simulation  ({len(distress_files)} × 3 rooms = "
          f"{len(distress_files) * 3} clips)")
    print(f"    3. Speaker-mic     ({len(distress_files)} clips)")
    print(f"    4. Pocket muffling ({len(distress_files)} × 4 scenarios = "
          f"{len(distress_files) * 4} clips)")
    total = (len(distress_files) * len(SNR_LEVELS) +
             len(distress_files) * 3 +
             len(distress_files) +
             len(distress_files) * 4)
    print(f"    TOTAL DISTRESS: {total} clips")
    print(f"    (was {len(distress_files) * 5} clips with v1)")

    # Run all augmentations
    augment_with_snr(distress_files, bg_files)
    augment_with_rir(distress_files, bg_files)
    augment_with_speaker_mic(distress_files, bg_files)
    augment_with_pocket(distress_files, bg_files)
    augment_background(bg_files)

    print_summary()