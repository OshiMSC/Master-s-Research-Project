"""
CycloneSOS — Priority Queue
============================
Ranks victims for rescue based on:
  - CNN confidence (50% weight) — how certain the detection is
  - Wait time      (30% weight) — how long since detection
  - Sound severity (20% weight) — how serious the sound type is

Higher score = higher priority = rescued first.
"""

import time


# Severity scores per sound type
SOUND_SEVERITY = {
    'Screaming':     1.0,
    'Manual SOS':    1.0,
    'Fearful speech': 0.85,
    'Glass breaking': 0.80,
    'Crying':        0.70,
    'Unknown':       0.60,
}

# Weights must sum to 1.0
W_CONFIDENCE = 0.50
W_WAIT_TIME  = 0.30
W_SEVERITY   = 0.20

# Max wait time for normalisation (30 minutes)
MAX_WAIT_SECONDS = 1800


class PriorityQueue:

    def calculate_score(self, alert: dict) -> float:
        """
        Calculate priority score for one alert.
        Returns value between 0.0 and 100.0
        Higher = more urgent
        """
        # Component 1: CNN confidence (already 0-1)
        conf_score = float(alert.get('confidence', 0))

        # Component 2: Wait time (normalised 0-1)
        received_at = alert.get('received_at', time.time())
        wait_secs   = time.time() - received_at
        wait_score  = min(wait_secs / MAX_WAIT_SECONDS, 1.0)

        # Component 3: Sound severity (0-1)
        sound_type    = alert.get('sound_type', 'Unknown')
        severity_score = SOUND_SEVERITY.get(sound_type, 0.60)

        # Weighted sum
        score = (
            conf_score   * W_CONFIDENCE +
            wait_score   * W_WAIT_TIME  +
            severity_score * W_SEVERITY
        ) * 100

        return round(score, 2)

    def sort_by_priority(self, alerts: list) -> list:
        """
        Sort alerts by priority score, highest first.
        Dispatched alerts go to the bottom.
        """
        # Recalculate scores (wait time changes every second)
        for alert in alerts:
            if alert.get('status') != 'dispatched':
                alert['priority_score'] = self.calculate_score(alert)

        # Split into active and dispatched
        active     = [a for a in alerts if a.get('status') != 'dispatched']
        dispatched = [a for a in alerts if a.get('status') == 'dispatched']

        # Sort active by score descending
        active.sort(key=lambda a: a.get('priority_score', 0), reverse=True)

        return active + dispatched
