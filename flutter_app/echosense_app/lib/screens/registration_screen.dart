
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import '../services/database_service.dart';
import 'main_navigation.dart';

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});
  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _nameCtrl    = TextEditingController();
  final _phoneCtrl   = TextEditingController();
  final _emailCtrl   = TextEditingController();
  final _passCtrl    = TextEditingController();
  final _medCtrl     = TextEditingController();

  bool _obscurePass  = true;
  bool _isLoading    = false;
  int  _currentStep  = 0; // 0=personal 1=contacts 2=done

  final List<_PickedContact> _emergencyContacts = [];

  // ── Colors ───────────────────────────────────────────────────
  static const _black  = Color(0xFF000000);
  static const _bg2    = Color(0xFF0F0F0F);
  static const _bg3    = Color(0xFF161616);
  static const _red    = Color(0xFFFF3B30);
  static const _green  = Color(0xFF34C759);
  static const _blue   = Color(0xFF0A84FF);
  static const _border = Color(0xFF1A1A1A);
  static const _hint   = Color(0xFF555555);

  @override
  void dispose() {
    _nameCtrl.dispose(); _phoneCtrl.dispose();
    _emailCtrl.dispose(); _passCtrl.dispose(); _medCtrl.dispose();
    super.dispose();
  }

  // ── Pick contact from phone ───────────────────────────────────
  Future<void> _pickContact() async {
    try {
      // Step 1: Request read permission first (looks at native setup)
      bool granted = await FlutterContacts.requestPermission(readonly: true);
      
      // Step 2: Open external system picker interface.
      // We pass 'false' to requestPermission if it failed, because native pickers 
      // can sometimes bypass raw database inspection checks securely.
      final contact = await FlutterContacts.openExternalPick();
      if (contact == null) return;

      // Step 3: Extract full details cleanly
      Contact? full;
      if (granted) {
        full = await FlutterContacts.getContact(contact.id);
      } else {
        // If structural permission flag was strict, fallback to picker payload properties directly
        full = contact;
      }

      if (full == null || full.phones.isEmpty) {
        _showSnack('This contact has no phone number or details could not be read');
        return;
      }

      setState(() {
        _emergencyContacts.add(_PickedContact(
          name:  full!.displayName.isNotEmpty ? full.displayName : 'Emergency Contact',
          phone: full.phones.first.number.replaceAll(' ', ''),
        ));
      });
      print('Registration: Added contact ${full.displayName}');
    } catch (e) {
      _showSnack('Could not open contacts: $e');
    }
  }

  // ── Manual add contact ────────────────────────────────────────
  void _addManual() {
    final nameCtrl  = TextEditingController();
    final phoneCtrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      backgroundColor: _bg2,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20,
            MediaQuery.of(context).viewInsets.bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              const Text('Add Contact Manually',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                  color: Colors.white)),
              const Spacer(),
              GestureDetector(onTap: () => Navigator.pop(context),
                child: const Icon(Icons.close, color: _hint)),
            ]),
            const SizedBox(height: 16),
            _inputField(nameCtrl,  'Full name',     Icons.person_outline),
            const SizedBox(height: 10),
            _inputField(phoneCtrl, 'Phone number',  Icons.phone_outlined,
                type: TextInputType.phone),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () {
                if (nameCtrl.text.isEmpty || phoneCtrl.text.isEmpty) {
                  _showSnack('Please fill both fields');
                  return;
                }
                setState(() => _emergencyContacts.add(_PickedContact(
                  name:  nameCtrl.text.trim(),
                  phone: phoneCtrl.text.trim(),
                )));
                Navigator.pop(context);
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: _red, borderRadius: BorderRadius.circular(14),
                  boxShadow: [BoxShadow(color: _red.withOpacity(0.35), blurRadius: 16)]),
                child: const Center(child: Text('Add Contact',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700,
                    color: Colors.white))),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Register ──────────────────────────────────────────────────
  Future<void> _register() async {
    if (_nameCtrl.text.isEmpty || _phoneCtrl.text.isEmpty) {
      _showSnack('Name and phone are required');
      return;
    }
    setState(() => _isLoading = true);

    try {
      // Save user to SQLite
      await DatabaseService.saveUser(UserModel(
        name:     _nameCtrl.text.trim(),
        phone:    _phoneCtrl.text.trim(),
        email:    _emailCtrl.text.trim(),
        password: _passCtrl.text,
        medical:  _medCtrl.text.trim(),
      ));

      // Save all emergency contacts to SQLite
      for (final c in _emergencyContacts) {
        await DatabaseService.saveContact(ContactModel(
          name:  c.name,
          phone: c.phone,
          role:  'Emergency',
        ));
      }

      print('Registration: Complete — ${_emergencyContacts.length} contacts saved');

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const MainNavigation()));
      }
    } catch (e) {
      _showSnack('Registration failed: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: _red));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _black,
      body: Stack(children: [
        Positioned.fill(child: CustomPaint(painter: _GridPainter())),
        SafeArea(child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),

              // Header
              Row(children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: _red.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _red.withOpacity(0.35))),
                  child: const Center(child: Text('🌀', style: TextStyle(fontSize: 16))),
                ),
                const SizedBox(width: 10),
                const Text('ResQNet', style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white)),
              ]),
              const SizedBox(height: 22),

              RichText(text: const TextSpan(
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800,
                  color: Colors.white, letterSpacing: -0.02, height: 1.15),
                children: [
                  TextSpan(text: 'Create your\n'),
                  TextSpan(text: 'Emergency Profile',
                    style: TextStyle(color: _red)),
                ],
              )),
              const SizedBox(height: 6),
              const Text('This information is stored locally on your device',
                style: TextStyle(fontSize: 11, color: _hint)),
              const SizedBox(height: 22),

              // ── Step 1 — Personal details ──
              _sectionLabel('PERSONAL DETAILS'),
              const SizedBox(height: 8),
              _card(Column(children: [
                _inputField(_nameCtrl,  'Full name *',    Icons.person_outline),
                const SizedBox(height: 10),
                _inputField(_phoneCtrl, 'Phone number *', Icons.phone_outlined,
                    type: TextInputType.phone),
                const SizedBox(height: 10),
                _inputField(_emailCtrl, 'Email (optional)', Icons.email_outlined,
                    type: TextInputType.emailAddress),
                const SizedBox(height: 10),
                _passwordField(),
                const SizedBox(height: 10),
                _inputField(_medCtrl,
                  'Medical notes (blood type, conditions...)',
                  Icons.medical_information_outlined,
                  maxLines: 2),
              ])),
              const SizedBox(height: 18),

              // ── Step 2 — Emergency contacts ──
              Row(children: [
                Expanded(child: _sectionLabel('EMERGENCY CONTACTS')),
                Text('${_emergencyContacts.length} added',
                  style: const TextStyle(fontSize: 11, color: _hint)),
              ]),
              const SizedBox(height: 8),

              // Add buttons
              Row(children: [
                Expanded(
                  child: _outlineBtn('📱 From Contacts', _pickContact, _blue),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _outlineBtn('✏️ Type Manually', _addManual, _hint),
                ),
              ]),
              const SizedBox(height: 10),

              // Contact list
              if (_emergencyContacts.isEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _bg2, borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _border)),
                  child: const Row(children: [
                    Text('⚠️', style: TextStyle(fontSize: 14)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(
                      'Add at least one emergency contact — they will receive SMS alerts automatically',
                      style: TextStyle(fontSize: 11, color: _hint, height: 1.5))),
                  ]),
                )
              else
                ..._emergencyContacts.asMap().entries.map((e) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _bg2, borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _border)),
                    child: Row(children: [
                      Container(
                        width: 36, height: 36,
                        decoration: BoxDecoration(
                          color: _green.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: _green.withOpacity(0.3))),
                        child: Center(child: Text(
                          e.value.name.isNotEmpty ? e.value.name[0].toUpperCase() : 'E',
                          style: const TextStyle(fontSize: 14,
                            fontWeight: FontWeight.w700, color: _green))),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.value.name, style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600,
                            color: Colors.white)),
                          Text(e.value.phone, style: const TextStyle(
                            fontFamily: 'Courier New', fontSize: 10,
                            color: _hint)),
                        ],
                      )),
                      GestureDetector(
                        onTap: () => setState(() =>
                            _emergencyContacts.removeAt(e.key)),
                        child: const Icon(Icons.close, color: _hint, size: 18)),
                    ]),
                  ),
                )),

              const SizedBox(height: 24),

              // Register button
              // Register button
              GestureDetector(
                onTap: _isLoading ? null : _register,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  decoration: BoxDecoration(
                    color: _red, borderRadius: BorderRadius.circular(16),
                    boxShadow: [BoxShadow(
                      color: _red.withOpacity(0.35), blurRadius: 20)]),
                  child: Center(child: _isLoading
                    ? const SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                    : const Text('Create Profile & Start ResQNet',
                        style: TextStyle(fontSize: 14,
                          fontWeight: FontWeight.w700, color: Colors.white))),
                ),
              ),

              const SizedBox(height: 10),
              const Center(child: Text(
                'All data stored locally · Never sent to cloud',
                style: TextStyle(fontSize: 10, color: _hint))),
              const SizedBox(height: 32),
            ],
          ),
        )),
      ]),
    );
  }

  Widget _sectionLabel(String text) => Text(text,
    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
      color: _hint, letterSpacing: 0.08));

  Widget _card(Widget child) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: _bg2, borderRadius: BorderRadius.circular(16),
      border: Border.all(color: _border)),
    child: child,
  );

  Widget _inputField(TextEditingController ctrl, String hint, IconData icon,
      {TextInputType? type, int maxLines = 1}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
      decoration: BoxDecoration(
        color: _bg3, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border)),
      child: Row(children: [
        Icon(icon, color: _hint, size: 16),
        const SizedBox(width: 9),
        Expanded(child: TextField(
          controller: ctrl, keyboardType: type, maxLines: maxLines,
          style: const TextStyle(fontSize: 13, color: Colors.white),
          decoration: InputDecoration(
            hintText: hint, isDense: true,
            contentPadding: EdgeInsets.zero, border: InputBorder.none,
            hintStyle: const TextStyle(fontSize: 13, color: _hint)),
        )),
      ]),
    );
  }

  Widget _passwordField() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
    decoration: BoxDecoration(
      color: _bg3, borderRadius: BorderRadius.circular(12),
      border: Border.all(color: _border)),
    child: Row(children: [
      const Icon(Icons.lock_outline, color: _hint, size: 16),
      const SizedBox(width: 9),
      Expanded(child: TextField(
        controller: _passCtrl, obscureText: _obscurePass,
        style: const TextStyle(fontSize: 13, color: Colors.white),
        decoration: InputDecoration(
          hintText: 'Password (optional)', isDense: true,
          contentPadding: EdgeInsets.zero, border: InputBorder.none,
          hintStyle: const TextStyle(fontSize: 13, color: _hint)),
      )),
      GestureDetector(
        onTap: () => setState(() => _obscurePass = !_obscurePass),
        child: Icon(_obscurePass
          ? Icons.visibility_off_outlined
          : Icons.visibility_outlined, color: _hint, size: 16)),
    ]),
  );

  Widget _outlineBtn(String text, VoidCallback onTap, Color color) =>
    GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3))),
        child: Center(child: Text(text,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
            color: color))),
      ),
    );
}

class _PickedContact {
  final String name, phone;
  const _PickedContact({required this.name, required this.phone});
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0x06FFFFFF)..strokeWidth = 0.5;
    const s = 40.0;
    for (double x=0;x<=size.width; x+=s)
      canvas.drawLine(Offset(x,0), Offset(x,size.height), p);
    for (double y=0;y<=size.height;y+=s)
      canvas.drawLine(Offset(0,y), Offset(size.width,y), p);
  }
  @override bool shouldRepaint(_GridPainter o) => false;
}