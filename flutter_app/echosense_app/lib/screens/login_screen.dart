import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'onboarding_screen.dart';
import 'main_navigation.dart';

abstract class ResQColors {
  static const black    = Color(0xFF000000);
  static const bg1      = Color(0xFF0A0A0A);
  static const bg2      = Color(0xFF0F0F0F);
  static const bg3      = Color(0xFF161616);
  static const red      = Color(0xFFFF3B30);
  static const green    = Color(0xFF34C759);
  static const blue     = Color(0xFF0A84FF);
  static const textPrim = Color(0xFFFFFFFF);
  static const textSec  = Color(0xFFA0A0A0);
  static const textHint = Color(0xFF555555);
  static const border   = Color(0xFF1E1E1E);
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with TickerProviderStateMixin {

  final _phoneCtrl    = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _phoneFocus   = FocusNode();
  final _passFocus    = FocusNode();

  bool   _obscurePass  = true;
  bool   _isLoading    = false;
  bool   _loginSuccess = false;

  late final AnimationController _entranceCtrl;
  late final Animation<double>   _cardFade;
  late final Animation<Offset>   _cardSlide;
  late final Animation<double>   _greetFade;

  @override
  void initState() {
    super.initState();

    _entranceCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 800),
    )..forward();

    _greetFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _entranceCtrl,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOut)));

    _cardFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _entranceCtrl,
        curve: const Interval(0.3, 0.8, curve: Curves.easeOut)));

    _cardSlide = Tween<Offset>(
      begin: const Offset(0, 0.15), end: Offset.zero,
    ).animate(CurvedAnimation(parent: _entranceCtrl,
        curve: const Interval(0.3, 0.9, curve: Curves.easeOutCubic)));
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _passwordCtrl.dispose();
    _phoneFocus.dispose();
    _passFocus.dispose();
    _entranceCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (_phoneCtrl.text.isEmpty || _passwordCtrl.text.isEmpty) return;
    HapticFeedback.mediumImpact();
    setState(() => _isLoading = true);
    await Future.delayed(const Duration(milliseconds: 1200));
    setState(() { _isLoading = false; _loginSuccess = true; });
    await Future.delayed(const Duration(milliseconds: 800));
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/main');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ResQColors.black,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          // Grid background
          Positioned.fill(child: CustomPaint(painter: _GridPainter())),

          // Top radial glow
          Positioned(
            top: -60, left: 0, right: 0,
            child: Container(
              height: 260,
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.topCenter,
                  radius: 0.9,
                  colors: [Color(0x0DFF3B30), Colors.transparent],
                ),
              ),
            ),
          ),

          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 20),

                  // Greeting
                  FadeTransition(
                    opacity: _greetFade,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Welcome back',
                          style: TextStyle(
                            fontSize: 12, color: ResQColors.textHint,
                            letterSpacing: 0.05,
                          )),
                        const SizedBox(height: 4),
                        RichText(text: const TextSpan(
                          style: TextStyle(
                            fontSize: 30, fontWeight: FontWeight.w800,
                            color: ResQColors.textPrim, letterSpacing: -0.02,
                            height: 1.1,
                          ),
                          children: [
                            TextSpan(text: 'Ready to\nStay '),
                            TextSpan(text: 'Safe.',
                              style: TextStyle(color: ResQColors.red)),
                          ],
                        )),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Quote
                  FadeTransition(
                    opacity: _greetFade,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: ResQColors.bg1,
                        borderRadius: BorderRadius.circular(12),
                        border: Border(
                          left: BorderSide(
                            color: ResQColors.red.withOpacity(0.4), width: 2),
                        ),
                      ),
                      child: const Text(
                        '"Preparedness saves lives. Stay connected, stay safe."',
                        style: TextStyle(
                          fontSize: 11, color: Color(0xFF666666),
                          fontStyle: FontStyle.italic, height: 1.6,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Login card
                  FadeTransition(
                    opacity: _cardFade,
                    child: SlideTransition(
                      position: _cardSlide,
                      child: Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: ResQColors.bg2,
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: ResQColors.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Sign In',
                              style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w700,
                                color: ResQColors.textPrim,
                              )),
                            const SizedBox(height: 2),
                            const Text('Enter your credentials to continue',
                              style: TextStyle(fontSize: 11, color: ResQColors.textHint)),
                            const SizedBox(height: 16),

                            // Phone field
                            _buildInputField(
                              controller: _phoneCtrl,
                              focusNode:  _phoneFocus,
                              hint:       'Phone number',
                              icon:       Icons.phone_iphone_outlined,
                              keyboardType: TextInputType.phone,
                            ),
                            const SizedBox(height: 10),

                            // Password field
                            _buildPasswordField(),
                            const SizedBox(height: 6),

                            // Forgot password
                            Align(
                              alignment: Alignment.centerRight,
                              child: Text('Forgot password?',
                                style: const TextStyle(
                                  fontSize: 11, color: ResQColors.red)),
                            ),
                            const SizedBox(height: 14),

                            // Sign in button
                            _buildSignInButton(),
                            const SizedBox(height: 14),

                            // Divider
                            Row(children: [
                              Expanded(child: Divider(color: ResQColors.border)),
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 10),
                                child: Text('or continue with',
                                  style: TextStyle(fontSize: 10, color: ResQColors.textHint)),
                              ),
                              Expanded(child: Divider(color: ResQColors.border)),
                            ]),
                            const SizedBox(height: 12),

                            // Biometric button
                            _buildBiometricButton(),
                            const SizedBox(height: 14),

                            // Register
                            Center(child: RichText(text: const TextSpan(
                              style: TextStyle(fontSize: 11, color: ResQColors.textHint),
                              children: [
                                TextSpan(text: "Don't have an account? "),
                                TextSpan(text: 'Register',
                                  style: TextStyle(color: ResQColors.red, fontWeight: FontWeight.w600)),
                              ],
                            ))),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String hint,
    required IconData icon,
    TextInputType? keyboardType,
  }) {
    return AnimatedBuilder(
      animation: focusNode,
      builder: (_, __) {
        final focused = focusNode.hasFocus;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: ResQColors.bg3,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: focused ? ResQColors.red.withOpacity(0.5) : ResQColors.border,
              width: focused ? 1.5 : 1,
            ),
          ),
          child: Row(children: [
            Icon(icon, color: focused ? ResQColors.red : ResQColors.textHint, size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode:  focusNode,
                keyboardType: keyboardType,
                style: const TextStyle(
                  fontSize: 13, color: ResQColors.textPrim),
                decoration: InputDecoration(
                  hintText:  hint,
                  hintStyle: const TextStyle(fontSize: 13, color: ResQColors.textHint),
                  isDense:   true,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                ),
              ),
            ),
          ]),
        );
      },
    );
  }

  Widget _buildPasswordField() {
    return AnimatedBuilder(
      animation: _passFocus,
      builder: (_, __) {
        final focused = _passFocus.hasFocus;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: ResQColors.bg3,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: focused ? ResQColors.red.withOpacity(0.5) : ResQColors.border,
              width: focused ? 1.5 : 1,
            ),
          ),
          child: Row(children: [
            Icon(Icons.lock_outline, color: focused ? ResQColors.red : ResQColors.textHint, size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller:   _passwordCtrl,
                focusNode:    _passFocus,
                obscureText:  _obscurePass,
                style: const TextStyle(fontSize: 13, color: ResQColors.textPrim),
                decoration: InputDecoration(
                  hintText:  'Password',
                  hintStyle: const TextStyle(fontSize: 13, color: ResQColors.textHint),
                  isDense:   true,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                ),
              ),
            ),
            GestureDetector(
              onTap: () => setState(() => _obscurePass = !_obscurePass),
              child: Icon(
                _obscurePass ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                color: ResQColors.textHint, size: 16,
              ),
            ),
          ]),
        );
      },
    );
  }

  Widget _buildSignInButton() {
    return GestureDetector(
      onTap: _handleLogin,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 15),
        decoration: BoxDecoration(
          color: _loginSuccess ? ResQColors.green : ResQColors.red,
          borderRadius: BorderRadius.circular(15),
          boxShadow: [BoxShadow(
            color: (_loginSuccess ? ResQColors.green : ResQColors.red).withOpacity(0.35),
            blurRadius: 20, offset: const Offset(0, 4),
          )],
        ),
        child: Center(
          child: _isLoading
              ? const SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
              : Text(
                  _loginSuccess ? '✓ Welcome back' : 'Sign In',
                  style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700,
                    color: Colors.white),
                ),
        ),
      ),
    );
  }

  Widget _buildBiometricButton() {
    return GestureDetector(
      onTap: () => HapticFeedback.lightImpact(),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color: ResQColors.bg3,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: ResQColors.border),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Text('🫆', style: TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          const Text('Biometric Login',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
              color: ResQColors.textSec)),
        ]),
      ),
    );
  }
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
