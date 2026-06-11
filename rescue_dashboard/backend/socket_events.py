"""
CycloneSOS — SocketIO Events
==============================
Real-time communication between backend and React dashboard.
"""

from flask_socketio import emit


def register_socket_events(socketio):

    @socketio.on('connect')
    def on_connect():
        print('Dashboard connected')
        emit('connected', {'status': 'Dashboard connected to CycloneSOS backend'})

    @socketio.on('disconnect')
    def on_disconnect():
        print('Dashboard disconnected')

    @socketio.on('ping')
    def on_ping():
        emit('pong', {'status': 'alive'})
