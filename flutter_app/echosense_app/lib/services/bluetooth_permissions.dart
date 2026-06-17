import 'dart:io';
import 'package:permission_handler/permission_handler.dart';

/// ResQNet — Bluetooth Permission Helper
/// ========================================
/// FIXES: BLE advertising (_doAdvertise -> startAdvertisingSet) failing
/// with PlatformException(18, UNDOCUMENTED, startAdvertisingSet, null)
/// on every single attempt, on every phone tested, regardless of brand.
///
/// ROOT CAUSE: on Android 12+ (API 31+), BLUETOOTH_ADVERTISE,
/// BLUETOOTH_SCAN, and BLUETOOTH_CONNECT are RUNTIME permissions.
/// Declaring them in AndroidManifest.xml (already done correctly in
/// this project) is necessary but NOT sufficient — the user must also
/// explicitly grant them via a system permission dialog, and nothing
/// in the app was ever triggering that dialog. flutter_ble_peripheral
/// and flutter_blue_plus do not reliably auto-prompt for these on
/// their own; the app must request them itself before calling into
/// native BLE start/scan/advertise APIs. Without the grant, every
/// native call that needs BLUETOOTH_ADVERTISE fails identically at
/// the Android framework permission-check layer — BEFORE it even
/// reaches the Bluetooth chipset/HAL — which is why this failed
/// identically on two completely different phone brands: the failure
/// has nothing to do with chipset/OEM Bluetooth stack differences,
/// it's the same OS-level permission gate on every device.
///
/// USAGE: call `await BluetoothPermissions.ensureGranted()` once,
/// BEFORE the first call to MeshService.startMesh() / startRelayMode()
/// / broadcastAlert() in any given app session. A good place is
/// HomeScreen.initState() alongside the existing AudioService.initialise()
/// call, and/or immediately before _startMeshBroadcast() as a safety net
/// in case the user denied it on first launch and granted it later via
/// system settings.
class BluetoothPermissions {
  /// Requests all three Android-12+ runtime Bluetooth permissions and
  /// returns true only if ALL of them end up granted. On iOS or
  /// Android < 12 this is a no-op that returns true immediately, since
  /// those platforms don't require these specific runtime grants the
  /// same way (legacy BLUETOOTH/BLUETOOTH_ADMIN in the manifest covers
  /// API <= 30, already present in AndroidManifest.xml).
  static Future<bool> ensureGranted() async {
    if (!Platform.isAndroid) return true;

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
    ].request();

    final allGranted = statuses.values.every((s) => s.isGranted);

    if (!allGranted) {
      print('BluetoothPermissions: NOT all granted — $statuses');
      print('BluetoothPermissions: this WILL cause BLE advertising to '
            'fail with PlatformException(18, ...) on Android 12+. '
            'The user needs to grant these via the system dialog, or '
            'manually in Settings > Apps > ResQNet > Permissions if '
            'previously denied (denial may be marked "permanently '
            'denied" after repeated refusals, which blocks the dialog '
            'from reappearing — openAppSettings() is required then).');
    } else {
      print('BluetoothPermissions: all granted ✓ — $statuses');
    }

    return allGranted;
  }

  /// Convenience check (no prompt) — useful for showing UI state
  /// without triggering the permission dialog itself.
  static Future<bool> isGranted() async {
    if (!Platform.isAndroid) return true;
    final scan = await Permission.bluetoothScan.status;
    final advertise = await Permission.bluetoothAdvertise.status;
    final connect = await Permission.bluetoothConnect.status;
    return scan.isGranted && advertise.isGranted && connect.isGranted;
  }

  /// If the user has permanently denied (selected "Don't ask again" or
  /// denied twice on some OEM skins), .request() will no longer show
  /// the dialog at all — the only way forward is the system Settings
  /// screen. Call this from a UI button ("Open Settings") if
  /// ensureGranted() keeps returning false after being called.
  static Future<void> openSettingsIfPermanentlyDenied() async {
    final advertiseStatus = await Permission.bluetoothAdvertise.status;
    if (advertiseStatus.isPermanentlyDenied) {
      await openAppSettings();
    }
  }
}
