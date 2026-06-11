"""
CycloneSOS — Test Alert Sender
================================
Run this to send fake alerts to your dashboard
without needing the Flutter app.

Usage:
  python test_send_alert.py          ← sends one alert
  python test_send_alert.py 5        ← sends 5 alerts
"""

import requests
import sys
import time

BASE_URL = 'http://localhost:5000'


def send_test_alert():
    """Send one test alert via the /test endpoint."""
    try:
        response = requests.post(f'{BASE_URL}/test')
        if response.status_code == 200:
            alert = response.json().get('alert', {})
            print(f"✓ Alert sent: {alert.get('sound_type')} "
                  f"({alert.get('confidence', 0)*100:.0f}%) "
                  f"at {alert.get('latitude', 0):.4f},"
                  f"{alert.get('longitude', 0):.4f}")
        else:
            print(f"✗ Failed: {response.status_code}")
    except Exception as e:
        print(f"✗ Error — is Flask running? {e}")


def send_real_alert(lat, lng, confidence, sound_type):
    """Send a real-format alert (same as Flutter app sends)."""
    try:
        data = {
            'latitude':   lat,
            'longitude':  lng,
            'confidence': confidence,
            'sound_type': sound_type,
            'battery':    75,
            'timestamp':  time.strftime('%Y-%m-%d %H:%M:%S'),
        }
        response = requests.post(f'{BASE_URL}/alert', json=data)
        if response.status_code == 200:
            print(f"✓ Real alert sent: {sound_type} ({confidence*100:.0f}%)")
        else:
            print(f"✗ Failed: {response.status_code}")
    except Exception as e:
        print(f"✗ Error: {e}")


if __name__ == '__main__':
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    print(f"Sending {count} test alert(s) to {BASE_URL}...")

    for i in range(count):
        send_test_alert()
        if count > 1:
            time.sleep(2)

    print("\nCheck your dashboard — alerts should appear on the map!")
