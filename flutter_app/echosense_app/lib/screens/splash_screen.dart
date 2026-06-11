import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'onboarding_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const ResQNetApp());
}

class ResQNetApp extends StatelessWidget {
  const ResQNetApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ResQNet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: ResQColors.black,
      ),
      home: const SplashScreen(),
    );
  }
}

abstract class ResQColors {
  static const black    = Color(0xFF000000);
  static const bg1      = Color(0xFF0A0A0A);
  static const bg2      = Color(0xFF111111);
  static const red      = Color(0xFFFF3B30);
  static const redGlow  = Color(0x40FF3B30);
  static const redFaint = Color(0x14FF3B30);
  static const orange   = Color(0xFFFF9500);
  static const green    = Color(0xFF34C759);
  static const blue     = Color(0xFF0A84FF);
  static const textPrim = Color(0xFFFFFFFF);
  static const textSec  = Color(0xFFA0A0A0);
  static const textHint = Color(0xFF555555);
  static const border   = Color(0x14FFFFFF);
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {

  late final AnimationController _glowController;
  late final AnimationController _ringController;
  late final AnimationController _entranceController;
  late final AnimationController _loadController;
  late final AnimationController _scanController;

  late final Animation<double> _logoFade;
  late final Animation<Offset> _logoSlide;
  late final Animation<double> _taglineFade;
  late final Animation<double> _barFade;
  late final Animation<double> _statusFade;
  late final Animation<double> _glowScale;
  late final Animation<double> _glowOpacity;
  late final Animation<double> _loadProgress;
  late final Animation<double> _scanPosition;

  @override
  void initState() {
    super.initState();

    // Glow pulse
    _glowController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
    _glowScale   = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut));
    _glowOpacity = Tween<double>(begin: 0.5,  end: 1.0).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut));

    // Expanding rings
    _ringController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2200),
    )..repeat();

    // Entrance sequence
    _entranceController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1600),
    );
    _logoFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _entranceController,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOut)));
    _logoSlide = Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero).animate(
      CurvedAnimation(parent: _entranceController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOutCubic)));
    _taglineFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _entranceController,
        curve: const Interval(0.35, 0.75, curve: Curves.easeOut)));
    _barFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _entranceController,
        curve: const Interval(0.55, 0.85, curve: Curves.easeOut)));
    _statusFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _entranceController,
        curve: const Interval(0.7, 1.0, curve: Curves.easeOut)));

    // Load bar
    _loadController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2800),
    );
    _loadProgress = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _loadController, curve: Curves.easeInOutCubic));

    // Scan line
    _scanController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1800),
    )..repeat();
    _scanPosition = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _scanController, curve: Curves.easeInOut));

    // Start
    _entranceController.forward();
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _loadController.forward();
    });

    // Navigate
    Future.delayed(const Duration(milliseconds: 3600), () {
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/onboarding');
      }
    });
  }

  @override
  void dispose() {
    _glowController.dispose();
    _ringController.dispose();
    _entranceController.dispose();
    _loadController.dispose();
    _scanController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ResQColors.black,
      body: Stack(
        children: [
          // Radial background gradient
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.center,
                  radius: 0.85,
                  colors: [Color(0x1AFF3B30), Color(0x00000000)],
                ),
              ),
            ),
          ),

          // Grid lines
          Positioned.fill(child: CustomPaint(painter: _GridPainter())),

          // Scan line
          AnimatedBuilder(
            animation: _scanPosition,
            builder: (_, __) {
              final h = MediaQuery.of(context).size.height;
              return Positioned(
                top: _scanPosition.value * h,
                left: 0, right: 0,
                child: Container(
                  height: 1,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [
                      Colors.transparent,
                      ResQColors.red.withOpacity(0.15),
                      ResQColors.red.withOpacity(0.3),
                      ResQColors.red.withOpacity(0.15),
                      Colors.transparent,
                    ]),
                  ),
                ),
              );
            },
          ),

          // Main content
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Logo area
                SizedBox(
                  width: 220, height: 220,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Ambient glow
                      AnimatedBuilder(
                        animation: _glowController,
                        builder: (_, __) => Transform.scale(
                          scale: _glowScale.value,
                          child: Container(
                            width: 200, height: 200,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [BoxShadow(
                                color: ResQColors.red.withOpacity(0.18 * _glowOpacity.value),
                                blurRadius: 80, spreadRadius: 20,
                              )],
                            ),
                          ),
                        ),
                      ),

                      // Expanding rings
                      _ExpandingRing(controller: _ringController, maxRadius: 90,  delay: 0.0, color: ResQColors.red, opacity: 0.4),
                      _ExpandingRing(controller: _ringController, maxRadius: 100, delay: 0.4, color: ResQColors.red, opacity: 0.2),

                      // Static ring
                      Container(
                        width: 112, height: 112,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: ResQColors.red.withOpacity(0.35), width: 1),
                        ),
                      ),

                      // Logo circle — ResQNet "R"
                      Container(
                        width: 88, height: 88,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: ResQColors.red.withOpacity(0.12),
                          border: Border.all(color: ResQColors.red.withOpacity(0.6), width: 1.5),
                          boxShadow: [BoxShadow(
                            color: ResQColors.red.withOpacity(0.25),
                            blurRadius: 24, spreadRadius: 2,
                          )],
                        ),
                        child: const Center(
                          child: Text('R',
                            style: TextStyle(
                              fontSize: 44, fontWeight: FontWeight.w700,
                              color: ResQColors.red, height: 1,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 28),

                // App name — ResQNet
                FadeTransition(
                  opacity: _logoFade,
                  child: SlideTransition(
                    position: _logoSlide,
                    child: RichText(
                      text: const TextSpan(children: [
                        TextSpan(text: 'ResQ',
                          style: TextStyle(
                            fontSize: 34, fontWeight: FontWeight.w700,
                            color: ResQColors.textPrim, letterSpacing: 1.5,
                          )),
                        TextSpan(text: 'Net',
                          style: TextStyle(
                            fontSize: 34, fontWeight: FontWeight.w700,
                            color: ResQColors.red, letterSpacing: 1.5,
                          )),
                      ]),
                    ),
                  ),
                ),

                const SizedBox(height: 8),

                // Tagline
                FadeTransition(
                  opacity: _taglineFade,
                  child: const Text(
                    'AI-POWERED EMERGENCY RESPONSE',
                    style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w500,
                      color: ResQColors.textHint, letterSpacing: 2.8,
                    ),
                  ),
                ),

                const SizedBox(height: 52),

                // Progress bar
                FadeTransition(
                  opacity: _barFade,
                  child: Column(
                    children: [
                      AnimatedBuilder(
                        animation: _loadProgress,
                        builder: (_, __) => SizedBox(
                          width: 120, height: 2,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(1),
                            child: Stack(children: [
                              Container(color: ResQColors.bg2),
                              FractionallySizedBox(
                                widthFactor: _loadProgress.value,
                                child: Container(
                                  decoration: const BoxDecoration(
                                    gradient: LinearGradient(colors: [
                                      ResQColors.red, Color(0xFFFF6158),
                                    ]),
                                  ),
                                ),
                              ),
                            ]),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      FadeTransition(
                        opacity: _statusFade,
                        child: AnimatedBuilder(
                          animation: _loadProgress,
                          builder: (_, __) {
                            final p = _loadProgress.value;
                            final label = p < 0.3 ? 'Initializing systems...'
                                        : p < 0.6 ? 'Loading CNN model...'
                                        : p < 0.85? 'Establishing mesh...'
                                        : 'Ready';
                            return Text(label,
                              style: const TextStyle(
                                fontSize: 11, color: ResQColors.textHint, letterSpacing: 0.8,
                              ));
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Version
          Positioned(
            bottom: 36, left: 0, right: 0,
            child: FadeTransition(
              opacity: _barFade,
              child: const Text('v1.0.0 · ResQNet',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, color: ResQColors.textHint, letterSpacing: 1.2)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExpandingRing extends StatelessWidget {
  const _ExpandingRing({
    required this.controller, required this.maxRadius,
    required this.delay, required this.color, required this.opacity,
  });
  final AnimationController controller;
  final double maxRadius, delay, opacity;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        double t = (controller.value - delay) % 1.0;
        if (t < 0) t += 1.0;
        final radius = maxRadius * t * 2;
        final alpha  = (opacity * (1.0 - t)).clamp(0.0, 1.0);
        return Container(
          width: radius, height: radius,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color.withOpacity(alpha), width: 1),
          ),
        );
      },
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0x08FFFFFF)..strokeWidth = 0.5;
    const spacing = 40.0;
    for (double x = 0; x <= size.width;  x += spacing)
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    for (double y = 0; y <= size.height; y += spacing)
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
  }
  @override
  bool shouldRepaint(_GridPainter old) => false;
}
