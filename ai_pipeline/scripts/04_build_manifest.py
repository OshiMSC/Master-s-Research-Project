"""
CycloneSOS — Script 04: Build Dataset Manifest
================================================
Scans all augmented audio files and builds a master CSV
that maps every file to its label, source, and SNR level.

This CSV is the single source of truth for all training.

HOW TO RUN:
  python 04_build_manifest.py

OUTPUT:
  datasets/dataset_manifest.csv

Columns:
  filepath    ← relative path to audio file
  label       ← 0 (background/safe) or 1 (distress)
  source      ← esc50 / ravdess / us8k / storm / chirp
  snr_db      ← SNR level used in augmentation
  category    ← crying / glass_breaking / wind / rain / etc.
  duration    ← clip duration in seconds
  split       ← train / val / test
"""

import os
import pandas as pd
import numpy as np
import librosa
from tqdm import tqdm
from sklearn.model_selection import train_test_split

# ── Config ────────────────────────────────────────────────
BASE          = os.path.dirname(os.path.abspath(__file__))
DATASETS      = os.path.join(BASE, "datasets")
AUGMENTED_DIR = os.path.join(DATASETS, "augmented")
MANIFEST_PATH = os.path.join(DATASETS, "dataset_manifest.csv")

TARGET_SR     = 22050
CLIP_DURATION = 3.0

# ── Label mapping from folder/filename ────────────────────
SNR_LEVELS = [0, -5, -10, -15, -20]


def infer_category(filename):
    """Infer sound category from filename."""
    fname = filename.lower()
    if 'cry'       in fname: return 'crying'
    if 'glass'     in fname: return 'glass_breaking'
    if 'scream'    in fname: return 'screaming'
    if 'fearful'   in fname: return 'fearful_speech'
    if 'angry'     in fname: return 'angry_speech'
    if 'gunshot'   in fname: return 'gunshot'
    if 'chirp'     in fname: return 'chirp_beacon'
    if 'wind'      in fname: return 'wind'
    if 'rain'      in fname: return 'rain'
    if 'thunder'   in fname: return 'thunderstorm'
    if 'storm'     in fname: return 'storm'
    if 'wave'      in fname: return 'sea_waves'
    return 'unknown'


def infer_source(filename):
    """Infer dataset source from filename."""
    fname = filename.lower()
    if 'esc50'   in fname: return 'esc50'
    if 'ravdess' in fname: return 'ravdess'
    if 'us8k'    in fname: return 'us8k'
    if 'chirp'   in fname: return 'chirp'
    if 'storm'   in fname: return 'freesound'
    return 'unknown'


def scan_augmented_folder():
    """Scan all augmented folders and collect file metadata."""
    records = []

    # ── Distress files (label = 1) ────────────────────────
    for snr in SNR_LEVELS:
        folder = os.path.join(AUGMENTED_DIR, f"distress_snr{snr}")
        if not os.path.exists(folder):
            print(f"  ⚠ Not found: {folder}")
            continue

        files = [f for f in os.listdir(folder) if f.endswith('.wav')]
        print(f"  distress_snr{snr:<4}: {len(files)} files")

        for filename in files:
            filepath = os.path.join(folder, filename)
            records.append({
                'filepath': os.path.relpath(filepath, BASE),
                'filename': filename,
                'label':    1,
                'snr_db':   snr,
                'category': infer_category(filename),
                'source':   infer_source(filename),
                'duration': CLIP_DURATION,
                'split':    None   # assigned later
            })

    # ── Background files (label = 0) ─────────────────────
    bg_folder = os.path.join(AUGMENTED_DIR, "background_noisy")
    if os.path.exists(bg_folder):
        bg_files = [f for f in os.listdir(bg_folder) if f.endswith('.wav')]
        print(f"  background_noisy : {len(bg_files)} files")

        for filename in bg_files:
            filepath = os.path.join(bg_folder, filename)
            records.append({
                'filepath': os.path.relpath(filepath, BASE),
                'filename': filename,
                'label':    0,
                'snr_db':   None,
                'category': infer_category(filename),
                'source':   infer_source(filename),
                'duration': CLIP_DURATION,
                'split':    None
            })

    # Also include original processed distress files
    dist_dir = os.path.join(DATASETS, "processed", "distress")
    if os.path.exists(dist_dir):
        orig_files = [f for f in os.listdir(dist_dir) if f.endswith('.wav')]
        print(f"  processed/distress: {len(orig_files)} original files")
        for filename in orig_files:
            filepath = os.path.join(dist_dir, filename)
            records.append({
                'filepath': os.path.relpath(filepath, BASE),
                'filename': filename,
                'label':    1,
                'snr_db':   None,
                'category': infer_category(filename),
                'source':   infer_source(filename),
                'duration': CLIP_DURATION,
                'split':    None
            })

    return pd.DataFrame(records)


def assign_splits(df, test_size=0.10, val_size=0.10, random_state=42):
    """
    Split dataset into train / val / test maintaining
    label balance in each split.

    Strategy:
      - 80% train, 10% val, 10% test
      - Stratified by label to keep balance
    """
    # First split off test set
    df_train_val, df_test = train_test_split(
        df, test_size=test_size,
        stratify=df['label'],
        random_state=random_state
    )
    # Then split val from train
    val_size_adjusted = val_size / (1 - test_size)
    df_train, df_val  = train_test_split(
        df_train_val, test_size=val_size_adjusted,
        stratify=df_train_val['label'],
        random_state=random_state
    )

    df.loc[df_train.index, 'split'] = 'train'
    df.loc[df_val.index,   'split'] = 'val'
    df.loc[df_test.index,  'split'] = 'test'

    return df


def print_manifest_summary(df):
    """Print a summary of the dataset manifest."""
    print("\n" + "="*55)
    print("  MANIFEST SUMMARY")
    print("="*55)
    print(f"  Total clips    : {len(df)}")
    print(f"  Distress (1)   : {len(df[df['label']==1])}")
    print(f"  Background (0) : {len(df[df['label']==0])}")

    balance = len(df[df['label']==1]) / len(df) * 100
    print(f"  Balance        : {balance:.1f}% distress")
    if 40 <= balance <= 60:
        print("  ✓ Dataset is well balanced")
    else:
        print("  ⚠ Dataset is imbalanced — consider adding more clips")

    print(f"\n  Split breakdown:")
    for split in ['train', 'val', 'test']:
        split_df = df[df['split'] == split]
        d = len(split_df[split_df['label']==1])
        b = len(split_df[split_df['label']==0])
        print(f"    {split:<8}: {len(split_df):>5} total  "
              f"({d} distress, {b} background)")

    print(f"\n  By SNR level (distress clips):")
    for snr in [None] + SNR_LEVELS:
        snr_df = df[(df['label']==1) & (df['snr_db']==snr)]
        label  = f"Clean (no noise)" if snr is None else f"SNR {snr:+d} dB"
        print(f"    {label:<20}: {len(snr_df)}")

    print(f"\n  By category:")
    for cat, count in df['category'].value_counts().items():
        label_counts = df[df['category']==cat]['label'].value_counts()
        d = label_counts.get(1, 0)
        b = label_counts.get(0, 0)
        print(f"    {cat:<25}: {count:>5}  (dist={d}, bg={b})")

    print(f"\n  By source:")
    for src, count in df['source'].value_counts().items():
        print(f"    {src:<15}: {count}")


# ── Main ──────────────────────────────────────────────────
if __name__ == "__main__":
    print("\n" + "★"*55)
    print("  CycloneSOS — Build Dataset Manifest")
    print("★"*55)

    print("\n  Scanning augmented folders...")
    df = scan_augmented_folder()

    if len(df) == 0:
        print("\n  ❌ No files found in augmented folder")
        print("     Run scripts 01, 02, 03 first")
        exit(1)

    print(f"\n  Total files found: {len(df)}")
    print("\n  Assigning train/val/test splits (80/10/10)...")
    df = assign_splits(df)

    # Save manifest
    df.to_csv(MANIFEST_PATH, index=False)
    print(f"\n  ✓ Saved manifest to: {MANIFEST_PATH}")

    # Save split-specific CSVs for easy loading during training
    for split in ['train', 'val', 'test']:
        split_df   = df[df['split'] == split]
        split_path = os.path.join(DATASETS, f"{split}_labels.csv")
        split_df.to_csv(split_path, index=False)
        print(f"  ✓ Saved {split_path}")

    print_manifest_summary(df)
    print("\n  Next step: python 05_generate_spectrograms.py")
