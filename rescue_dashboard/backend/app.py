"""
ResQNet — Rescue Dashboard Backend
====================================
Fixed: debug=False so only ONE process runs
       This prevents microphone conflict between
       Flask reloader process and main process.

Run:
  python app.py
"""


from flask import Flask
from flask_socketio import SocketIO
from flask_cors import CORS
from routes import register_routes
from socket_events import register_socket_events
from chirp_detector import ChirpDetector
import os

app      = Flask(__name__)
CORS(app, resources={r"/*": {"origins": "*"}})
socketio = SocketIO(
    app,
    cors_allowed_origins="*",
    async_mode='threading',
    logger=False,
    engineio_logger=False
)

register_routes(app, socketio)
register_socket_events(socketio)

# ── Global chirp detector ──────────────────────────────────────
_chirp_detector = None

def start_chirp():
    global _chirp_detector
    if _chirp_detector and _chirp_detector._running:
        return

    def on_chirp(event):
        socketio.emit('chirp_detected', event)
        print(f"Chirp detected — emitting to dashboard")

    _chirp_detector = ChirpDetector(on_chirp_detected=on_chirp)
    success = _chirp_detector.start()
    if success:
        print("ChirpDetector: Auto-started successfully ✓")
    else:
        print("ChirpDetector: Could not start — check pyaudio")

    app.chirp_detector = _chirp_detector

# Start chirp detector immediately — no debug mode = no reloader
start_chirp()

if __name__ == '__main__':
    print("=" * 50)
    print("  ResQNet — Rescue Dashboard Backend")
    print("  Running on http://localhost:5000")
    print("=" * 50)
    socketio.run(
        app,
        host='0.0.0.0',
        port=5000,
        debug=False,              # ← KEY FIX: no reloader = no mic conflict
    )