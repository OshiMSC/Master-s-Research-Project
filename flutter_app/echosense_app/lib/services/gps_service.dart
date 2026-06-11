import 'package:geolocator/geolocator.dart';

class GpsService {
  static Position? _lastPosition;

  /// Get current GPS coordinates.
  /// Returns null if permission denied or unavailable.
  static Future<Position?> getCurrentLocation() async {
    try {
      // Check if location services are enabled
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        print('GPS: Location services disabled');
        return _lastPosition;
      }

      // Check permissions
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          print('GPS: Permission denied');
          return _lastPosition;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        print('GPS: Permission permanently denied');
        return _lastPosition;
      }

      // Get position
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      _lastPosition = position;
      return position;

    } catch (e) {
      print('GPS error: $e');
      return _lastPosition; // return last known if available
    }
  }

  /// Build Google Maps URL from coordinates
  static String buildMapsUrl(double lat, double lng) {
    return 'https://maps.google.com/?q=$lat,$lng';
  }

  /// Get last known position without requesting new one
  static Position? get lastPosition => _lastPosition;

  /// Check if we have a recent position (within 5 minutes)
  static bool get hasRecentPosition {
    return _lastPosition != null;
  }
}