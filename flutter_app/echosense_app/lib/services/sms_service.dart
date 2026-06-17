import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:battery_plus/battery_plus.dart';
import 'dart:convert';
import 'database_service.dart';

/// ResQNet — SMS Alert Service
///
/// Communication channels:
///   1. Native SMS via Android SmsManager (silent — no app opens)
///   2. Telegram Bot API (fully automatic)
///   3. HTTP POST to rescue dashboard
///   4. Save to local SQLite alert history
class SmsService {

  // ── MethodChannel — must match MainActivity.kt ────────────────
  static const _channel = MethodChannel('com.resqnet.sms/send');

  // ── Telegram credentials ──────────────────────────────────────
  static const String _telegramBotToken =
      '8835166426:AAGgI_j20eSBK0Tv2koxTF17f29-1iN4MUs';
  static const String _telegramChatId = '8418739667';

  // ── Battery service ───────────────────────────────────────────
  static final Battery _battery = Battery();

  // ── Duplicate alert guard ─────────────────────────────────────
  static bool _alertInProgress = false;

  // ── Send SOS alert ────────────────────────────────────────────
  static Future<bool> sendSosAlert({
    required double latitude,
    required double longitude,
    required double confidence,
    required String soundType,
  }) async {
    if (_alertInProgress) {
      print('SmsService: Alert already in progress — skipping duplicate');
      return false;
    }
    _alertInProgress = true;

    try {
      // Get real battery level
      int batteryLevel = 0;
      try {
        batteryLevel = await _battery.batteryLevel;
      } catch (e) {
        print('SmsService: Battery read failed — $e');
      }

      final contacts = await DatabaseService.getContacts();
      final mapsLink =
          'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude';
      final confPct = (confidence * 100).toStringAsFixed(0);
      final time    = _formatTime(DateTime.now());

      final message =
          'ResQNet EMERGENCY ALERT\n\n'
          'Distress detected: $soundType ($confPct% confidence)\n'
          'Location: $mapsLink\n'
          'Time: $time\n'
          'Battery: $batteryLevel%\n\n'
          'Sent automatically by ResQNet.\n'
          'Please contact emergency services immediately.';

      bool smsSent = false;

      if (contacts.isEmpty) {
        print('SmsService: No contacts — using fallback number');
        smsSent = await _sendNativeSms(
          message:    message,
          recipients: ['+64225012439'],
        );
      } else {
        final phones = contacts.map((c) => c.phone).toList();
        print('SmsService: Sending native SMS to ${phones.length} contacts');
        smsSent = await _sendNativeSms(
          message:    message,
          recipients: phones,
        );
      }

      // Channel 2 — Telegram (automatic)
      await _sendTelegram(
        latitude:   latitude,
        longitude:  longitude,
        confidence: confidence,
        soundType:  soundType,
        time:       time,
        mapsLink:   mapsLink,
        confPct:    confPct,
      );

      // Channel 3 — Dashboard HTTP POST
      await _sendToDashboard(
        latitude:   latitude,
        longitude:  longitude,
        confidence: confidence,
        soundType:  soundType,
        battery:    batteryLevel,
      );

      // Channel 4 — Save to SQLite history
      await DatabaseService.saveAlert(AlertRecord(
        soundType:  soundType,
        confidence: confidence,
        latitude:   latitude,
        longitude:  longitude,
        smsSent:    smsSent,
        dashSent:   true,
      ));

      return smsSent;

    } finally {
      _alertInProgress = false;
    }
  }

  // ── Native SMS via Android SmsManager ────────────────────────
  // Sends silently — no Messages app opens
  static Future<bool> _sendNativeSms({
    required String       message,
    required List<String> recipients,
  }) async {
    try {
      final result = await _channel.invokeMethod<String>('sendSms', {
        'message':    message,
        'recipients': recipients,
      });
      print('SmsService: Native SMS result = $result');
      return true;
    } on PlatformException catch (e) {
      print('SmsService: Native SMS failed — ${e.code}: ${e.message}');
      if (e.code == 'PERMISSION_DENIED') {
        await _channel.invokeMethod('requestPermission');
        print('SmsService: SMS permission requested — will work next alert');
      }
      return false;
    } catch (e) {
      print('SmsService: SMS error — $e');
      return false;
    }
  }

  // ── Check SMS permission ──────────────────────────────────────
  static Future<bool> checkSmsPermission() async {
    try {
      final granted =
          await _channel.invokeMethod<bool>('checkPermission');
      return granted ?? false;
    } catch (e) {
      return false;
    }
  }

  // ── Request SMS permission ────────────────────────────────────
  static Future<void> requestSmsPermission() async {
    try {
      await _channel.invokeMethod('requestPermission');
    } catch (e) {
      print('SmsService: Permission request failed — $e');
    }
  }

  // ── Manual SOS button ─────────────────────────────────────────
  static Future<bool> sendManualSos({
    required double latitude,
    required double longitude,
  }) async {
    return sendSosAlert(
      latitude:   latitude,
      longitude:  longitude,
      confidence: 1.0,
      soundType:  'Manual SOS (button pressed)',
    );
  }

  // ── Telegram Bot (fully automatic) ───────────────────────────
  static Future<void> _sendTelegram({
    required double latitude,
    required double longitude,
    required double confidence,
    required String soundType,
    required String time,
    required String mapsLink,
    required String confPct,
  }) async {
    try {
      final text =
          '*ResQNet EMERGENCY ALERT*\n\n'
          '*$soundType* ($confPct% confidence)\n'
          '[View Location on Maps]($mapsLink)\n'
          '$time\n\n'
          '_Sent automatically by ResQNet._\n'
          '_Please contact emergency services immediately._';

      final uri = Uri.parse(
          'https://api.telegram.org/bot$_telegramBotToken/sendMessage');

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'chat_id':    _telegramChatId,
          'text':       text,
          'parse_mode': 'Markdown',
        }),
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          print('SmsService: Telegram timeout');
          return http.Response('timeout', 408);
        },
      );

      if (response.statusCode == 200) {
        print('SmsService: Telegram alert sent ✓');
      } else {
        print('SmsService: Telegram failed — ${response.statusCode}');
      }
    } catch (e) {
      print('SmsService: Telegram error — $e');
    }
  }

  // ── HTTP POST to dashboard ────────────────────────────────────
  static Future<void> _sendToDashboard({
    required double latitude,
    required double longitude,
    required double confidence,
    required String soundType,
    required int    battery,
  }) async {
    try {
      final prefs   = await SharedPreferences.getInstance();
      final rawIp   = prefs.getString('dashboard_ip') ?? '';
      final cleanIp = _sanitizeIp(rawIp);

      if (cleanIp.isEmpty) {
        print('SmsService: No dashboard IP — skipping');
        return;
      }

      print('SmsService: Posting to dashboard $cleanIp');

      final uri = Uri.parse('http://$cleanIp:5000/alert');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'latitude':   latitude,
          'longitude':  longitude,
          'confidence': confidence,
          'sound_type': soundType,
          'battery':    battery,
          'timestamp':  _formatTime(DateTime.now()),
        }),
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          print('SmsService: Dashboard timeout');
          return http.Response('timeout', 408);
        },
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        print('SmsService: Dashboard received alert ✓');
      } else {
        print('SmsService: Dashboard returned ${response.statusCode}');
      }
    } catch (e) {
      print('SmsService: Dashboard post failed — $e');
    }
  }

  // ── Dashboard IP helpers ──────────────────────────────────────
  //
  // BUG HISTORY (keep this sanitizer — do not simplify it away):
  // a stray ":port" once ended up saved into 'dashboard_ip' (e.g.
  // "192.168.10.202:48702"). Every call site that builds a dashboard
  // URL appends ":5000" onto the stored value, so the resulting URL
  // became "http://192.168.10.202:48702:5000/alert" — a malformed
  // authority. Uri.parse resolved the FIRST ":NNNN" group as the
  // actual port, silently routing every request to port 48702
  // instead of 5000 ("No route to host" — there was nothing
  // listening there). The printed log line still showed ":5000"
  // because that's just string interpolation of the URL we
  // *intended* to build, not what Uri.parse actually resolved.
  //
  // Fix: 'dashboard_ip' must never contain a port, scheme, or path —
  // only a bare host/IP — enforced both when it is written AND when
  // it is read, since mesh_service.dart reads it via getDashboardIp()
  // directly and shouldn't have to trust this file's stored data.
  static String _sanitizeIp(String raw) {
    var ip = raw.trim().replaceAll('%20', '').replaceAll(' ', '');
    if (ip.isEmpty) return '';
    // Someone may paste a full URL ("http://host:5000/alert") into a
    // settings field — strip the scheme first.
    if (ip.contains('://')) {
      ip = ip.split('://').last;
    }
    // Strip any path suffix (everything after the first '/').
    ip = ip.split('/').first;
    // Strip a trailing ':port' — this is what fixes the 48702 bug.
    // A bare IPv4 host never contains ':', so anything after the
    // first colon here is port data that doesn't belong in storage.
    if (ip.contains(':')) {
      ip = ip.split(':').first;
    }
    return ip;
  }

  static Future<void> saveDashboardIp(String ip) async {
    final prefs = await SharedPreferences.getInstance();
    final clean = _sanitizeIp(ip);
    await prefs.setString('dashboard_ip', clean);
    print('SmsService: Dashboard IP saved as "$clean"');
  }

  static Future<String> getDashboardIp() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString('dashboard_ip') ?? '';
    // Defense in depth: sanitize on read too, in case bad data is
    // still sitting in prefs from before this fix existed (e.g. on
    // a phone that already has the corrupted value saved).
    return _sanitizeIp(raw);
  }

  // ── Time formatter ────────────────────────────────────────────
  static String _formatTime(DateTime dt) =>
      '${dt.year}-${_p(dt.month)}-${_p(dt.day)} '
      '${_p(dt.hour)}:${_p(dt.minute)}:${_p(dt.second)}';

  static String _p(int n) => n.toString().padLeft(2, '0');
}