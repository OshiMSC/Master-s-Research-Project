import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/splash_screen.dart';
import 'screens/registration_screen.dart';
import 'screens/main_navigation.dart';
import 'screens/onboarding_screen.dart';
import 'screens/login_screen.dart';
import 'screens/active_emergency_screen.dart';
import 'screens/acoustic_beacon_screen.dart';
import 'screens/about_screen.dart';
import 'services/database_service.dart';
import 'services/audio_service.dart';
import 'services/background_audio_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor:           Colors.transparent,
    statusBarIconBrightness:  Brightness.light,
    systemNavigationBarColor: Color(0xFF000000),
  ));

  // Check if user is registered
  final isRegistered = await DatabaseService.isRegistered();
  print('Main: User registered = $isRegistered');

  // Register the background service's entry point. This is cheap and
  // has no side effects on its own (it does NOT start listening yet)
  // — it just tells flutter_background_service what to run if/when
  // start() is called below or later from home_screen.dart's
  // Disaster Mode toggle.
  await BackgroundAudioService.initialize();

  // Only actually START background monitoring if the user has
  // already registered — an unregistered user has no emergency
  // contacts saved yet, so there'd be nowhere for an alert to go.
  // Once registration completes, home_screen.dart's Disaster Mode
  // toggle (the same place that already starts the foreground
  // AudioService) is responsible for calling
  // BackgroundAudioService.start() for newly-registered users in
  // this same app session.
  if (isRegistered) {
    await BackgroundAudioService.start();
    print('Main: Background monitoring started for registered user');
  }

  runApp(ResQNetApp(isRegistered: isRegistered));
}

class ResQNetApp extends StatelessWidget {
  final bool isRegistered;
  const ResQNetApp({super.key, required this.isRegistered});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title:                      'ResQNet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3:            true,
        brightness:              Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF000000),
        colorScheme: const ColorScheme.dark(
          primary:   Color(0xFFFF3B30),
          secondary: Color(0xFF34C759),
          tertiary:  Color(0xFF0A84FF),
          surface:   Color(0xFF0F0F0F),
        ),
        fontFamily: 'SF Pro Display',
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS:     CupertinoPageTransitionsBuilder(),
          },
        ),
      ),

      // ── Smart initial route ───────────────────────────────────
      // If registered → go straight to main (no login needed)
      // If not        → go to onboarding → registration
      initialRoute: isRegistered ? '/main' : '/onboarding',

      routes: {
        '/onboarding':    (_) => const OnboardingScreen(),
        '/register':      (_) => const RegistrationScreen(),
        '/login':         (_) => const LoginScreen(),
        '/main':          (_) => const MainNavigation(),
        '/beacon':        (_) => const AcousticBeaconScreen(),
        '/about':         (_) => const AboutScreen(),
        
      },

      onGenerateRoute: (settings) {
        if (settings.name == '/emergency') {
          final args = settings.arguments as Map<String, dynamic>?;
          return MaterialPageRoute(
            builder: (_) => ActiveEmergencyScreen(
              soundType:  args?['soundType']  ?? 'Screaming',
              confidence: args?['confidence'] ?? 0.94,
              latitude:   args?['latitude']   ?? 0.0,
              longitude:  args?['longitude']  ?? 0.0,
            ),
          );
        }
        return null;
      },
    );
  }
}