"""
CycloneSOS — Script 02 (Updated): Extract and Standardise Audio
================================================================
Updated version — works WITHOUT UrbanSound8K.

Datasets used:
  REQUIRED:
    ESC-50      → crying, glass breaking, wind, rain, thunder
    RAVDESS     → fearful speech, angry speech
    storm_noise → freesound.org storm WAV files

  OPTIONAL (replaces UrbanSound8K):
    screaming/  → Kaggle screaming detection dataset
                  kaggle.com/datasets/whats2000/human-screaming-detection-dataset

HOW TO RUN:
  python 02_extract_classes.py

OUTPUT:
  datasets/processed/distress/    <- label = 1
  datasets/processed/background/  <- label = 0
"""

import os
import numpy as np
import librosa
import soundfile as sf
import pandas as pd
from tqdm import tqdm

# Config
TARGET_SR      = 22050
CLIP_DURATION  = 3.0
BASE           = os.path.dirname(os.path.abspath(__file__))
DATASETS       = os.path.join(BASE, "datasets")
PROCESSED      = os.path.join(DATASETS, "processed")
DISTRESS_DIR   = os.path.join(PROCESSED, "distress")
BACKGROUND_DIR = os.path.join(PROCESSED, "background")

for d in [DISTRESS_DIR, BACKGROUND_DIR]:
    os.makedirs(d, exist_ok=True)

ESC50_DISTRESS   = [20, 40]
ESC50_BACKGROUND = [10, 16, 19]

counts = {'distress': 0, 'background': 0, 'skipped': 0}


def load_and_standardise(filepath):
    try:
        audio, sr = librosa.load(filepath, sr=TARGET_SR, mono=True)
        target_len = int(TARGET_SR * CLIP_DURATION)
        if len(audio) >= target_len:
            start = (len(audio) - target_len) // 2
            audio = audio[start:start + target_len]
        else:
            pad   = target_len - len(audio)
            audio = np.pad(audio, (pad//2, pad - pad//2), mode='constant')
        max_val = np.max(np.abs(audio))
        if max_val > 0:
            audio = audio / max_val * 0.9
        return audio.astype(np.float32)
    except:
        return None


def save_clip(audio, output_dir, prefix, counter):
    filename = f"{prefix}_{counter:04d}.wav"
    filepath = os.path.join(output_dir, filename)
    sf.write(filepath, audio, TARGET_SR, subtype='PCM_16')
    return filename


def split_long_audio(audio, clip_duration=CLIP_DURATION):
    target_len = int(TARGET_SR * clip_duration)
    chunks = []
    for i in range(0, len(audio) - target_len + 1, target_len):
        chunk = audio[i:i + target_len]
        max_val = np.max(np.abs(chunk))
        if max_val > 0:
            chunk = chunk / max_val * 0.9
        chunks.append(chunk.astype(np.float32))
    return chunks


def extract_from_esc50():
    print("\n── ESC-50 ─────────────────────────────────────")
    meta_path = os.path.join(DATASETS, "ESC-50", "meta", "esc50.csv")
    audio_dir = os.path.join(DATASETS, "ESC-50", "audio")

    if not os.path.exists(meta_path):
        print("  NOT FOUND — Download: github.com/karolpiczak/ESC-50/archive/master.zip")
        return

    meta   = pd.read_csv(meta_path)
    d_rows = meta[meta['target'].isin(ESC50_DISTRESS)]
    b_rows = meta[meta['target'].isin(ESC50_BACKGROUND)]
    print(f"  Distress clips: {len(d_rows)}  |  Background clips: {len(b_rows)}")

    for _, row in tqdm(d_rows.iterrows(), total=len(d_rows), desc="  ESC-50 distress"):
        audio = load_and_standardise(os.path.join(audio_dir, row['filename']))
        if audio is None:
            counts['skipped'] += 1
            continue
        save_clip(audio, DISTRESS_DIR,
                  f"distress_esc50_{row['category'].replace(' ','_')}", counts['distress'])
        counts['distress'] += 1

    for _, row in tqdm(b_rows.iterrows(), total=len(b_rows), desc="  ESC-50 background"):
        audio = load_and_standardise(os.path.join(audio_dir, row['filename']))
        if audio is None:
            counts['skipped'] += 1
            continue
        save_clip(audio, BACKGROUND_DIR,
                  f"background_esc50_{row['category'].replace(' ','_')}", counts['background'])
        counts['background'] += 1


def extract_from_ravdess():
    print("\n── RAVDESS ────────────────────────────────────")
    ravdess_dir = os.path.join(DATASETS, "RAVDESS")

    if not os.path.exists(ravdess_dir):
        print("  NOT FOUND — Download: zenodo.org/record/1188976")
        print("  File needed: Audio_Speech_Actors_01-24.zip (215 MB)")
        return

    all_wav = []
    for root, _, files in os.walk(ravdess_dir):
        for f in files:
            if f.lower().endswith('.wav'):
                all_wav.append(os.path.join(root, f))

    print(f"  Total files found: {len(all_wav)}")

    distress_emotions = {'05': 'angry', '06': 'fearful'}
    distress_files    = []
    neutral_files     = []

    for path in all_wav:
        parts = os.path.basename(path).replace('.wav', '').split('-')
        if len(parts) >= 3:
            if parts[2] in distress_emotions:
                distress_files.append((path, distress_emotions[parts[2]]))
            elif parts[2] == '01':
                neutral_files.append(path)

    print(f"  Fearful + angry: {len(distress_files)}  |  Neutral (background): {len(neutral_files)}")

    for path, emotion in tqdm(distress_files, desc="  RAVDESS distress"):
        audio = load_and_standardise(path)
        if audio is None:
            counts['skipped'] += 1
            continue
        save_clip(audio, DISTRESS_DIR,
                  f"distress_ravdess_{emotion}", counts['distress'])
        counts['distress'] += 1

    for path in tqdm(neutral_files[:100], desc="  RAVDESS neutral bg"):
        audio = load_and_standardise(path)
        if audio is None:
            counts['skipped'] += 1
            continue
        save_clip(audio, BACKGROUND_DIR,
                  "background_ravdess_neutral", counts['background'])
        counts['background'] += 1


def extract_from_screaming_dataset():
    """
    Kaggle screaming dataset:
    kaggle.com/datasets/whats2000/human-screaming-detection-dataset

    Extract to: datasets/screaming/
    Folder structure inside may vary — script handles common variations.
    """
    print("\n── Kaggle Screaming Dataset ────────────────────")
    scream_dir = os.path.join(DATASETS, "screaming")

    if not os.path.exists(scream_dir):
        print("  NOT FOUND — Download from Kaggle (optional but recommended)")
        print("  kaggle.com/datasets/whats2000/human-screaming-detection-dataset")
        print("  Extract to: datasets/screaming/")
        return

    # Handle different possible subfolder names
    scream_subfolders = ['screaming', 'Screaming', 'scream', 'positive', 'yes']
    bg_subfolders     = ['not_screaming', 'Not_Screaming', 'negative', 'no', 'background']

    found_scream = False
    for subfolder in scream_subfolders:
        path = os.path.join(scream_dir, subfolder)
        if os.path.exists(path):
            files = [f for f in os.listdir(path)
                     if f.lower().endswith(('.wav','.mp3','.ogg'))]
            print(f"  Screaming files in '{subfolder}': {len(files)}")
            for f in tqdm(files, desc="  Screaming clips"):
                audio = load_and_standardise(os.path.join(path, f))
                if audio is None:
                    counts['skipped'] += 1
                    continue
                save_clip(audio, DISTRESS_DIR,
                          "distress_kaggle_scream", counts['distress'])
                counts['distress'] += 1
            found_scream = True
            break

    if not found_scream:
        # Try root of screaming folder directly
        files = [f for f in os.listdir(scream_dir)
                 if f.lower().endswith(('.wav','.mp3','.ogg'))]
        if files:
            print(f"  Found {len(files)} audio files directly in screaming/")
            for f in tqdm(files, desc="  Screaming clips"):
                audio = load_and_standardise(os.path.join(scream_dir, f))
                if audio is None:
                    counts['skipped'] += 1
                    continue
                save_clip(audio, DISTRESS_DIR,
                          "distress_kaggle_scream", counts['distress'])
                counts['distress'] += 1

    for subfolder in bg_subfolders:
        path = os.path.join(scream_dir, subfolder)
        if os.path.exists(path):
            files = [f for f in os.listdir(path)
                     if f.lower().endswith(('.wav','.mp3','.ogg'))]
            print(f"  Non-screaming in '{subfolder}': {len(files)}")
            for f in tqdm(files[:200], desc="  Non-scream bg"):
                audio = load_and_standardise(os.path.join(path, f))
                if audio is None:
                    counts['skipped'] += 1
                    continue
                save_clip(audio, BACKGROUND_DIR,
                          "background_kaggle_nonscream", counts['background'])
                counts['background'] += 1
            break


def extract_storm_noise():
    print("\n── Storm Noise (freesound.org) ─────────────────")
    storm_dir = os.path.join(DATASETS, "storm_noise")

    if not os.path.exists(storm_dir):
        print("  NOT FOUND — Download WAV files from freesound.org")
        return

    wav_files = [f for f in os.listdir(storm_dir)
                 if f.lower().endswith('.wav')]
    print(f"  Storm files found: {len(wav_files)}")

    for filename in tqdm(wav_files, desc="  Storm noise"):
        path = os.path.join(storm_dir, filename)
        try:
            audio, _ = librosa.load(path, sr=TARGET_SR, mono=True)
            chunks   = split_long_audio(audio)
            base     = os.path.splitext(filename)[0][:20].replace(' ', '_')
            for chunk in chunks:
                save_clip(chunk, BACKGROUND_DIR,
                          f"background_storm_{base}", counts['background'])
                counts['background'] += 1
        except Exception as e:
            counts['skipped'] += 1


def add_chirp_clips():
    print("\n── Multi-Band Chirp ───────────────────────────")
    chirp_path = os.path.join(BASE, "outputs", "multi_band_chirp.wav")

    if not os.path.exists(chirp_path):
        print("  multi_band_chirp.wav not found — run 14_chirp_generator.py first")
        return

    try:
        audio, _ = librosa.load(chirp_path, sr=TARGET_SR, mono=True)
        chunks   = split_long_audio(audio)
        for chunk in chunks[:20]:
            save_clip(chunk, DISTRESS_DIR,
                      "distress_chirp_multiband", counts['distress'])
            counts['distress'] += 1
        print(f"  Added {min(20, len(chunks))} chirp clips as distress samples")
    except Exception as e:
        print(f"  Error: {e}")


def print_summary():
    d_files = os.listdir(DISTRESS_DIR)
    b_files = os.listdir(BACKGROUND_DIR)
    d_count = len([f for f in d_files if f.endswith('.wav')])
    b_count = len([f for f in b_files if f.endswith('.wav')])
    total   = d_count + b_count

    print("\n" + "="*55)
    print("  EXTRACTION SUMMARY")
    print("="*55)
    print(f"  Distress  (label=1) : {d_count}")
    print(f"  Background (label=0): {b_count}")
    print(f"  Skipped             : {counts['skipped']}")
    print(f"  Total               : {total}")

    if total == 0:
        print("\n  No clips extracted — check your dataset folders")
        return

    balance = d_count / total * 100
    print(f"  Balance             : {balance:.1f}% distress")

    if balance < 30 or balance > 70:
        print("\n  WARNING: Dataset is imbalanced")
        print("  Aim for 40-60% distress")
        if d_count < b_count:
            print("  Download RAVDESS + Kaggle screaming for more distress clips")
        else:
            print("  Download more storm noise for more background clips")
    else:
        print("\n  Dataset balance is good")

    if total < 500:
        print(f"\n  WARNING: Only {total} total clips")
        print("  CNN needs at least 500 to train reliably")
        print("  Download missing datasets and re-run this script")
    else:
        print(f"\n  Dataset size is sufficient for training")

    print("\n  Next step: python 03_augment_data.py")


if __name__ == "__main__":
    print("\n" + "★"*55)
    print("  CycloneSOS — Extract and Standardise")
    print("  (No UrbanSound8K required)")
    print("★"*55)

    extract_from_esc50()
    extract_from_ravdess()
    extract_from_screaming_dataset()
    extract_storm_noise()
    add_chirp_clips()
    print_summary()