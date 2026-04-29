"""
CycloneSOS — Script 01: Explore Datasets
==========================================
Run this FIRST before anything else.
This script reads your downloaded datasets and tells you
exactly what files are inside and which ones you need.

HOW TO RUN:
  python 01_explore_datasets.py

WHAT IT DOES:
  - Reads ESC-50 metadata CSV
  - Reads UrbanSound8K metadata CSV
  - Lists all category numbers and names
  - Counts files per category
  - Tells you exactly which files to use

BEFORE RUNNING:
  Download datasets and place them like this:
    datasets/ESC-50/           ← from github.com/karolpiczak/ESC-50
    datasets/UrbanSound8K/     ← from urbansounddataset.weebly.com
    datasets/storm_noise/      ← WAV files from freesound.org
"""

import os
import pandas as pd

# ── Paths ─────────────────────────────────────────────────
BASE      = os.path.dirname(os.path.abspath(__file__))
DATASETS  = os.path.join(BASE, "datasets")
ESC50_DIR = os.path.join(DATASETS, "ESC-50")
US8K_DIR  = os.path.join(DATASETS, "UrbanSound8K")
STORM_DIR = os.path.join(DATASETS, "storm_noise")


def print_header(title):
    print("\n" + "="*55)
    print(f"  {title}")
    print("="*55)


def explore_esc50():
    print_header("ESC-50 Dataset")
    meta_path = os.path.join(ESC50_DIR, "meta", "esc50.csv")

    if not os.path.exists(meta_path):
        print(f"  ❌ NOT FOUND: {meta_path}")
        print("  → Download from: github.com/karolpiczak/ESC-50")
        print("  → Extract to: datasets/ESC-50/")
        return None

    meta = pd.read_csv(meta_path)
    print(f"  ✓ Found: {len(meta)} total audio files")
    print(f"  ✓ Columns: {list(meta.columns)}")

    print("\n  All 50 categories:")
    print(f"  {'#':<5} {'Category':<30} {'Files':<8} {'Use For'}")
    print("  " + "-"*60)

    # Categories relevant to CycloneSOS marked with ★
    relevant = {
        10: ('rain',        'BACKGROUND noise'),
        11: ('sea_waves',   'BACKGROUND noise'),
        16: ('wind',        'BACKGROUND noise ★ PRIMARY'),
        17: ('crickets',    'BACKGROUND noise'),
        19: ('thunderstorm','BACKGROUND noise ★ PRIMARY'),
        20: ('crying_baby', 'DISTRESS sound ★ PRIMARY'),
        40: ('glass_breaking','DISTRESS sound ★ PRIMARY'),
    }

    summary = meta.groupby(['target', 'category']).size().reset_index(name='count')
    for _, row in summary.iterrows():
        target = row['target']
        cat    = row['category']
        count  = row['count']
        note   = relevant.get(target, ('', ''))[1] if target in relevant else ''
        star   = ' ★' if target in relevant else ''
        print(f"  {target:<5} {cat:<30} {count:<8} {note}")

    print(f"\n  Categories YOU need for CycloneSOS:")
    for target, (cat, use) in relevant.items():
        files = meta[meta['target'] == target]
        print(f"    [{target:02d}] {cat:<25} {len(files)} files  →  {use}")

    return meta


def explore_urbansound8k():
    print_header("UrbanSound8K Dataset")
    meta_path = os.path.join(US8K_DIR, "metadata", "UrbanSound8K.csv")

    if not os.path.exists(meta_path):
        print(f"  ❌ NOT FOUND: {meta_path}")
        print("  → Download from: urbansounddataset.weebly.com")
        print("  → Extract to: datasets/UrbanSound8K/")
        return None

    meta = pd.read_csv(meta_path)
    print(f"  ✓ Found: {len(meta)} total audio files")

    # UrbanSound8K class IDs relevant to CycloneSOS
    relevant = {
        1:  'children_playing — contains screaming',
        6:  'gun_shot         — distress indicator',
        7:  'jackhammer       — structural/collapse sound',
        9:  'street_music     — background (safe)',
    }

    print(f"\n  All 10 categories:")
    print(f"  {'ID':<5} {'Class':<30} {'Files':<8} {'Use For'}")
    print("  " + "-"*60)

    summary = meta.groupby(['classID', 'class']).size().reset_index(name='count')
    for _, row in summary.iterrows():
        cid   = row['classID']
        cname = row['class']
        count = row['count']
        note  = relevant.get(cid, '')
        print(f"  {cid:<5} {cname:<30} {count:<8} {note}")

    print(f"\n  For screaming — we use AudioSet or RAVDESS")
    print(f"  UrbanSound8K mainly gives us: gun_shot, street sounds")
    return meta


def explore_storm_noise():
    print_header("Storm Noise Files (from freesound.org)")

    if not os.path.exists(STORM_DIR):
        os.makedirs(STORM_DIR, exist_ok=True)
        print(f"  ❌ Folder created but EMPTY: {STORM_DIR}")
        print("  → Download storm audio from freesound.org:")
        print("     Search: 'heavy wind'    → download 10+ WAV files")
        print("     Search: 'cyclone sound' → download 10+ WAV files")
        print("     Search: 'heavy rain'    → download 10+ WAV files")
        print("     Search: 'thunderstorm'  → download 10+ WAV files")
        print("  → Place all .wav files inside datasets/storm_noise/")
        return

    wav_files = [f for f in os.listdir(STORM_DIR) if f.endswith('.wav')]
    print(f"  Found: {len(wav_files)} WAV files")

    if wav_files:
        import librosa
        total_duration = 0
        for f in wav_files:
            path = os.path.join(STORM_DIR, f)
            try:
                dur = librosa.get_duration(path=path)
                total_duration += dur
                print(f"    {f:<45} {dur:.1f}s")
            except Exception as e:
                print(f"    {f} — error: {e}")
        print(f"\n  Total storm audio: {total_duration:.1f}s ({total_duration/60:.1f} minutes)")
        if total_duration < 300:
            print("  ⚠ Recommendation: download more storm audio (aim for 10+ minutes)")
        else:
            print("  ✓ Sufficient storm audio for training")
    else:
        print("  ⚠ No WAV files found — please download storm audio")


def check_folder_structure():
    print_header("Checking Folder Structure")

    folders = {
        DATASETS:              "datasets root",
        ESC50_DIR:             "ESC-50 dataset",
        US8K_DIR:              "UrbanSound8K dataset",
        STORM_DIR:             "storm noise audio",
    }

    all_good = True
    for path, name in folders.items():
        exists = os.path.exists(path)
        status = "✓" if exists else "❌ MISSING"
        print(f"  {status}  {name}")
        print(f"       {path}")
        if not exists:
            all_good = False
            os.makedirs(path, exist_ok=True)
            print(f"       → Created empty folder")

    if all_good:
        print("\n  ✓ All folders exist — ready to proceed")
    else:
        print("\n  ⚠ Some datasets missing — download them first")
        print("  → Script will still run and create the folder structure")


# ── Main ──────────────────────────────────────────────────
if __name__ == "__main__":
    print("\n" + "★"*55)
    print("  CycloneSOS — Dataset Explorer")
    print("  Run this to understand your data before processing")
    print("★"*55)

    check_folder_structure()
    esc_meta  = explore_esc50()
    us8k_meta = explore_urbansound8k()
    explore_storm_noise()

    print_header("Summary — What To Download")
    print("""
  1. ESC-50 Dataset (~600 MB)
     → github.com/karolpiczak/ESC-50/archive/master.zip
     → Extract to: datasets/ESC-50/
     → You need categories: 16 (wind), 19 (thunderstorm),
                            20 (crying_baby), 40 (glass_breaking)

  2. UrbanSound8K (~6 GB)
     → urbansounddataset.weebly.com
     → Extract to: datasets/UrbanSound8K/
     → You need: gun_shot files as distress indicators

  3. RAVDESS Screaming Audio (~500 MB subset)
     → zenodo.org/record/1188976
     → Download only Actor folders 01–10 to save space
     → Extract to: datasets/RAVDESS/
     → Use fearful (06) and angry (05) speech files

  4. Storm Noise (~50 files)
     → freesound.org → search "heavy wind", "cyclone", "heavy rain"
     → Download as WAV
     → Place in: datasets/storm_noise/

  After downloading, run:  python 02_extract_classes.py
    """)
