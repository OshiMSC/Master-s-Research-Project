import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/sms_service.dart';
import '../services/database_service.dart';

abstract class ResQColors {
  static const black   = Color(0xFF000000);
  static const bg2     = Color(0xFF0F0F0F);
  static const red     = Color(0xFFFF3B30);
  static const orange  = Color(0xFFFF9500);
  static const green   = Color(0xFF34C759);
  static const blue    = Color(0xFF0A84FF);
  static const textPrim= Color(0xFFFFFFFF);
  static const textHint= Color(0xFF555555);
  static const border  = Color(0xFF1E1E1E);
}

class ActiveEmergencyScreen extends StatefulWidget {
  final String soundType;
  final double confidence;
  final double latitude;
  final double longitude;
  final bool   alreadySent; // true = SMS already sent, skip duplicate
  const ActiveEmergencyScreen({
    super.key,
    this.soundType   = 'Screaming',
    this.confidence  = 0.94,
    this.latitude    = -36.8866,
    this.longitude   = 174.7469,
    this.alreadySent = false,
  });
  @override
  State<ActiveEmergencyScreen> createState() => _ActiveEmergencyScreenState();
}

class _ActiveEmergencyScreenState extends State<ActiveEmergencyScreen>
    with TickerProviderStateMixin {

  late AnimationController _flashCtrl;
  late AnimationController _pulseCtrl;
  late AnimationController _confCtrl;
  late Animation<double>   _flashAnim;
  late Animation<double>   _confAnim;

  int    _txStep      = 0;
  List<ContactModel> _contacts = [];
  List<bool>          _contactsSent = [];

  @override
  void initState() {
    super.initState();
    HapticFeedback.heavyImpact();

    _flashCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1000))..repeat(reverse: true);
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);
    _confCtrl  = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200));

    _flashAnim = Tween<double>(begin: 0.05, end: 0.16).animate(
        CurvedAnimation(parent: _flashCtrl, curve: Curves.easeInOut));
    _confAnim  = Tween<double>(begin: 0.0, end: widget.confidence).animate(
        CurvedAnimation(parent: _confCtrl,  curve: Curves.easeOutCubic));

    _confCtrl.forward();
    _simulateTransmission();
  }

  void _simulateTransmission() async {
    // Load real contacts from database
    final contacts = await DatabaseService.getContacts();
    if (mounted) {
      setState(() {
        _contacts      = contacts;
        _contactsSent  = List.filled(contacts.length, false);
      });
    }

    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    setState(() => _txStep = 1);

    // Skip SMS if already sent upstream (avoid duplicates)
    bool smsSent = widget.alreadySent;
    if (!widget.alreadySent) {
      smsSent = await SmsService.sendSosAlert(
        latitude:   widget.latitude,
        longitude:  widget.longitude,
        confidence: widget.confidence,
        soundType:  widget.soundType,
      );
    } else {
      print('ActiveEmergencyScreen: SMS already sent — skipping duplicate');
    }
    if (!mounted) return;
    setState(() {
      _txStep       = 2;
      _contactsSent = List.filled(_contacts.length, smsSent);
    });

    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    setState(() => _txStep = 3);

    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    setState(() => _txStep = 4);

    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    setState(() => _txStep = 6);
  }

  @override
  void dispose() {
    _flashCtrl.dispose();
    _pulseCtrl.dispose();
    _confCtrl.dispose();
    super.dispose();
  }

  String get _soundEmoji {
    switch (widget.soundType.toLowerCase()) {
      case 'screaming':      return '😱';
      case 'crying':         return '😢';
      case 'glass breaking': return '🪟';
      case 'fearful speech': return '😨';
      default:               return '🆘';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ResQColors.black,
      body: AnimatedBuilder(
        animation: _flashAnim,
        builder: (_, child) => Stack(children: [
          Positioned.fill(child: CustomPaint(painter: _GridPainter())),
          // Red radial flash
          Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0, -0.3), radius: 1.2,
              colors: [ResQColors.red.withOpacity(_flashAnim.value), Colors.transparent],
            ),
          ))),
          child!,
        ]),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 14),
                _buildBadge(),
                const SizedBox(height: 14),
                _buildTitle(),
                const SizedBox(height: 14),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(children: [
                      _buildDetectionCard(),
                      const SizedBox(height: 10),
                      _buildGpsCard(),
                      const SizedBox(height: 10),
                      _buildTransmissionCard(),
                      const SizedBox(height: 10),
                      _buildContactsCard(),
                      const SizedBox(height: 16),
                      _buildCancelButton(),
                      const SizedBox(height: 8),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBadge() {
    return AnimatedBuilder(
      animation: _pulseCtrl,
      builder: (_, __) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: ResQColors.red,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(
            color: ResQColors.red.withOpacity(0.3 + _pulseCtrl.value * 0.35),
            blurRadius: 20,
          )],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 6, height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(0.5 + _pulseCtrl.value * 0.5),
            ),
          ),
          const SizedBox(width: 7),
          const Text('ALERT ACTIVE', style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w700,
            color: Colors.white, letterSpacing: 0.1)),
        ]),
      ),
    );
  }

  Widget _buildTitle() => RichText(
    text: const TextSpan(
      style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800,
          color: ResQColors.textPrim, letterSpacing: -0.02, height: 1.15),
      children: [
        TextSpan(text: 'Distress\n'),
        TextSpan(text: 'Detected', style: TextStyle(color: ResQColors.red)),
      ],
    ),
  );

  Widget _buildDetectionCard() => _emCard(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _cardLabel('DETECTION TYPE', ResQColors.red),
      Text('$_soundEmoji  ${widget.soundType} — ${(widget.confidence*100).round()}% confidence',
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ResQColors.textPrim)),
      const SizedBox(height: 8),
      AnimatedBuilder(animation: _confAnim, builder: (_, __) => ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: _confAnim.value,
          backgroundColor: const Color(0xFF1A1A1A),
          valueColor: const AlwaysStoppedAnimation(ResQColors.red),
          minHeight: 4,
        ),
      )),
    ]),
  );

  Widget _buildGpsCard() => _emCard(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _cardLabel('GPS COORDINATES', ResQColors.red),
      const Text('📍  Location captured',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ResQColors.textPrim)),
      const SizedBox(height: 4),
      Text('${widget.latitude.toStringAsFixed(4)}°N  ${widget.longitude.toStringAsFixed(4)}°E',
        style: const TextStyle(fontFamily: 'Courier New',
            fontSize: 11, color: ResQColors.textHint)),
    ]),
  );

  Widget _buildTransmissionCard() => _emCard(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _cardLabel('TRANSMISSION STATUS', ResQColors.red),
      const Text('SMS → BLE Mesh → Dashboard',
        style: TextStyle(fontSize: 10, color: ResQColors.textHint)),
      const SizedBox(height: 8),
      Row(children: List.generate(6, (i) => Expanded(
        child: Padding(
          padding: EdgeInsets.only(right: i < 5 ? 4 : 0),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            height: 4,
            decoration: BoxDecoration(
              color: i < _txStep
                  ? ResQColors.green
                  : i == _txStep ? ResQColors.orange : const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ))),
    ]),
  );

  Widget _buildContactsCard() {
    final colors = [ResQColors.red, ResQColors.green, ResQColors.blue,
                    ResQColors.orange, ResQColors.textPrim];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ResQColors.green.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ResQColors.green.withOpacity(0.2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _cardLabel('CONTACTS NOTIFIED', ResQColors.green),
        if (_contacts.isEmpty)
          const Text('No contacts saved — add in settings',
            style: TextStyle(fontSize: 11, color: ResQColors.textHint))
        else
          ..._contacts.asMap().entries.map((e) {
            final i       = e.key;
            final contact = e.value;
            final initial = contact.name.isNotEmpty
                ? contact.name[0].toUpperCase() : '?';
            final color   = colors[i % colors.length];
            final sent    = i < _contactsSent.length ? _contactsSent[i] : false;
            return Column(children: [
              if (i > 0) const Divider(color: Color(0xFF1A1A1A), height: 10),
              _contactRow(initial, contact.name, color, sent),
            ]);
          }),
      ]),
    );
  }

  Widget _contactRow(String initial, String name, Color color, bool sent) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Container(
          width: 28, height: 28,
          decoration: BoxDecoration(
            color: color.withOpacity(0.18),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(child: Text(initial, style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w700, color: color))),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(name, style: const TextStyle(
          fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFFCCCCCC)))),
        AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: sent ? ResQColors.green.withOpacity(0.15) : ResQColors.orange.withOpacity(0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            sent ? '✓ SMS' : '⏳ Sending',
            style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600,
              color: sent ? ResQColors.green : ResQColors.orange),
          ),
        ),
      ]),
    );
  }

  Widget _buildCancelButton() => GestureDetector(
    onTap: () => Navigator.of(context).pop(),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 15),
      decoration: BoxDecoration(
        color: ResQColors.bg2,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: ResQColors.border),
      ),
      child: const Center(child: Text('Cancel Alert', style: TextStyle(
        fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF666666)))),
    ),
  );

  Widget _emCard({required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: ResQColors.red.withOpacity(0.07),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: ResQColors.red.withOpacity(0.22)),
    ),
    child: child,
  );

  Widget _cardLabel(String text, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: TextStyle(
      fontSize: 9, fontWeight: FontWeight.w600,
      color: color.withOpacity(0.7), letterSpacing: 0.1)),
  );
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0x06FFFFFF)..strokeWidth = 0.5;
    const s = 40.0;
    for(double x=0;x<=size.width; x+=s) canvas.drawLine(Offset(x,0),Offset(x,size.height),p);
    for(double y=0;y<=size.height;y+=s) canvas.drawLine(Offset(0,y),Offset(size.width,y),p);
  }
  @override bool shouldRepaint(_GridPainter o) => false;
}