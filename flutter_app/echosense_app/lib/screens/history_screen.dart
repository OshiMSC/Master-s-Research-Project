import 'package:flutter/material.dart';
import '../services/database_service.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<AlertRecord> _alerts = [];
  bool _loading = true;

  static const _black  = Color(0xFF000000);
  static const _bg2    = Color(0xFF0F0F0F);
  static const _red    = Color(0xFFFF3B30);
  static const _orange = Color(0xFFFF9500);
  static const _green  = Color(0xFF34C759);
  static const _blue   = Color(0xFF0A84FF);
  static const _border = Color(0xFF1A1A1A);
  static const _hint   = Color(0xFF555555);

  @override
  void initState() {
    super.initState();
    _loadAlerts();
  }

  Future<void> _loadAlerts() async {
    setState(() => _loading = true);
    final records = await DatabaseService.getAlerts();
    setState(() { _alerts = records; _loading = false; });
    print('HistoryScreen: Loaded ${_alerts.length} alerts from DB');
  }

  Color _colorFor(AlertRecord a) {
    if (a.confidence >= 0.85) return _red;
    if (a.confidence >= 0.65) return _orange;
    return _blue;
  }

  String _emoji(String type) {
    switch (type) {
      case 'Screaming':       return '😱';
      case 'Crying':          return '😢';
      case 'Glass breaking':  return '🪟';
      case 'Fearful speech':  return '😨';
      default:                return '🆘';
    }
  }

  String _timeAgo(String? ts) {
    if (ts == null) return 'Unknown';
    try {
      final dt   = DateTime.parse(ts);
      final diff = DateTime.now().difference(dt);
      if (diff.inSeconds < 60)  return '${diff.inSeconds}s ago';
      if (diff.inMinutes < 60)  return '${diff.inMinutes}m ago';
      if (diff.inHours < 24)    return '${diff.inHours}h ago';
      return '${diff.inDays}d ago';
    } catch (_) { return ts; }
  }

  @override
  Widget build(BuildContext context) {
    final total   = _alerts.length;
    final smsSent = _alerts.where((a) => a.smsSent).length;
    final dashSent = _alerts.where((a) => a.dashSent).length;

    return Scaffold(
      backgroundColor: _black,
      body: Stack(children: [
        Positioned.fill(child: CustomPaint(painter: _GridPainter())),
        SafeArea(child: Column(children: [
          // Header
          Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(children: [
              const Text('Alert History', style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
              const Spacer(),
              GestureDetector(
                onTap: _loadAlerts,
                child: const Icon(Icons.refresh, color: _hint, size: 18)),
            ])),
          const SizedBox(height: 12),

          // Summary cards
          if (total > 0)
            Padding(padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                _sumCard('$total',    'Total',    _red),
                const SizedBox(width: 7),
                _sumCard('$smsSent', 'SMS Sent', _green),
                const SizedBox(width: 7),
                _sumCard('$dashSent','Dashboard', _blue),
              ])),

          if (total > 0) const SizedBox(height: 12),

          // List
          Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator(color: _red))
            : _alerts.isEmpty
              ? _buildEmpty()
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: _alerts.length,
                  itemBuilder: (_, i) => _buildTimelineItem(_alerts[i], i == _alerts.length - 1))),
        ])),
      ]),
    );
  }

  Widget _sumCard(String val, String lbl, Color c) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: _bg2, borderRadius: BorderRadius.circular(13),
        border: Border.all(color: _border)),
      child: Column(children: [
        Text(val, style: TextStyle(
          fontSize: 20, fontWeight: FontWeight.w700, color: c)),
        const SizedBox(height: 2),
        Text(lbl, style: const TextStyle(fontSize: 9, color: _hint)),
      ])));

  Widget _buildTimelineItem(AlertRecord a, bool isLast) {
    final color = _colorFor(a);
    final conf  = (a.confidence * 100).round();
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 18, child: Column(children: [
          Container(width: 10, height: 10, margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(
              shape: BoxShape.circle, color: color,
              boxShadow: [BoxShadow(color: color.withOpacity(0.5), blurRadius: 6)])),
          if (!isLast) Expanded(child: Container(width: 1, color: _border,
            margin: const EdgeInsets.symmetric(vertical: 3))),
        ])),
        const SizedBox(width: 8),
        Expanded(child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _bg2, borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Type
              Text('${_emoji(a.soundType)}  ${a.soundType}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                  color: Color(0xFFDDDDDD))),
              const SizedBox(height: 3),
              // Time
              Text(_timeAgo(a.timestamp),
                style: const TextStyle(fontFamily: 'Courier New',
                  fontSize: 9, color: _hint)),
              // GPS if available
              if (a.latitude != null && a.longitude != null)
                Text('${a.latitude!.toStringAsFixed(4)}°N  '
                     '${a.longitude!.toStringAsFixed(4)}°E',
                  style: const TextStyle(fontFamily: 'Courier New',
                    fontSize: 9, color: _hint)),
              const SizedBox(height: 7),
              // Confidence bar
              Row(children: [
                Text('Confidence: $conf%', style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w600, color: color)),
                const SizedBox(width: 8),
                Expanded(child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: a.confidence, minHeight: 3,
                    backgroundColor: const Color(0xFF1A1A1A),
                    valueColor: AlwaysStoppedAnimation(color)))),
              ]),
              const SizedBox(height: 7),
              // Tags
              Wrap(spacing: 5, children: [
                if (a.smsSent)  _tag('✓ SMS',       _green),
                if (a.dashSent) _tag('✓ Dashboard', _blue),
                if (!a.smsSent) _tag('✗ SMS Failed', _red),
              ]),
            ]),
          ))),
      ]));
  }

  Widget _tag(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withOpacity(0.3))),
    child: Text(text, style: TextStyle(
      fontSize: 9, fontWeight: FontWeight.w600, color: color)));

  Widget _buildEmpty() => Center(
    child: Padding(padding: const EdgeInsets.all(40),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 60, height: 60,
          decoration: BoxDecoration(
            color: _blue.withOpacity(0.1), shape: BoxShape.circle,
            border: Border.all(color: _blue.withOpacity(0.3))),
          child: const Center(child: Icon(Icons.history, color: _blue, size: 26))),
        const SizedBox(height: 14),
        const Text('No alerts yet', style: TextStyle(
          fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white)),
        const SizedBox(height: 6),
        const Text('Alerts will appear here after the CNN detects distress or you press SOS',
          style: TextStyle(fontSize: 12, color: _hint, height: 1.5),
          textAlign: TextAlign.center),
      ])));
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0x06FFFFFF)..strokeWidth = 0.5;
    const s = 40.0;
    for(double x=0;x<=size.width;x+=s) canvas.drawLine(Offset(x,0),Offset(x,size.height),p);
    for(double y=0;y<=size.height;y+=s) canvas.drawLine(Offset(0,y),Offset(size.width,y),p);
  }
  @override bool shouldRepaint(_GridPainter o) => false;
}