import numpy as np
from scipy.signal import chirp
import sounddevice as sd
import soundfile as sf

def create_rescue_chirp(duration=0.5, fs=44100):
    t = np.linspace(0, duration, int(fs * duration))
    # 1kHz to 2.5kHz is the 'sweet spot' for distance and speaker volume
    signal = chirp(t, f0=1000, f1=2500, t1=duration, method='linear')
    
    # Apply a Hanning window to avoid 'clicks' at the start/end
    signal *= np.hanning(len(signal))
    return signal.astype(np.float32)

# Generate and Save the 'Master' chirp to use for Week 2 & 3
fs = 44100
my_chirp = create_rescue_chirp()
sf.write('rescue_chirp_master.wav', my_chirp, fs)

print("✅ Master Chirp Created: rescue_chirp_master.wav")
# sd.play(my_chirp, fs) # Uncomment to hear it