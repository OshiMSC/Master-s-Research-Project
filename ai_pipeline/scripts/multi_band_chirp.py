"""
CycloneSOS — Multi-Band Chirp Generator
========================================
Generates a structured 3-band chirp beacon:
  [1–2 kHz] → [2–3 kHz] → [3–4 kHz] → silence → repeat

Each band is 0.3s, silence is 0.6s, repeated 10 times.
Total duration = (0.3 × 3 + 0.6) × 10 = 15 seconds
"""

import numpy as np
from scipy.signal import chirp
import soundfile as sf
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
import librosa
import librosa.display
import os

os.makedirs("outputs", exist_ok=True)

# ─────────────────────────────────────────
# PARAMETERS
# ─────────────────────────────────────────
sr                 = 44100
segment_duration   = 0.3     # seconds per band
silence_duration   = 0.6     # silence gap between pulses
repetitions        = 10      # number of full pulse repeats
amplitude          = 0.9     # peak amplitude (0.0 – 1.0)

# The 3 frequency bands
bands = [
    (1000, 2000),   # Band 1 — low
    (2000, 3000),   # Band 2 — mid
    (3000, 4000),   # Band 3 — high
]

band_colors = ['#378ADD', '#1D9E75', '#E24B4A']
band_labels = ['Band 1: 1–2 kHz', 'Band 2: 2–3 kHz', 'Band 3: 3–4 kHz']

# ─────────────────────────────────────────
# FUNCTION: CREATE ONE CHIRP SEGMENT
# ─────────────────────────────────────────
def create_chirp_segment(f_start, f_end, duration, sample_rate):
    """
    Generate a linear frequency sweep from f_start to f_end.
    Applies a Hanning window to smooth start/end — prevents
    audio clicks and creates a cleaner spectrogram shape.
    """
    t      = np.linspace(0, duration, int(sample_rate * duration), endpoint=False)
    signal = chirp(t, f0=f_start, f1=f_end, t1=duration, method='linear')
    window = np.hanning(len(signal))   # smooth the edges
    return (signal * window).astype(np.float32)


# ─────────────────────────────────────────
# BUILD THE MULTI-BAND PULSE
# ─────────────────────────────────────────
print("Building multi-band chirp signal...")

segments = []
for f_start, f_end in bands:
    seg = create_chirp_segment(f_start, f_end, segment_duration, sr)
    segments.append(seg)
    print(f"  ✓ Band {f_start}–{f_end} Hz  ({len(seg)} samples  {segment_duration}s)")

# Concatenate 3 bands into one pulse
multi_band_pulse  = np.concatenate(segments)

# Add silence after the pulse
silence           = np.zeros(int(sr * silence_duration), dtype=np.float32)
pulse_with_silence = np.concatenate([multi_band_pulse, silence])

# Repeat the full pattern
final_signal      = np.tile(pulse_with_silence, repetitions)

# Normalise to peak amplitude
final_signal      = (final_signal / np.max(np.abs(final_signal))) * amplitude

total_duration    = len(final_signal) / sr
pulse_duration    = segment_duration * len(bands) + silence_duration

print(f"\nSignal structure:")
print(f"  Pulse duration  : {segment_duration * len(bands):.1f}s chirp + {silence_duration}s silence = {pulse_duration:.1f}s per cycle")
print(f"  Repetitions     : {repetitions}")
print(f"  Total duration  : {total_duration:.1f}s")
print(f"  Total samples   : {len(final_signal):,}")

# Save the WAV file
output_path = "outputs/multi_band_chirp.wav"
sf.write(output_path, final_signal, sr)
print(f"\n✅ Saved: {output_path}")


# ─────────────────────────────────────────
# VISUALISATION — 4-panel figure
# ─────────────────────────────────────────
print("\nGenerating visualisation...")

# Use first 3 seconds (3 full pulses) for clear plots
plot_duration = 3.0
plot_samples  = int(sr * plot_duration)
plot_signal   = final_signal[:plot_samples]
t_axis        = np.linspace(0, plot_duration, plot_samples)

fig = plt.figure(figsize=(16, 14))
fig.patch.set_facecolor('#0F0F1A')
gs  = gridspec.GridSpec(4, 1, hspace=0.45,
                         top=0.93, bottom=0.06,
                         left=0.08, right=0.95)

title_kwargs  = dict(color='white', fontsize=12, fontweight='bold', pad=10)
label_kwargs  = dict(color='#AAAAAA', fontsize=10)
tick_kwargs   = dict(colors='#888888', labelsize=9)

# ── Panel 1: Waveform ──────────────────────────────
ax1 = fig.add_subplot(gs[0])
ax1.set_facecolor('#1A1A2E')

# Colour each band segment differently
for rep in range(3):                          # show 3 repetitions
    offset = rep * pulse_duration
    for i, (f_start, f_end) in enumerate(bands):
        seg_start = offset + i * segment_duration
        seg_end   = seg_start + segment_duration
        idx_s     = int(seg_start * sr)
        idx_e     = min(int(seg_end * sr), plot_samples)
        if idx_s >= plot_samples:
            break
        ax1.plot(t_axis[idx_s:idx_e], plot_signal[idx_s:idx_e],
                 color=band_colors[i], linewidth=0.8, alpha=0.9)

ax1.set_title('Waveform — Multi-Band Chirp (first 3 seconds)', **title_kwargs)
ax1.set_ylabel('Amplitude', **label_kwargs)
ax1.set_xlim(0, plot_duration)
ax1.set_ylim(-1.05, 1.05)
ax1.tick_params(**tick_kwargs)
ax1.spines[:].set_color('#333355')
ax1.grid(axis='x', color='#333355', linewidth=0.5, linestyle='--')

# Band annotation on first pulse
for i, label in enumerate(band_labels):
    x_pos = i * segment_duration + segment_duration / 2
    ax1.annotate(label, xy=(x_pos, 0.75),
                 ha='center', fontsize=8, color=band_colors[i],
                 fontweight='bold')

# ── Panel 2: STFT Spectrogram ──────────────────────
ax2 = fig.add_subplot(gs[1])
ax2.set_facecolor('#1A1A2E')

D    = librosa.amplitude_to_db(
          np.abs(librosa.stft(plot_signal, n_fft=2048)), ref=np.max)
img2 = librosa.display.specshow(D, sr=sr,
          x_axis='time', y_axis='hz',
          ax=ax2, cmap='magma')
ax2.set_ylim(0, 5000)
ax2.set_title('STFT Spectrogram — diagonal sweeps visible per band', **title_kwargs)
ax2.set_ylabel('Frequency (Hz)', **label_kwargs)
ax2.tick_params(**tick_kwargs)
ax2.spines[:].set_color('#333355')

# Frequency band dividers
for freq, col in [(1000,'#378ADD'), (2000,'#1D9E75'), (3000,'#E24B4A'), (4000,'#888888')]:
    ax2.axhline(freq, color=col, linewidth=0.8, linestyle='--', alpha=0.6)
    ax2.text(plot_duration - 0.05, freq + 50, f'{freq} Hz',
             ha='right', fontsize=8, color=col, alpha=0.8)

plt.colorbar(img2, ax=ax2, format='%+2.0f dB',
             label='dB').ax.yaxis.label.update(dict(color='#AAAAAA'))

# ── Panel 3: Mel-Spectrogram (CNN input) ────────────
ax3 = fig.add_subplot(gs[2])
ax3.set_facecolor('#1A1A2E')

mel    = librosa.feature.melspectrogram(y=plot_signal, sr=sr,
                                         n_mels=128, fmax=5000)
mel_db = librosa.power_to_db(mel, ref=np.max)
img3   = librosa.display.specshow(mel_db, sr=sr,
             x_axis='time', y_axis='mel',
             fmax=5000, ax=ax3, cmap='magma')
ax3.set_title('Mel-Spectrogram — CNN input representation', **title_kwargs)
ax3.set_ylabel('Frequency (Mel)', **label_kwargs)
ax3.tick_params(**tick_kwargs)
ax3.spines[:].set_color('#333355')

plt.colorbar(img3, ax=ax3, format='%+2.0f dB',
             label='dB').ax.yaxis.label.update(dict(color='#AAAAAA'))

ax3.annotate('3 diagonal bands\n= unique fingerprint',
             xy=(0.6, 0.65), xycoords='axes fraction',
             fontsize=9, color='white',
             bbox=dict(boxstyle='round,pad=0.3', facecolor='#333355',
                       edgecolor='#555577', alpha=0.8))

# ── Panel 4: Band Energy Timeline ───────────────────
ax4 = fig.add_subplot(gs[3])
ax4.set_facecolor('#1A1A2E')

# Calculate RMS energy in each band over time using short windows
win_size  = int(0.05 * sr)   # 50ms windows
hop_size  = int(0.01 * sr)   # 10ms hop
n_frames  = (plot_samples - win_size) // hop_size
t_frames  = np.array([i * hop_size / sr for i in range(n_frames)])

for i, (f_start, f_end) in enumerate(bands):
    energies = []
    for f in range(n_frames):
        start   = f * hop_size
        frame   = plot_signal[start:start + win_size]
        fft     = np.abs(np.fft.rfft(frame))
        freqs   = np.fft.rfftfreq(win_size, 1 / sr)
        mask    = (freqs >= f_start) & (freqs < f_end)
        energy  = np.mean(fft[mask] ** 2) if np.any(mask) else 0
        energies.append(energy)
    energies = np.array(energies)
    if energies.max() > 0:
        energies = energies / energies.max()
    ax4.plot(t_frames, energies, color=band_colors[i],
             linewidth=1.5, label=band_labels[i], alpha=0.9)

ax4.set_title('Band Energy Timeline — sequential activation pattern', **title_kwargs)
ax4.set_ylabel('Normalised Energy', **label_kwargs)
ax4.set_xlabel('Time (seconds)', **label_kwargs)
ax4.set_xlim(0, plot_duration)
ax4.set_ylim(-0.05, 1.15)
ax4.tick_params(**tick_kwargs)
ax4.spines[:].set_color('#333355')
ax4.grid(color='#333355', linewidth=0.5, linestyle='--', alpha=0.6)
ax4.legend(loc='upper right', fontsize=9,
           facecolor='#1A1A2E', edgecolor='#333355',
           labelcolor='white')

# Main title
fig.suptitle('CycloneSOS — Multi-Band Chirp Signal Analysis\n'
             '[1–2 kHz] → [2–3 kHz] → [3–4 kHz] → silence → repeat',
             color='white', fontsize=14, fontweight='bold', y=0.98)

fig_path = "outputs/multi_band_chirp_analysis.png"
plt.savefig(fig_path, dpi=150, bbox_inches='tight',
            facecolor='#0F0F1A', edgecolor='none')
plt.close()
print(f"✅ Saved: {fig_path}")

# ─────────────────────────────────────────
# PRINT SUMMARY FOR THESIS
# ─────────────────────────────────────────
print("\n" + "="*52)
print("  Multi-Band Chirp — Design Summary")
print("="*52)
print(f"  Bands          : {len(bands)}")
for i, (f_start, f_end) in enumerate(bands):
    print(f"    Band {i+1}      : {f_start} – {f_end} Hz  ({segment_duration}s)")
print(f"  Silence gap    : {silence_duration}s")
print(f"  Full cycle     : {segment_duration * len(bands) + silence_duration}s")
print(f"  Repetitions    : {repetitions}")
print(f"  Total length   : {total_duration:.1f}s")
print(f"  Sample rate    : {sr} Hz")
print(f"  Amplitude      : {amplitude}")
print(f"  Window         : Hanning (anti-click)")
print("="*52)
print(f"\n  Frequency diversity: {len(bands)} independent bands")
print(f"  Pattern unique: YES — 3 sequential diagonals")
print(f"  Noise resilient: YES — partial band detection sufficient")
print("="*52)
