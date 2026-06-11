class AlertModel {
  final String id;
  final DateTime timestamp;
  final double latitude;
  final double longitude;
  final double confidence;
  final String soundType;
  final bool smsSent;
  final String status;

  AlertModel({
    required this.id,
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.confidence,
    required this.soundType,
    this.smsSent = false,
    this.status = 'unresponded',
  });

  // Convert to Map for SQLite storage
  Map<String, dynamic> toMap() {
    return {
      'id':         id,
      'timestamp':  timestamp.toIso8601String(),
      'latitude':   latitude,
      'longitude':  longitude,
      'confidence': confidence,
      'sound_type': soundType,
      'sms_sent':   smsSent ? 1 : 0,
      'status':     status,
    };
  }

  // Create from SQLite Map
  factory AlertModel.fromMap(Map<String, dynamic> map) {
    return AlertModel(
      id:         map['id'],
      timestamp:  DateTime.parse(map['timestamp']),
      latitude:   map['latitude'],
      longitude:  map['longitude'],
      confidence: map['confidence'],
      soundType:  map['sound_type'],
      smsSent:    map['sms_sent'] == 1,
      status:     map['status'],
    );
  }

  // Google Maps link for SMS
  String get mapsLink =>
      'https://maps.google.com/?q=$latitude,$longitude';

  // Confidence as percentage string
  String get confidencePercent =>
      '${(confidence * 100).toStringAsFixed(0)}%';

  // Time ago string
  String get timeAgo {
    final diff = DateTime.now().difference(timestamp);
    if (diff.inMinutes < 1)  return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours   < 24) return '${diff.inHours} hr ago';
    return '${diff.inDays} days ago';
  }
}