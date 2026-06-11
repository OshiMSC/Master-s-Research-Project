import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/sms_service.dart';

abstract class ResQColors {
  static const black   = Color(0xFF000000);
  static const bg2     = Color(0xFF0F0F0F);
  static const bg3     = Color(0xFF161616);
  static const red     = Color(0xFFFF3B30);
  static const orange  = Color(0xFFFF9500);
  static const green   = Color(0xFF34C759);
  static const blue    = Color(0xFF0A84FF);
  static const textPrim= Color(0xFFFFFFFF);
  static const textHint= Color(0xFF555555);
  static const border  = Color(0xFF1A1A1A);
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  double _sensitivity  = 0.20;
  bool   _bgMonitor    = true;
  bool   _batterySaver = true;
  bool   _autoSms      = true;
  bool   _bleRelay     = true;
  bool   _chirpEnabled = false;
  bool   _dashPush     = true;

  // ── IP field ──────────────────────────────────────────────
  final _ipCtrl   = TextEditingController();
  bool  _ipSaved  = false;
  bool  _ipLoading = true;

  @override
  void initState() {
    super.initState();
    _loadIp();
  }

  Future<void> _loadIp() async {
    final saved = await SmsService.getDashboardIp();
    if (mounted) {
      setState(() {
        _ipCtrl.text = saved;
        _ipLoading   = false;
      });
    }
  }

  Future<void> _saveIp() async {
    final ip = _ipCtrl.text.trim();
    if (ip.isEmpty) {
      _showSnack('Please enter the dashboard IP address');
      return;
    }
    await SmsService.saveDashboardIp(ip);
    HapticFeedback.mediumImpact();
    setState(() => _ipSaved = true);
    _showSnack('Dashboard IP saved — $ip');
    Future.delayed(const Duration(seconds: 2),
        () { if (mounted) setState(() => _ipSaved = false); });
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg,
        style: const TextStyle(fontFamily: 'Courier New', fontSize: 12)),
      backgroundColor: ResQColors.bg2,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ResQColors.black,
      body: Stack(children: [
        Positioned.fill(child: CustomPaint(painter: _GridPainter())),
        SafeArea(child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 14),
              const Text('Settings', style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700,
                color: ResQColors.textPrim)),
              const SizedBox(height: 14),

              _buildSensCard(),
              const SizedBox(height: 8),

              _buildGroup('DETECTION', [
                _Row(Icons.mic_none_outlined, ResQColors.red,
                  'Background Monitoring', 'Runs CNN every 3 seconds',
                  _bgMonitor, (v) => setState(() => _bgMonitor = v)),
                _Row(Icons.battery_charging_full_outlined, ResQColors.blue,
                  'Battery Saver VAD', 'Skip CNN during silence',
                  _batterySaver, (v) => setState(() => _batterySaver = v)),
              ]),
              const SizedBox(height: 8),

              _buildGroup('COMMUNICATION', [
                _Row(Icons.sms_outlined, ResQColors.green,
                  'Automatic SMS', 'Send on detection',
                  _autoSms, (v) => setState(() => _autoSms = v)),
                _Row(Icons.bluetooth_outlined, ResQColors.blue,
                  'Bluetooth Mesh', 'Relay to nearby devices',
                  _bleRelay, (v) => setState(() => _bleRelay = v)),
                _Row(Icons.volume_up_outlined, ResQColors.orange,
                  'Acoustic Chirp', 'Enable chirp beacon',
                  _chirpEnabled, (v) => setState(() => _chirpEnabled = v)),
                _Row(Icons.dashboard_outlined, ResQColors.red,
                  'Dashboard Push', 'Send to rescue dashboard',
                  _dashPush, (v) => setState(() => _dashPush = v)),
              ]),
              const SizedBox(height: 8),

              // ── Dashboard IP card — now fully functional ──
              _buildIpCard(),
              const SizedBox(height: 8),

              _buildAboutRow(),
              const SizedBox(height: 10),

              const Center(child: Text(
                'ResQNet v1.0.0 · Build 20260718',
                style: TextStyle(
                  fontFamily: 'Courier New', fontSize: 9,
                  color: Color(0xFF333333)))),
              const SizedBox(height: 24),
            ],
          ),
        )),
      ]),
    );
  }

  // ── Sensitivity slider ────────────────────────────────────
  Widget _buildSensCard() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: ResQColors.bg2,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: ResQColors.border)),
    child: Column(children: [
      Row(children: [
        Container(
          width: 30, height: 30,
          decoration: BoxDecoration(
            color: ResQColors.blue.withOpacity(0.12),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: ResQColors.blue.withOpacity(0.25))),
          child: const Center(child: Icon(
            Icons.tune, color: ResQColors.blue, size: 15))),
        const SizedBox(width: 10),
        const Expanded(child: Text('AI Detection Sensitivity',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
            color: Color(0xFFDDDDDD)))),
        Text(_sensitivity.toStringAsFixed(2),
          style: const TextStyle(
            fontFamily: 'Courier New', fontSize: 13,
            fontWeight: FontWeight.w700, color: ResQColors.blue)),
      ]),
      const SizedBox(height: 12),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor:   ResQColors.blue,
          inactiveTrackColor: ResQColors.border,
          thumbColor:         ResQColors.blue,
          overlayColor:       ResQColors.blue.withOpacity(0.15),
          thumbShape:  const RoundSliderThumbShape(enabledThumbRadius: 8),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
          trackHeight: 4,
        ),
        child: Slider(
          value: _sensitivity, min: 0.10, max: 0.50, divisions: 8,
          onChanged: (v) {
            HapticFeedback.selectionClick();
            setState(() => _sensitivity = v);
          }),
      ),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('Conservative', style: TextStyle(fontSize: 9, color: ResQColors.textHint)),
        Text('Balanced',     style: TextStyle(fontSize: 9, color: ResQColors.textHint)),
        Text('Sensitive',    style: TextStyle(fontSize: 9, color: ResQColors.textHint)),
      ]),
    ]),
  );

  // ── Toggle group ──────────────────────────────────────────
  Widget _buildGroup(String label, List<_Row> rows) => Container(
    decoration: BoxDecoration(
      color: ResQColors.bg2,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: ResQColors.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
        child: Text(label, style: const TextStyle(
          fontSize: 9, fontWeight: FontWeight.w600,
          color: ResQColors.textHint, letterSpacing: 0.08))),
      ...rows.asMap().entries.map((e) => Column(children: [
        if (e.key > 0) const Divider(color: Color(0xFF141414), height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(children: [
            Container(
              width: 30, height: 30,
              decoration: BoxDecoration(
                color: e.value.color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: e.value.color.withOpacity(0.25))),
              child: Icon(e.value.icon, color: e.value.color, size: 15)),
            const SizedBox(width: 10),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.value.title, style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w500,
                color: Color(0xFFDDDDDD))),
              Text(e.value.desc, style: const TextStyle(
                fontSize: 9, color: ResQColors.textHint)),
            ])),
            _buildSwitch(e.value.value, e.value.onChanged),
          ])),
      ])),
    ]),
  );

  Widget _buildSwitch(bool value, ValueChanged<bool> onChanged) =>
    GestureDetector(
      onTap: () { HapticFeedback.lightImpact(); onChanged(!value); },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        width: 38, height: 21,
        decoration: BoxDecoration(
          color: value ? ResQColors.green : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(11)),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 280),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 17, height: 17,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: const BoxDecoration(
              shape: BoxShape.circle, color: Colors.white,
              boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 3)])),
        ),
      ),
    );

  // ── Dashboard IP — editable + save button ─────────────────
  Widget _buildIpCard() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: ResQColors.bg2,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: _ipSaved ? ResQColors.green : ResQColors.border)),
    child: Column(children: [
      Row(children: [
        Container(
          width: 30, height: 30,
          decoration: BoxDecoration(
            color: ResQColors.green.withOpacity(0.12),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: ResQColors.green.withOpacity(0.25))),
          child: const Icon(Icons.computer_outlined,
            color: ResQColors.green, size: 15)),
        const SizedBox(width: 10),
        const Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Dashboard IP Address', style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w500,
            color: Color(0xFFDDDDDD))),
          Text('Rescue coordination server',
            style: TextStyle(fontSize: 9, color: ResQColors.textHint)),
        ])),
        // Green tick when saved
        AnimatedOpacity(
          opacity: _ipSaved ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 300),
          child: const Icon(Icons.check_circle_outline,
            color: ResQColors.green, size: 16)),
      ]),
      const SizedBox(height: 10),

      // ── Editable IP field ────────────────────────────
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: ResQColors.bg3,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF222222))),
        child: Row(children: [
          const Icon(Icons.router_outlined,
            color: ResQColors.textHint, size: 14),
          const SizedBox(width: 8),
          Expanded(child: TextField(
            controller:  _ipCtrl,
            keyboardType: TextInputType.number,
            style: const TextStyle(
              fontFamily: 'Courier New', fontSize: 12,
              color: Colors.white),
            decoration: const InputDecoration(
              hintText:        '192.168.x.x',
              hintStyle:       TextStyle(
                fontFamily: 'Courier New', fontSize: 12,
                color: ResQColors.textHint),
              border:          InputBorder.none,
              isDense:         true,
              contentPadding: EdgeInsets.symmetric(vertical: 8)),
            onSubmitted: (_) => _saveIp(),
          )),
          // Save button
          GestureDetector(
            onTap: _saveIp,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _ipSaved
                    ? ResQColors.green.withOpacity(0.15)
                    : ResQColors.blue.withOpacity(0.15),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color: _ipSaved ? ResQColors.green : ResQColors.blue)),
              child: Text(
                _ipSaved ? 'Saved' : 'Save',
                style: TextStyle(
                  fontFamily: 'Courier New', fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _ipSaved ? ResQColors.green : ResQColors.blue)),
            ),
          ),
        ]),
      ),

      const SizedBox(height: 8),

      // Hint text
      Row(children: [
        const Icon(Icons.info_outline,
          color: ResQColors.textHint, size: 11),
        const SizedBox(width: 5),
        Expanded(child: Text(
          'Enter laptop IP only — no port, no http://  '
          'e.g. 192.168.10.106',
          style: const TextStyle(
            fontFamily: 'Courier New', fontSize: 9,
            color: ResQColors.textHint))),
      ]),
    ]),
  );

  // ── About row ─────────────────────────────────────────────
  Widget _buildAboutRow() => GestureDetector(
    onTap: () => Navigator.pushNamed(context, '/about'),
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ResQColors.bg2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ResQColors.border)),
      child: Row(children: [
        Container(
          width: 30, height: 30,
          decoration: BoxDecoration(
            color: ResQColors.red.withOpacity(0.12),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: ResQColors.red.withOpacity(0.25))),
          child: const Icon(Icons.info_outline,
            color: ResQColors.red, size: 15)),
        const SizedBox(width: 10),
        const Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('About & Help', style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w500,
            color: Color(0xFFDDDDDD))),
          Text('How ResQNet works · Setup guide',
            style: TextStyle(fontSize: 9, color: ResQColors.textHint)),
        ])),
        const Icon(Icons.chevron_right,
          color: ResQColors.textHint, size: 18),
      ]),
    ),
  );
}

class _Row {
  final IconData icon;
  final Color color;
  final String title, desc;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _Row(this.icon, this.color, this.title,
             this.desc, this.value, this.onChanged);
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0x06FFFFFF)
      ..strokeWidth = 0.5;
    const s = 40.0;
    for (double x = 0; x <= size.width;  x += s)
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    for (double y = 0; y <= size.height; y += s)
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
  }
  @override bool shouldRepaint(_GridPainter o) => false;
}