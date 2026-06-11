import 'package:flutter/material.dart';

abstract class ResQColors {
  static const black   = Color(0xFF000000);
  static const bg2     = Color(0xFF0F0F0F);
  static const red     = Color(0xFFFF3B30);
  static const orange  = Color(0xFFFF9500);
  static const green   = Color(0xFF34C759);
  static const blue    = Color(0xFF0A84FF);
  static const textPrim= Color(0xFFFFFFFF);
  static const textHint= Color(0xFF555555);
  static const border  = Color(0xFF1A1A1A);
}

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});
  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  int _openFaq = -1;

  final _faqs = const [
    _Faq('Does the app work without internet?',
        'Yes. All AI detection runs on-device. Alerts use SMS (no internet) or Bluetooth mesh (no towers). Fully offline capable in total blackout conditions.'),
    _Faq('What sounds does it detect?',
        'Screaming, fearful speech, crying, glass breaking, and structural collapse. Trained on 5,972 labelled clips from ESC-50, RAVDESS, UrbanSound8K and Kaggle.'),
    _Faq('How accurate is the detection?',
        '84.8% overall accuracy, 96.5% precision, AUC 0.900. Threshold 0.20 maximises F1-score to 0.811. Tested live on Samsung Galaxy M10.'),
    _Faq('Why does it need microphone permission?',
        'The CNN needs continuous microphone access to analyse audio every 3 seconds during disaster mode. This is the core detection mechanism.'),
    _Faq('What if all phones are dead?',
        'The acoustic chirp beacon (1–4 kHz multi-band) plays from the phone speaker as a last-resort signal for rescue teams at 10m+ range.'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ResQColors.black,
      body: Stack(children: [
        Positioned.fill(child: CustomPaint(painter: _GridPainter())),
        SafeArea(child: Column(children: [
          // Header
          Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(color: ResQColors.bg2,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: ResQColors.border)),
                  child: const Icon(Icons.arrow_back_ios,
                    color: Colors.white, size: 14)),
              ),
              const SizedBox(width: 12),
              const Text('About & Help', style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w700,
                color: ResQColors.textPrim)),
            ])),
          const SizedBox(height: 12),
          Expanded(child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Column(children: [
              _buildHeroCard(),
              const SizedBox(height: 9),
              _buildHowItWorks(),
              const SizedBox(height: 9),
              _buildFaqSection(),
              const SizedBox(height: 9),
              _buildSetupGuide(),
              const SizedBox(height: 9),
              _buildResearchCard(),
              const SizedBox(height: 10),
              const Text('ResQNet v1.0.0 · Build 20260718 · MSE907 Capstone',
                style: TextStyle(fontFamily: 'Courier New',
                  fontSize: 9, color: Color(0xFF333333))),
              const SizedBox(height: 24),
            ]),
          )),
        ])),
      ]),
    );
  }

  Widget _buildHeroCard() => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: [ResQColors.red.withOpacity(0.09), ResQColors.blue.withOpacity(0.04)],
        begin: Alignment.topLeft, end: Alignment.bottomRight),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: ResQColors.red.withOpacity(0.18))),
    child: Column(children: [
      Container(width: 54, height: 54,
        decoration: BoxDecoration(
          color: ResQColors.red.withOpacity(0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: ResQColors.red.withOpacity(0.3)),
          boxShadow: [BoxShadow(color: ResQColors.red.withOpacity(0.18), blurRadius: 20)]),
        child: const Center(child: Text('🌀', style: TextStyle(fontSize: 24)))),
      const SizedBox(height: 10),
      const Text('ResQNet', style: TextStyle(
        fontSize: 17, fontWeight: FontWeight.w800,
        color: ResQColors.textPrim, letterSpacing: -0.02)),
      const SizedBox(height: 6),
      const Text(
        'AI-powered distress detection and emergency alerting for telecommunication-denied disaster environments.',
        style: TextStyle(fontSize: 10, color: Color(0xFF666666), height: 1.6),
        textAlign: TextAlign.center),
      const SizedBox(height: 10),
      Wrap(spacing: 6, children: const [
        _HeroTag('84.8% Accuracy', ResQColors.green),
        _HeroTag('AUC 0.900',      ResQColors.blue),
        _HeroTag('Zero Cost',      ResQColors.orange),
      ]),
    ]),
  );

  Widget _buildHowItWorks() {
    final steps = [
      _Step('1', 'Microphone listens every 3 seconds',
          'Continuous background recording — no action needed. Software VAD skips CNN during silence to save ~80% battery.',
          ResQColors.red),
      _Step('2', 'CNN classifies distress sounds',
          'Audio converted to 128×128 Mel-Spectrogram. TFLite CNN classifies on-device. Threshold 0.20 gives precision 96.5%.',
          ResQColors.orange),
      _Step('3', 'Alert sent automatically',
          'GPS captured. SMS fires to all contacts. BLE mesh broadcasts to nearby devices. Dashboard notified in real-time.',
          ResQColors.blue),
      _Step('4', 'Rescue teams dispatched',
          'Dashboard shows GPS pin, confidence, sound type. Priority queue ranks victims. Team dispatched to highest priority first.',
          ResQColors.green),
    ];
    return _buildSection('HOW IT WORKS', Column(
      children: steps.asMap().entries.map((e) => Column(children: [
        if (e.key > 0) const Divider(color: Color(0xFF141414), height: 1),
        Padding(padding: const EdgeInsets.all(12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(width: 24, height: 24,
              decoration: BoxDecoration(
                color: e.value.color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8)),
              child: Center(child: Text(e.value.num, style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w700,
                color: e.value.color)))),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.value.title, style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600,
                color: Color(0xFFDDDDDD))),
              const SizedBox(height: 3),
              Text(e.value.desc, style: const TextStyle(
                fontSize: 9, color: ResQColors.textHint, height: 1.55)),
            ])),
          ])),
      ])).toList(),
    ));
  }

  Widget _buildFaqSection() => _buildSection('FREQUENTLY ASKED',
    Column(children: _faqs.asMap().entries.map((e) => Column(children: [
      if (e.key > 0) const Divider(color: Color(0xFF141414), height: 1),
      GestureDetector(
        onTap: () => setState(() => _openFaq = _openFaq == e.key ? -1 : e.key),
        child: Padding(padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(e.value.q, style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600,
                color: Color(0xFFDDDDDD)))),
              AnimatedRotation(
                turns: _openFaq == e.key ? 0.25 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Text('›', style: TextStyle(
                  fontSize: 14, color: ResQColors.textHint))),
            ]),
            AnimatedCrossFade(
              firstChild: const SizedBox.shrink(),
              secondChild: Padding(
                padding: const EdgeInsets.only(top: 7),
                child: Text(e.value.a, style: const TextStyle(
                  fontSize: 10, color: Color(0xFF666666), height: 1.6))),
              crossFadeState: _openFaq == e.key
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 200)),
          ])),
      ),
    ])).toList()),
  );

  Widget _buildSetupGuide() {
    final steps = ['Go to Contacts tab',    'Tap the Contacts icon in the bottom navigation',
                   'Tap the + button',       'Press the red FAB button at bottom right',
                   'Add name & phone',       'Enter the contact\'s full name and mobile number',
                   'Test the alert',         'Long-press SOS and verify the contact receives the SMS'];
    return _buildSection('SETUP GUIDE — CONTACTS',
      Padding(padding: const EdgeInsets.all(12),
        child: Column(children: [
          ...List.generate(4, (i) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(width: 20, height: 20,
                decoration: BoxDecoration(shape: BoxShape.circle,
                  color: ResQColors.green.withOpacity(0.15),
                  border: Border.all(color: ResQColors.green.withOpacity(0.35))),
                child: Center(child: Text('${i+1}', style: const TextStyle(
                  fontSize: 9, fontWeight: FontWeight.w700,
                  color: ResQColors.green)))),
              const SizedBox(width: 9),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(steps[i*2], style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600,
                  color: Color(0xFFDDDDDD))),
                Text(steps[i*2+1], style: const TextStyle(
                  fontSize: 9, color: ResQColors.textHint)),
              ])),
            ]))),
          Container(padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: ResQColors.orange.withOpacity(0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: ResQColors.orange.withOpacity(0.22))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('⚠️', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 8),
              const Expanded(child: Text(
                'Add at least one contact before enabling disaster mode or no alerts will be sent.',
                style: TextStyle(fontSize: 9, color: Color(0xFFFF9500), height: 1.55))),
            ])),
        ])));
  }

  Widget _buildResearchCard() => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: ResQColors.blue.withOpacity(0.05),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: ResQColors.blue.withOpacity(0.18))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [
        Text('🎓', style: TextStyle(fontSize: 14)),
        SizedBox(width: 7),
        Text('Research Project', style: TextStyle(
          fontSize: 11, fontWeight: FontWeight.w600,
          color: Color(0xFF888888))),
      ]),
      const SizedBox(height: 7),
      const Text(
        'ResQNet is a Master\'s capstone research project in Software Engineering, '
        'validated against the documented communication failure of Cyclone Ditwah, Sri Lanka (2025).',
        style: TextStyle(fontSize: 10, color: Color(0xFF555555), height: 1.6)),
      const SizedBox(height: 6),
      const Text(
        'Supervisor: Dr. Prakash Kumar Karn\n'
        'Student: Oshadee Kaushalya · 270648042\n'
        'Programme: MSE907 · 2026',
        style: TextStyle(fontFamily: 'Courier New',
          fontSize: 9, color: Color(0xFF444444), height: 1.7)),
    ]),
  );

  Widget _buildSection(String label, Widget content) => Container(
    decoration: BoxDecoration(color: ResQColors.bg2,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: ResQColors.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
        child: Text(label, style: const TextStyle(
          fontSize: 9, fontWeight: FontWeight.w600,
          color: ResQColors.textHint, letterSpacing: 0.08))),
      content,
    ]));
}

class _HeroTag extends StatelessWidget {
  final String text;
  final Color  color;
  const _HeroTag(this.text, this.color);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color: color.withOpacity(0.12),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withOpacity(0.3))),
    child: Text(text, style: TextStyle(
      fontSize: 9, fontWeight: FontWeight.w600, color: color)));
}

class _Faq  { final String q, a; const _Faq(this.q, this.a); }
class _Step { final String num, title, desc; final Color color;
  const _Step(this.num, this.title, this.desc, this.color); }

class _GridPainter extends CustomPainter {
  @override void paint(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0x06FFFFFF)..strokeWidth = 0.5;
    const s = 40.0;
    for(double x=0;x<=size.width; x+=s) canvas.drawLine(Offset(x,0),Offset(x,size.height),p);
    for(double y=0;y<=size.height;y+=s) canvas.drawLine(Offset(0,y),Offset(size.width,y),p);
  }
  @override bool shouldRepaint(_GridPainter o) => false;
}
