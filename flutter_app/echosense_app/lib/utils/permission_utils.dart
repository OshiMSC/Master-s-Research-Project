import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionUtils {

  /// Request all permissions needed by CycloneSOS
  static Future<bool> requestAllPermissions(BuildContext context) async {
    final permissions = [
      Permission.microphone,
      Permission.location,
      Permission.sms,
      Permission.phone,
    ];

    // Request all at once
    final statuses = await permissions.request();

    final micOk      = statuses[Permission.microphone] == PermissionStatus.granted;
    final locationOk = statuses[Permission.location]   == PermissionStatus.granted;

    if (!micOk) {
      _showPermissionDialog(
        context,
        title:   'Microphone required',
        message: 'CycloneSOS needs microphone access to detect distress sounds. '
                 'Please grant permission in Settings.',
      );
      return false;
    }

    if (!locationOk) {
      _showPermissionDialog(
        context,
        title:   'Location required',
        message: 'CycloneSOS needs location access to include your GPS '
                 'coordinates in emergency alerts.',
      );
      return false;
    }

    print('PermissionUtils: All critical permissions granted');
    return true;
  }

  /// Check if mic permission is granted
  static Future<bool> hasMicPermission() async {
    return await Permission.microphone.isGranted;
  }

  /// Check if location permission is granted
  static Future<bool> hasLocationPermission() async {
    return await Permission.location.isGranted;
  }

  static void _showPermissionDialog(
    BuildContext context, {
    required String title,
    required String message,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Text(title,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(message,
            style: const TextStyle(color: Colors.white60, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Later',
                style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE24B4A)),
            onPressed: () {
              Navigator.pop(ctx);
              openAppSettings();
            },
            child: const Text('Open Settings',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}