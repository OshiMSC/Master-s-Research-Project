"""
ResQNet — Data Models
======================
Alert storage with JSON file persistence.
Alerts survive browser refresh and Flask restart.
"""

import json
import os
import time
from threading import Lock

ALERTS_FILE = 'alerts_data.json'


class AlertStore:
    """Thread-safe alert storage with file persistence."""

    def __init__(self):
        self._alerts = []
        self._lock   = Lock()
        self._load_from_file()

    # ── File persistence ──────────────────────────────────────
    def _load_from_file(self):
        """Load alerts from JSON file on startup."""
        try:
            if os.path.exists(ALERTS_FILE):
                with open(ALERTS_FILE, 'r') as f:
                    self._alerts = json.load(f)
                print(f'AlertStore: Loaded {len(self._alerts)} '
                      f'alerts from {ALERTS_FILE}')
            else:
                self._alerts = []
                print('AlertStore: No existing alerts file — starting fresh')
        except Exception as e:
            print(f'AlertStore: Could not load file — {e}')
            self._alerts = []

    def _save_to_file(self):
        """Save alerts to JSON file after every change."""
        try:
            with open(ALERTS_FILE, 'w') as f:
                json.dump(self._alerts, f, indent=2)
        except Exception as e:
            print(f'AlertStore: Could not save file — {e}')

    # ── CRUD ──────────────────────────────────────────────────
    def add(self, alert: dict) -> dict:
        with self._lock:
            self._alerts.append(alert)
            self._save_to_file()
        return alert

    def get_all(self) -> list:
        with self._lock:
            return list(self._alerts)

    def get_by_id(self, alert_id: str) -> dict | None:
        with self._lock:
            for a in self._alerts:
                if a['id'] == alert_id:
                    return a
        return None

    def update_status(self, alert_id: str,
                      status: str, team: str = '') -> dict | None:
        with self._lock:
            for a in self._alerts:
                if a['id'] == alert_id:
                    a['status']        = status
                    a['dispatched_at'] = time.time()
                    a['team']          = team
                    self._save_to_file()
                    return a
        return None

    def clear(self):
        with self._lock:
            self._alerts.clear()
            self._save_to_file()

    @property
    def count(self) -> int:
        return len(self._alerts)