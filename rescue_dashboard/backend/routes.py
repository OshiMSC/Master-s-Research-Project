"""
ResQNet — HTTP Routes
======================
Uses app.chirp_detector set in app.py
"""

from flask import request, jsonify, send_from_directory, current_app
from models import AlertStore
from priority_queue import PriorityQueue
import time
import os

alert_store = AlertStore()
pq          = PriorityQueue()


def register_routes(app, socketio):

    # ── Serve dashboard ────────────────────────────────────────
    @app.route('/')
    def serve_dashboard():
        backend_dir  = os.path.dirname(os.path.abspath(__file__))
        frontend_dir = os.path.abspath(
            os.path.join(backend_dir, '..', 'frontend'))
        return send_from_directory(frontend_dir, 'dashboard.html')

    # ── Receive SOS alert ──────────────────────────────────────
    @app.route('/alert', methods=['POST'])
    def receive_alert():
        try:
            data = request.get_json()
            if not data:
                return jsonify({'error': 'No data'}), 400

            alert = {
                'id':          str(int(time.time() * 1000)),
                'latitude':    data.get('latitude',   0.0),
                'longitude':   data.get('longitude',  0.0),
                'confidence':  data.get('confidence', 0.0),
                'sound_type':  data.get('sound_type', 'Unknown'),
                'battery':     data.get('battery',    0),
                'timestamp':   data.get('timestamp',  ''),
                'status':      'unresponded',
                'received_at': time.time(),
                'mesh_relay':  data.get('mesh_relay', False),
                'hop_count':   data.get('hop_count',  0),
                'origin_id':   data.get('origin_id',  ''),
            }
            alert['priority_score'] = pq.calculate_score(alert)
            alert_store.add(alert)
            socketio.emit('new_alert', alert)

            tag = '[MESH]' if alert['mesh_relay'] else '[DIRECT]'
            print(f"Alert received: {alert['sound_type']} "
                  f"({alert['confidence']*100:.0f}%) {tag}")

            return jsonify({'status': 'received', 'id': alert['id']}), 200

        except Exception as e:
            return jsonify({'error': str(e)}), 500

    # ── Get all alerts ─────────────────────────────────────────
    @app.route('/alerts', methods=['GET'])
    def get_alerts():
        alerts = alert_store.get_all()
        return jsonify(pq.sort_by_priority(alerts)), 200

    # ── Dispatch ───────────────────────────────────────────────
    @app.route('/dispatch/<alert_id>', methods=['POST'])
    def dispatch_team(alert_id):
        try:
            data  = request.get_json() or {}
            team  = data.get('team', 'Rescue Team')
            alert = alert_store.update_status(
                alert_id, 'dispatched', team)
            if alert:
                socketio.emit('alert_updated', alert)
                return jsonify({'status': 'dispatched', 'alert': alert}), 200
            return jsonify({'error': 'Not found'}), 404
        except Exception as e:
            return jsonify({'error': str(e)}), 500

    # ── Stats ──────────────────────────────────────────────────
    @app.route('/stats', methods=['GET'])
    def get_stats():
        alerts     = alert_store.get_all()
        total      = len(alerts)
        avg_conf   = (sum(a['confidence'] for a in alerts) / total
                      if total > 0 else 0)
        return jsonify({
            'total':          total,
            'unresponded':    len([a for a in alerts
                                   if a['status'] == 'unresponded']),
            'dispatched':     len([a for a in alerts
                                   if a['status'] == 'dispatched']),
            'mesh_relayed':   len([a for a in alerts
                                   if a.get('mesh_relay', False)]),
            'avg_confidence': round(avg_conf * 100, 1),
        }), 200

    # ── Test alert ─────────────────────────────────────────────
    @app.route('/test', methods=['POST'])
    def send_test_alert():
        import random
        sound_types = ['Screaming', 'Fearful speech',
                       'Glass breaking', 'Crying', 'Manual SOS']
        coords = [
            (-36.8866, 174.7470), (-36.8900, 174.7500),
            (-36.8840, 174.7440), (-36.8920, 174.7520),
        ]
        lat, lng = random.choice(coords)
        alert = {
            'id':          str(int(time.time() * 1000)),
            'latitude':    lat + random.uniform(-0.001, 0.001),
            'longitude':   lng + random.uniform(-0.001, 0.001),
            'confidence':  round(random.uniform(0.65, 0.97), 3),
            'sound_type':  random.choice(sound_types),
            'battery':     random.randint(20, 90),
            'timestamp':   time.strftime('%Y-%m-%d %H:%M:%S'),
            'status':      'unresponded',
            'received_at': time.time(),
            'mesh_relay':  False,
            'hop_count':   0,
        }
        alert['priority_score'] = pq.calculate_score(alert)
        alert_store.add(alert)
        socketio.emit('new_alert', alert)
        print(f"Test alert: {alert['sound_type']}")
        return jsonify({'status': 'test_sent', 'alert': alert}), 200

    # ── Clear ──────────────────────────────────────────────────
    @app.route('/clear', methods=['POST'])
    def clear_alerts():
        alert_store.clear()
        socketio.emit('alerts_cleared', {})
        return jsonify({'status': 'cleared'}), 200


    # ── Resolve alert ──────────────────────────────────────────
    @app.route('/resolve/<alert_id>', methods=['POST'])
    def resolve_alert(alert_id):
        try:
            alert = alert_store.update_status(alert_id, 'resolved')
            if alert:
                socketio.emit('alert_updated', alert)
                return jsonify({'status': 'resolved', 'alert': alert}), 200
            return jsonify({'error': 'Not found'}), 404
        except Exception as e:
            return jsonify({'error': str(e)}), 500

    # ── Case history ───────────────────────────────────────────
    @app.route('/history', methods=['GET'])
    def get_history():
        all_alerts  = alert_store.get_all()
        resolved    = [a for a in all_alerts if a.get('status') == 'resolved']
        dispatched  = [a for a in all_alerts if a.get('status') == 'dispatched']
        return jsonify({
            'resolved':   sorted(resolved,   key=lambda x: x.get('received_at', 0), reverse=True),
            'dispatched': sorted(dispatched, key=lambda x: x.get('received_at', 0), reverse=True),
            'total':      len(all_alerts),
        }), 200

    # ── Chirp routes ───────────────────────────────────────────
    def _get_detector():
        """Get chirp detector from app or create new one."""
        detector = getattr(current_app, 'chirp_detector', None)
        return detector

    @app.route('/chirp/start', methods=['POST'])
    def start_chirp():
        detector = _get_detector()
        if detector and detector._running:
            return jsonify({'status': 'already_running'}), 200

        from chirp_detector import ChirpDetector

        def on_chirp(event):
            socketio.emit('chirp_detected', event)

        new_detector = ChirpDetector(on_chirp_detected=on_chirp)
        success = new_detector.start()
        app.chirp_detector = new_detector

        if success:
            return jsonify({'status': 'started'}), 200
        return jsonify({
            'status': 'failed',
            'error':  'Cannot open microphone — install pyaudio'
        }), 500

    @app.route('/chirp/stop', methods=['POST'])
    def stop_chirp():
        detector = _get_detector()
        if detector:
            detector.stop()
            app.chirp_detector = None
        return jsonify({'status': 'stopped'}), 200

    @app.route('/chirp/status', methods=['GET'])
    def chirp_status():
        detector = _get_detector()
        if detector:
            return jsonify(detector.get_status()), 200
        return jsonify({
            'running':          False,
            'total_detections': 0,
            'history':          [],
        }), 200

    @app.route('/chirp/history', methods=['GET'])
    def chirp_history():
        detector = _get_detector()
        if detector:
            return jsonify({'history': detector.detection_history}), 200
        return jsonify({'history': []}), 200