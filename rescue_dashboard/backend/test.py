import pyaudio

audio = pyaudio.PyAudio()
for i in range(audio.get_device_count()):
    dev = audio.get_device_info_by_index(i)
    if dev['maxInputChannels'] > 0:
        print(f"Index {i}: {dev['name']} (Host API: {dev['hostApi']})")
audio.terminate()