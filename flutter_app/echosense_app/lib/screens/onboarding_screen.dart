import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'login_screen.dart';

abstract class ResQColors {
  static const black    = Color(0xFF000000);
  static const bg1      = Color(0xFF0A0A0A);
  static const bg2      = Color(0xFF0F0F0F);
  static const red      = Color(0xFFFF3B30);
  static const orange   = Color(0xFFFF9500);
  static const green    = Color(0xFF34C759);
  static const blue     = Color(0xFF0A84FF);
  static const textPrim = Color(0xFFFFFFFF);
  static const textHint = Color(0xFF555555);
  static const border   = Color(0xFF1A1A1A);
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {

  final _pageCtrl = PageController();
  int _cur = 0;

  late AnimationController _contentCtrl;
  late Animation<double>   _contentFade;
  late Animation<Offset>   _contentSlide;

  final _steps = const [
    _Step(
      icon: '🧠', color: ResQColors.red,
      titleLine1: 'AI Distress', titleLine2: 'Detection',
      desc: 'ResQNet uses a CNN trained on 5,972 audio clips to automatically detect screaming, crying, and collapse sounds — even in heavy cyclone noise.',
      badge: 'Step 1 of 3',
      features: [
        _Feature('🎤', ResQColors.red,    'Runs silently in background',       'Every 3 seconds · no action needed'),
        _Feature('⚡', ResQColors.blue,   'On-device AI — no internet needed', 'TFLite · 84.8% accuracy · AUC 0.900'),
      ],
    ),
    _Step(
      icon: '🔵', color: ResQColors.blue,
      titleLine1: 'Bluetooth', titleLine2: 'Mesh Network',
      desc: 'When SMS fails, your alert hops phone-to-phone via Bluetooth. Each nearby ResQNet device relays the message — up to 10 hops across the disaster zone.',
      badge: 'Step 2 of 3',
      features: [
        _Feature('📡', ResQColors.blue,  '100m range per hop',     'No towers · no internet · no hardware'),
        _Feature('💾', ResQColors.green, 'Store and forward',       'Saves alert · retries automatically'),
      ],
    ),
    _Step(
      icon: '🗺️', color: ResQColors.green,
      titleLine1: 'Rescue', titleLine2: 'Coordination',
      desc: 'Every alert is pushed in real-time to the rescue coordination dashboard. Coordinators see your GPS, confidence score, and dispatch teams by priority.',
      badge: 'Step 3 of 3',
      features: [
        _Feature('📍', ResQColors.green,  'GPS location in every alert', 'Google Maps link · live coordinates'),
        _Feature('🔊', ResQColors.orange, 'Acoustic chirp beacon',        '1–4 kHz · audible at 10m+ range'),
      ],
    ),
  ];

  @override
  void initState() {
    super.initState();
    _contentCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 400));
    _contentFade = CurvedAnimation(parent: _contentCtrl, curve: Curves.easeOut);
    _contentSlide = Tween<Offset>(
      begin: const Offset(0, 0.08), end: Offset.zero,
    ).animate(CurvedAnimation(parent: _contentCtrl, curve: Curves.easeOutCubic));
    _contentCtrl.forward();
  }

  void _animateContent() {
    _contentCtrl.reset();
    _contentCtrl.forward();
  }

  void _next() {
    HapticFeedback.lightImpact();
    if (_cur < _steps.length - 1) {
      _pageCtrl.nextPage(
        duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
    } else {
      _goToLogin();
    }
  }

  void _back() {
    if (_cur > 0) {
      HapticFeedback.lightImpact();
      _pageCtrl.previousPage(
        duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
    } else {
      _goToLogin();
    }
  }

  void _goToLogin() {
    Navigator.pushReplacementNamed(context, '/register'); 
}

  @override
  void dispose() {
    _pageCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final step = _steps[_cur];
    return Scaffold(
      backgroundColor: ResQColors.black,
      body: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _GridPainter())),
          // Radial glow
          Positioned(
            top: 60, left: 0, right: 0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              height: 200,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.topCenter, radius: 0.9,
                  colors: [step.color.withOpacity(0.10), Colors.transparent],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 8),
                // Progress dots
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  ...List.generate(_steps.length, (i) {
                    final isActive = i == _cur;
                    final isDone   = i < _cur;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: isActive ? 22 : 10, height: 3,
                      decoration: BoxDecoration(
                        color: isActive ? step.color
                             : isDone   ? const Color(0xFF333333)
                                        : const Color(0xFF1A1A1A),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    );
                  }),
                ]),
                const SizedBox(height: 8),
                // PageView
                Expanded(
                  child: PageView.builder(
                    controller: _pageCtrl,
                    onPageChanged: (i) {
                      setState(() => _cur = i);
                      _animateContent();
                    },
                    itemCount: _steps.length,
                    itemBuilder: (_, i) => _StepPage(
                      step: _steps[i],
                      fadeAnim: _contentFade,
                      slideAnim: _contentSlide,
                    ),
                  ),
                ),
                // Buttons
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                  child: Row(children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: _back,
                        child: Container(
                          height: 50,
                          decoration: BoxDecoration(
                            color: ResQColors.bg2,
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(color: ResQColors.border),
                          ),
                          child: Center(child: Text(
                            _cur > 0 ? '← Back' : 'Skip',
                            style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600,
                              color: Color(0xFF666666)),
                          )),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: GestureDetector(
                        onTap: _next,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          height: 50,
                          decoration: BoxDecoration(
                            color: step.color,
                            borderRadius: BorderRadius.circular(15),
                            boxShadow: [BoxShadow(
                              color: step.color.withOpacity(0.35),
                              blurRadius: 20, offset: const Offset(0, 4),
                            )],
                          ),
                          child: Center(child: Text(
                            _cur == _steps.length - 1 ? 'Get Started ✓' : 'Next →',
                            style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700,
                              color: Colors.white),
                          )),
                        ),
                      ),
                    ),
                  ]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StepPage extends StatelessWidget {
  final _Step step;
  final Animation<double> fadeAnim;
  final Animation<Offset>  slideAnim;
  const _StepPage({required this.step, required this.fadeAnim, required this.slideAnim});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Visual
          Center(
            child: SizedBox(
              width: 160, height: 160,
              child: Stack(alignment: Alignment.center, children: [
                // Outer rings
                Container(width: 150, height: 150, decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: step.color.withOpacity(0.12), width: 1),
                )),
                Container(width: 125, height: 125, decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: step.color.withOpacity(0.22), width: 1),
                )),
                Container(width: 100, height: 100, decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: step.color.withOpacity(0.35), width: 1),
                )),
                // Badge
                Positioned(top: 14, right: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: step.color,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(step.badge, style: const TextStyle(
                      fontSize: 8, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                ),
                // Icon
                Text(step.icon, style: const TextStyle(fontSize: 48)),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          // Content
          FadeTransition(
            opacity: fadeAnim,
            child: SlideTransition(
              position: slideAnim,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title
                  RichText(text: TextSpan(
                    style: const TextStyle(
                      fontSize: 26, fontWeight: FontWeight.w800,
                      color: ResQColors.textPrim, letterSpacing: -0.02, height: 1.15),
                    children: [
                      TextSpan(text: '${step.titleLine1}\n'),
                      TextSpan(text: step.titleLine2,
                        style: TextStyle(color: step.color)),
                    ],
                  )),
                  const SizedBox(height: 10),
                  // Description
                  Text(step.desc, style: const TextStyle(
                    fontSize: 12, color: Color(0xFF666666), height: 1.65)),
                  const SizedBox(height: 14),
                  // Features
                  ...step.features.map((f) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: ResQColors.bg2,
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(color: ResQColors.border),
                      ),
                      child: Row(children: [
                        Container(
                          width: 32, height: 32,
                          decoration: BoxDecoration(
                            color: f.color.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(color: f.color.withOpacity(0.3)),
                          ),
                          child: Center(child: Text(f.icon,
                            style: const TextStyle(fontSize: 14))),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(f.title, style: const TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w600,
                              color: Color(0xFFDDDDDD))),
                            const SizedBox(height: 2),
                            Text(f.subtitle, style: const TextStyle(
                              fontSize: 9, color: ResQColors.textHint)),
                          ],
                        )),
                      ]),
                    ),
                  )),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Step {
  final String icon, titleLine1, titleLine2, desc, badge;
  final Color  color;
  final List<_Feature> features;
  const _Step({
    required this.icon, required this.color,
    required this.titleLine1, required this.titleLine2,
    required this.desc, required this.badge,
    required this.features,
  });
}

class _Feature {
  final String icon, title, subtitle;
  final Color  color;
  const _Feature(this.icon, this.color, this.title, this.subtitle);
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0x06FFFFFF)..strokeWidth = 0.5;
    const s = 40.0;
    for (double x=0;x<=size.width; x+=s) canvas.drawLine(Offset(x,0),Offset(x,size.height),p);
    for (double y=0;y<=size.height;y+=s) canvas.drawLine(Offset(0,y),Offset(size.width,y),p);
  }
  @override bool shouldRepaint(_GridPainter o) => false;
}
