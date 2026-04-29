"""
CycloneSOS — Script 05: Generate Mel-Spectrograms
===================================================
Converts every audio file in the manifest to a
Mel-Spectrogram numpy array — the exact input your CNN sees.

WHY MEL-SPECTROGRAM:
  Raw audio waveforms are too complex for direct CNN input.
  A Mel-Spectrogram converts audio into a 2D image (time × frequency)
  that captures how energy is distributed — exactly like a photograph
  of the sound. CNNs are excellent at finding patterns in images.

OUTPUT SHAPE PER CLIP:
  (128, 128, 1)  ← 128 mel bands × 128 time frames × 1 channel

HOW TO RUN:
  python 05_generate_spectrograms.py

OUTPUT:
  datasets/spectrograms/
    Each .npy file is one spectrogram ready for training

THEN:
  Upload datasets/spectrograms/ to Google Drive
  Open CycloneSOS_Training.ipynb in Google Colab
  Mount Drive and train
"""

import os
import numpy as np
import librosa
import pandas as pd
from tqdm import tqdm
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec

# ── Config ────────────────────────────────────────────────
TARGET_SR       = 22050
N_MELS          = 128       # number of Mel filter banks
N_FFT           = 2048      # FFT window size
HOP_LENGTH      = 512       # samples between frames
TARGET_SHAPE    = (128, 128) # output spectrogram shape (H × W)
CLIP_DURATION   = 3.0

BASE            = os.path.dirname(os.path.abspath(__file__))
DATASETS        = os.path.join(BASE, "datasets")
MANIFEST_PATH   = os.path.join(DATASETS, "dataset_manifest.csv")
SPEC_DIR        = os.path.join(DATASETS, "spectrograms")
FIGURES_DIR     = os.path.join(BASE, "outputs")

os.makedirs(SPEC_DIR,    exist_ok=True)
os.makedirs(FIGURES_DIR, exist_ok=True)


def audio_to_melspectrogram(audio, sr=TARGET_SR):
    """
    Convert raw audio array to a normalised Mel-Spectrogram.

    Steps:
      1. Compute mel-scaled power spectrogram
      2. Convert power to decibels (log scale)
      3. Normalise to range [0, 1]
      4. Resize to TARGET_SHAPE (128 × 128)

    Returns:
      numpy array of shape (128, 128, 1) — ready for CNN
    """
    # Step 1: Mel-Spectrogram (power)
    mel = librosa.feature.melspectrogram(
        y          = audio,
        sr         = sr,
        n_mels     = N_MELS,
        n_fft      = N_FFT,
        hop_length = HOP_LENGTH,
        fmax       = 8000       # focus on 0–8000 Hz range
    )

    # Step 2: Convert to dB (log scale — matches human hearing)
    mel_db = librosa.power_to_db(mel, ref=np.max)

    # Step 3: Resize to TARGET_SHAPE (128 × 128)
    # Use simple interpolation if shape doesn't match
    if mel_db.shape != TARGET_SHAPE:
        from PIL import Image
        img    = Image.fromarray(mel_db.astype(np.float32))
        img    = img.resize((TARGET_SHAPE[1], TARGET_SHAPE[0]),
                            Image.BILINEAR)
        mel_db = np.array(img)

    # Step 4: Normalise to [0, 1]
    mel_min = mel_db.min()
    mel_max = mel_db.max()
    if mel_max - mel_min > 0:
        mel_norm = (mel_db - mel_min) / (mel_max - mel_min)
    else:
        mel_norm = np.zeros_like(mel_db)

    # Add channel dimension → (128, 128, 1)
    return mel_norm[..., np.newaxis].astype(np.float32)


def process_manifest():
    """Convert all audio files in manifest to spectrograms."""
    if not os.path.exists(MANIFEST_PATH):
        print(f"  ❌ Manifest not found: {MANIFEST_PATH}")
        print("     Run 04_build_manifest.py first")
        return 0, 0

    df      = pd.read_csv(MANIFEST_PATH)
    success = 0
    errors  = 0

    # Update manifest with spectrogram paths
    spec_paths = []

    for idx, row in tqdm(df.iterrows(),
                         total=len(df),
                         desc="  Converting to spectrograms"):
        audio_path = os.path.join(BASE, row['filepath'])

        if not os.path.exists(audio_path):
            spec_paths.append(None)
            errors += 1
            continue

        try:
            # Load audio
            audio, _ = librosa.load(audio_path, sr=TARGET_SR, mono=True)

            # Ensure correct length
            target_len = int(TARGET_SR * CLIP_DURATION)
            if len(audio) >= target_len:
                audio = audio[:target_len]
            else:
                audio = np.pad(audio, (0, target_len - len(audio)))

            # Convert to spectrogram
            spec = audio_to_melspectrogram(audio)

            # Save as .npy file
            spec_filename = os.path.splitext(
                os.path.basename(row['filepath'])
            )[0] + '.npy'
            spec_path = os.path.join(SPEC_DIR, spec_filename)
            np.save(spec_path, spec)

            spec_paths.append(
                os.path.relpath(spec_path, BASE)
            )
            success += 1

        except Exception as e:
            spec_paths.append(None)
            errors += 1

    # Save updated manifest with spectrogram paths
    df['spec_filepath'] = spec_paths
    df.to_csv(MANIFEST_PATH, index=False)

    return success, errors


def visualise_spectrograms():
    """
    Generate comparison figure showing spectrograms for each
    sound category — this becomes Figure 1 in your thesis.
    """
    print("\n  Generating spectrogram comparison figure...")

    if not os.path.exists(MANIFEST_PATH):
        return

    df = pd.read_csv(MANIFEST_PATH)
    df = df.dropna(subset=['spec_filepath'])

    # Pick one example per category
    categories = df['category'].unique()
    n_cats     = len(categories)
    if n_cats == 0:
        return

    cols = min(4, n_cats)
    rows = (n_cats + cols - 1) // cols

    fig, axes = plt.subplots(rows, cols,
                              figsize=(cols * 4, rows * 3.5))
    fig.patch.set_facecolor('#0F0F1A')

    if rows == 1 and cols == 1:
        axes = np.array([[axes]])
    elif rows == 1:
        axes = axes[np.newaxis, :]
    elif cols == 1:
        axes = axes[:, np.newaxis]

    label_colors = {0: '#1D9E75', 1: '#E24B4A'}
    label_names  = {0: 'Safe', 1: 'Distress'}

    for idx, category in enumerate(sorted(categories)):
        row_idx = idx // cols
        col_idx = idx % cols
        ax      = axes[row_idx][col_idx]
        ax.set_facecolor('#1A1A2E')

        # Get one example from this category
        cat_df  = df[df['category'] == category]
        if len(cat_df) == 0:
            ax.axis('off')
            continue

        sample      = cat_df.iloc[0]
        spec_path   = os.path.join(BASE, sample['spec_filepath'])

        if not os.path.exists(spec_path):
            ax.axis('off')
            continue

        spec = np.load(spec_path)[:, :, 0]     # remove channel dim

        ax.imshow(spec, aspect='auto', origin='lower',
                  cmap='magma', vmin=0, vmax=1)

        label_color = label_colors.get(sample['label'], 'white')
        label_name  = label_names.get(sample['label'],  'Unknown')

        ax.set_title(f"{category}\n({label_name})",
                     color=label_color, fontsize=10, fontweight='bold', pad=6)
        ax.set_xlabel('Time frames', color='#888888', fontsize=8)
        ax.set_ylabel('Mel bands',   color='#888888', fontsize=8)
        ax.tick_params(colors='#666666', labelsize=7)
        ax.spines[:].set_color('#333355')

    # Hide empty subplots
    for idx in range(n_cats, rows * cols):
        axes[idx // cols][idx % cols].axis('off')

    fig.suptitle('CycloneSOS — Mel-Spectrogram per Sound Category\n'
                 'Red title = Distress (label=1)   Green title = Safe (label=0)',
                 color='white', fontsize=13, fontweight='bold', y=1.01)

    plt.tight_layout()
    save_path = os.path.join(FIGURES_DIR,
                             'Figure_1_spectrogram_comparison.png')
    plt.savefig(save_path, dpi=150, bbox_inches='tight',
                facecolor='#0F0F1A', edgecolor='none')
    plt.close()
    print(f"  ✓ Saved: {save_path}")


def print_dataset_stats():
    """Print final dataset statistics."""
    if not os.path.exists(MANIFEST_PATH):
        return

    df   = pd.read_csv(MANIFEST_PATH)
    good = df.dropna(subset=['spec_filepath'])

    print("\n" + "="*55)
    print("  SPECTROGRAM DATASET READY")
    print("="*55)
    print(f"  Total spectrograms : {len(good)}")
    print(f"  Shape per clip     : {TARGET_SHAPE} + 1 channel")
    print(f"  Distress (1)       : {len(good[good['label']==1])}")
    print(f"  Background (0)     : {len(good[good['label']==0])}")
    print(f"\n  Split sizes:")
    for split in ['train', 'val', 'test']:
        s = good[good['split'] == split]
        print(f"    {split:<8}: {len(s):>5} spectrograms")
    print(f"\n  Spectrogram folder : {SPEC_DIR}")
    size_mb = sum(
        os.path.getsize(os.path.join(SPEC_DIR, f))
        for f in os.listdir(SPEC_DIR) if f.endswith('.npy')
    ) / 1024 / 1024 if os.path.exists(SPEC_DIR) else 0
    print(f"  Total size         : {size_mb:.1f} MB")
    print(f"\n  ✓ Upload datasets/ folder to Google Drive")
    print(f"  ✓ Then open CycloneSOS_Training.ipynb in Colab")


# ── Main ──────────────────────────────────────────────────
if __name__ == "__main__":
    print("\n" + "★"*55)
    print("  CycloneSOS — Generate Mel-Spectrograms")
    print(f"  Output shape  : {TARGET_SHAPE} per clip")
    print(f"  Mel bands     : {N_MELS}")
    print(f"  FFT window    : {N_FFT}")
    print(f"  Hop length    : {HOP_LENGTH}")
    print("★"*55)

    # Check PIL availability for resize
    try:
        from PIL import Image
        print("  ✓ PIL available for spectrogram resize")
    except ImportError:
        print("  Installing Pillow...")
        os.system("pip install Pillow --break-system-packages -q")

    print("\n  Converting audio files to spectrograms...")
    success, errors = process_manifest()

    print(f"\n  ✓ Success : {success}")
    print(f"  ✗ Errors  : {errors}")

    visualise_spectrograms()
    print_dataset_stats()

    print("\n  Next step:")
    print("  1. Upload datasets/spectrograms/ to Google Drive")
    print("  2. Open CycloneSOS_Training.ipynb in Google Colab")
    print("  3. Run all cells to train the CNN")
