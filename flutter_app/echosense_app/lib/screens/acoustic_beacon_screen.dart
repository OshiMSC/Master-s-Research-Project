import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/chirp_service.dart';

abstract class ResQColors {
  static const black = Color(0xFF000000);
  static const bg2 = Color(0xFF0F0F0F);
  static const red = Color(0xFFFF3B30);
  static const orange = Color(0xFFFF9500);
  static const green = Color(0xFF34C759);
  static const blue = Color(0xFF0A84FF);
  static const textPrim = Color(0xFFFFFFFF);
  static const textHint = Color(0xFF555555);
  static const border = Color(0xFF1A1A1A);
}

class AcousticBeaconScreen extends StatefulWidget {
  const AcousticBeaconScreen({super.key});
  @override
  State<AcousticBeaconScreen> createState() => _AcousticBeaconScreenState();
}

class _AcousticBeaconScreenState extends State<AcousticBeaconScreen>
    with TickerProviderStateMixin {
  bool _isPlaying = false;
  int _activeBand = 0; // 0=none 1=band1 2=band2 3=band3

  late AnimationController _sweepCtrl;
  late AnimationController _bandCtrl;

  static const _bands = [
    _Band(
      'Band 1 — Low',
      '1,000 — 2,000 Hz · 0.3s',
      ResQColors.blue,
      '1.5 kHz',
    ),
    _Band(
      'Band 2 — Mid',
      '2,000 — 3,000 Hz · 0.3s',
      ResQColors.orange,
      '2.5 kHz',
    ),
    _Band(
      'Band 3 — High',
      '3,000 — 4,000 Hz · 0.3s',
      ResQColors.red,
      '3.5 kHz',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _sweepCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _bandCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _bandCtrl.addStatusListener((s) {
      if (s == AnimationStatus.completed && _isPlaying) _nextBand();
    });
  }

  void _nextBand() {
    if (!mounted) return;
    setState(() => _activeBand = (_activeBand % 3) + 1);
    _bandCtrl.forward(from: 0);
  }

  void _toggleChirp() async {
    HapticFeedback.mediumImpact();
    setState(() => _isPlaying = !_isPlaying);

    if (_isPlaying) {
      // Start real chirp audio
      await ChirpService.startChirp();
      // Start visual animation
      _sweepCtrl.repeat();
      setState(() => _activeBand = 1);
      _bandCtrl.forward(from: 0);
    } else {
      // Stop real chirp audio
      await ChirpService.stopChirp();
      // Stop visual animation
      _sweepCtrl.stop();
      _bandCtrl.stop();
      setState(() => _activeBand = 0);
    }
  }

  @override
  void dispose() {
    _sweepCtrl.dispose();
    _bandCtrl.dispose();
    ChirpService.stopChirp(); // stop audio if screen closes
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curBand = _activeBand > 0 ? _bands[_activeBand - 1] : null;

    return Scaffold(
      backgroundColor: ResQColors.black,
      appBar: AppBar(
        backgroundColor: ResQColors.black,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, size: 18, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Acoustic Beacon',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _GridPainter())),
          SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Column(
              children: [
                const SizedBox(height: 2),
                Text(
                  'Multi-band chirp signal',
                  style: const TextStyle(
                    fontSize: 11,
                    color: ResQColors.textHint,
                  ),
                ),
                const SizedBox(height: 14),

                // Frequency display card
                _buildFreqCard(curBand),
                const SizedBox(height: 12),

                // Play / Stop button
                _buildPlayButton(),
                const SizedBox(height: 12),

                // Band cards
                ..._bands.asMap().entries.map((e) {
                  final i = e.key;
                  final band = e.value;
                  final isActive = _isPlaying && _activeBand == i + 1;
                  final isDone = _isPlaying && _activeBand > i + 1;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _buildBandCard(band, isActive, isDone),
                  );
                }),
                const SizedBox(height: 4),

                // Info row
                _buildInfoRow(),
                const SizedBox(height: 10),

                // Why card
                _buildWhyCard(),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFreqCard(_Band? curBand) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: ResQColors.bg2,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ResQColors.border),
      ),
      child: Column(
        children: [
          // Freq value
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 300),
            style: TextStyle(
              fontFamily: 'Courier New',
              fontSize: 36,
              fontWeight: FontWeight.w700,
              color: curBand?.color ?? ResQColors.textHint,
            ),
            child: Text(curBand?.freqDisplay ?? '— kHz'),
          ),
          const SizedBox(height: 4),
          const Text(
            'Current frequency',
            style: TextStyle(fontSize: 10, color: ResQColors.textHint),
          ),
          const SizedBox(height: 14),

          // Sweep bars
          AnimatedBuilder(
            animation: _sweepCtrl,
            builder: (_, __) {
              final heights = [
                0.3,
                0.5,
                0.7,
                0.9,
                1.0,
                0.95,
                0.85,
                0.7,
                0.55,
                0.4,
                0.6,
                0.8,
                0.95,
                1.0,
                0.9,
                0.75,
                0.55,
                0.35,
                0.2,
                0.1,
                0.3,
                0.55,
                0.75,
                0.95,
                1.0,
                0.9,
                0.7,
                0.5,
                0.3,
                0.15,
              ];
              final bandColours = [
                ...List.filled(10, ResQColors.blue),
                ...List.filled(10, ResQColors.orange),
                ...List.filled(10, ResQColors.red),
              ];
              return Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List.generate(30, (i) {
                  final phase = _sweepCtrl.value * 2 * math.pi;
                  final h = _isPlaying
                      ? heights[i] *
                            (0.35 + 0.65 * (math.sin(phase + i * 0.25)).abs())
                      : 0.05;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 80),
                        height: 48 * h + 2,
                        decoration: BoxDecoration(
                          color: _isPlaying
                              ? bandColours[i]
                              : ResQColors.border,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPlayButton() {
    return GestureDetector(
      onTap: _toggleChirp,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: _isPlaying ? const Color(0xFF3A3A3C) : ResQColors.orange,
          borderRadius: BorderRadius.circular(15),
          boxShadow: _isPlaying
              ? []
              : [
                  BoxShadow(
                    color: ResQColors.orange.withOpacity(0.35),
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                  ),
                ],
        ),
        child: Center(
          child: Text(
            _isPlaying ? '⏹  Stop Beacon' : '▶  Start Chirp Beacon',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBandCard(_Band band, bool isActive, bool isDone) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isActive ? band.color.withOpacity(0.08) : ResQColors.bg2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isActive
              ? band.color.withOpacity(0.4)
              : isDone
              ? band.color.withOpacity(0.2)
              : ResQColors.border,
        ),
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive
                  ? band.color
                  : isDone
                  ? band.color.withOpacity(0.5)
                  : const Color(0xFF1A1A1A),
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: band.color.withOpacity(0.6),
                        blurRadius: 8,
                      ),
                    ]
                  : [],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  band.name,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFFDDDDDD),
                  ),
                ),
                Text(
                  band.range,
                  style: const TextStyle(
                    fontSize: 9,
                    color: ResQColors.textHint,
                  ),
                ),
              ],
            ),
          ),
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 300),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: isActive
                  ? band.color
                  : isDone
                  ? ResQColors.green
                  : ResQColors.textHint,
            ),
            child: Text(
              isActive
                  ? '▶ Active'
                  : isDone
                  ? '✓ Done'
                  : '⏸ Pending',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow() {
    return Row(
      children: [
        Expanded(
          child: _infoCard(
            '🔋 Battery impact',
            '~3% / hr',
            'Active chirp mode',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _infoCard('📡 Audible range', '10m+', 'Indoor environment'),
        ),
      ],
    );
  }

  Widget _infoCard(String label, String value, String sub) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: ResQColors.bg2,
      borderRadius: BorderRadius.circular(13),
      border: Border.all(color: ResQColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 9, color: ResQColors.textHint),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Color(0xFFDDDDDD),
          ),
        ),
        Text(
          sub,
          style: const TextStyle(fontSize: 9, color: ResQColors.textHint),
        ),
      ],
    ),
  );

  Widget _buildWhyCard() => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: ResQColors.orange.withOpacity(0.06),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: ResQColors.orange.withOpacity(0.18)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('⚡', style: TextStyle(fontSize: 13)),
            const SizedBox(width: 7),
            const Text(
              'Why 1–4 kHz?',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF888888),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Cyclone noise concentrates below 800 Hz. The 2–4 kHz range aligns '
          'with peak human hearing sensitivity. Three sequential bands create a '
          'unique fingerprint rescue teams can identify.',
          style: TextStyle(fontSize: 11, color: Color(0xFF666666), height: 1.6),
        ),
      ],
    ),
  );
}

class _Band {
  final String name, range, freqDisplay;
  final Color color;
  const _Band(this.name, this.range, this.color, this.freqDisplay);
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0x06FFFFFF)
      ..strokeWidth = 0.5;
    const s = 40.0;
    for (double x = 0; x <= size.width; x += s)
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    for (double y = 0; y <= size.height; y += s)
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
  }

  @override
  bool shouldRepaint(_GridPainter o) => false;
}
