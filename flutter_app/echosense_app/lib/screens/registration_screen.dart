import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:bcrypt/bcrypt.dart';
import '../services/database_service.dart';
import 'main_navigation.dart';

/// ResQNet — Registration Screen (v2)
/// =====================================
/// CHANGES FROM ORIGINAL:
///  1. Medical notes field REMOVED per request.
///  2. Home address field ADDED (plain text — no autocomplete/API,
///     per discussion: a geocoding API was considered but skipped to
///     avoid adding API-key/network dependency this close to the
///     project deadline).
///  3. Password is now OPTIONAL but, if provided, is hashed with
///     bcrypt before being stored — never stored in plaintext. There
///     is currently no remote auth backend (no server validates this
///     password against anything), so this is intentionally framed
///     as a LOCAL APP LOCK, not a real login system. Making it
///     mandatory would have given a false impression of security
///     without an actual backend behind it. A real authentication
///     backend is noted as a Future Enhancement rather than rushed
///     in days before a presentation.
///  4. Email is OPTIONAL (kept that way deliberately — requiring it
///     would exclude users without easy email access, which runs
///     against the accessibility goals of a disaster-response app)
///     but is now properly format-validated if the user does enter
///     one, instead of accepting anything.
///  5. Phone number remains REQUIRED (the SMS alert pipeline
///     fundamentally depends on it) and is now properly validated —
///     previously any non-empty string was accepted, including
///     obviously malformed input.
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
  final _addressCtrl = TextEditingController();

  bool _obscurePass  = true;
  bool _isLoading    = false;

  // Inline validation error messages, shown under each field once the
  // user has interacted with it (not before — avoids "required field"
  // errors flashing red before anyone has had a chance to type).
  String? _nameError;
  String? _phoneError;
  String? _emailError;
  String? _passwordError;

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

  // ── Validation patterns ─────────────────────────────────────
  // Pragmatic email pattern — covers the vast majority of real
  // addresses without the complexity (and false rejections) of a full
  // RFC 5322 implementation.
  static final RegExp _emailPattern =
      RegExp(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$');
  // Accepts an optional leading + then 7-15 digits, after stripping
  // spaces/dashes/parens. Permissive on formatting (countries differ),
  // strict on actually containing a plausible number of digits.
  static final RegExp _phoneCleanPattern = RegExp(r'[\s\-\(\)]');
  static final RegExp _phoneDigitsPattern = RegExp(r'^\+?\d{7,15}$');

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  // ── Validation helpers ──────────────────────────────────────
  String? _validateName(String v) {
    if (v.trim().isEmpty) return 'Full name is required';
    return null;
  }

  String? _validatePhone(String v) {
    final trimmed = v.trim();
    if (trimmed.isEmpty) return 'Phone number is required';
    final cleaned = trimmed.replaceAll(_phoneCleanPattern, '');
    if (!_phoneDigitsPattern.hasMatch(cleaned)) {
      return 'Enter a valid phone number';
    }
    return null;
  }

  String? _validateEmail(String v) {
    final trimmed = v.trim();
    if (trimmed.isEmpty) return null; // optional
    if (!_emailPattern.hasMatch(trimmed)) {
      return 'Enter a valid email address';
    }
    return null;
  }

  String? _validatePassword(String v) {
    if (v.isEmpty) return null; // optional
    if (v.length < 6) return 'Password must be at least 6 characters';
    return null;
  }

  bool _validateAll() {
    setState(() {
      _nameError     = _validateName(_nameCtrl.text);
      _phoneError    = _validatePhone(_phoneCtrl.text);
      _emailError    = _validateEmail(_emailCtrl.text);
      _passwordError = _validatePassword(_passCtrl.text);
    });
    return _nameError == null &&
        _phoneError == null &&
        _emailError == null &&
        _passwordError == null;
  }

  // ── Pick contact from phone ───────────────────────────────────
  Future<void> _pickContact() async {
    try {
      bool granted = await FlutterContacts.requestPermission(readonly: true);

      final contact = await FlutterContacts.openExternalPick();
      if (contact == null) return;

      Contact? full;
      if (granted) {
        full = await FlutterContacts.getContact(contact.id);
      } else {
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
                final cleaned = phoneCtrl.text.trim()
                    .replaceAll(_phoneCleanPattern, '');
                if (nameCtrl.text.trim().isEmpty) {
                  _showSnack('Please enter a name');
                  return;
                }
                if (!_phoneDigitsPattern.hasMatch(cleaned)) {
                  _showSnack('Please enter a valid phone number');
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
    if (!_validateAll()) {
      _showSnack('Please fix the highlighted fields');
      return;
    }
    if (_emergencyContacts.isEmpty) {
      _showSnack('Add at least one emergency contact before continuing');
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Hash the password locally with bcrypt before storing — never
      // store plaintext. If the user left it blank, store null/empty
      // rather than hashing an empty string, so "no password set" is
      // represented unambiguously rather than as a hash of "".
      String? passwordHash;
      if (_passCtrl.text.isNotEmpty) {
        passwordHash = BCrypt.hashpw(_passCtrl.text, BCrypt.gensalt());
      }

      await DatabaseService.saveUser(UserModel(
        name:     _nameCtrl.text.trim(),
        phone:    _phoneCtrl.text.trim(),
        email:    _emailCtrl.text.trim(),
        password: passwordHash ?? '',
        address:  _addressCtrl.text.trim(),
      ));

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
                _inputField(_nameCtrl, 'Full name *', Icons.person_outline,
                    errorText: _nameError,
                    onChanged: (v) => setState(() => _nameError = _validateName(v))),
                const SizedBox(height: 10),
                _inputField(_phoneCtrl, 'Phone number *', Icons.phone_outlined,
                    type: TextInputType.phone,
                    errorText: _phoneError,
                    onChanged: (v) => setState(() => _phoneError = _validatePhone(v))),
                const SizedBox(height: 10),
                _inputField(_emailCtrl, 'Email (optional)', Icons.email_outlined,
                    type: TextInputType.emailAddress,
                    errorText: _emailError,
                    onChanged: (v) => setState(() => _emailError = _validateEmail(v))),
                const SizedBox(height: 10),
                _passwordField(),
                const SizedBox(height: 4),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    'Optional. Locks the app on this device only — there is no '
                    'remote account behind it yet.',
                    style: TextStyle(fontSize: 9, color: _hint, height: 1.4)),
                ),
                const SizedBox(height: 10),
                _inputField(_addressCtrl, 'Home address (optional)',
                    Icons.home_outlined, maxLines: 2),
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
                    SizedBox(width: 10),
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
                    : const Text('Start ResQNet',
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
      {TextInputType? type, int maxLines = 1, String? errorText,
       ValueChanged<String>? onChanged}) {
    final hasError = errorText != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
          decoration: BoxDecoration(
            color: _bg3, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: hasError ? _red : _border)),
          child: Row(children: [
            Icon(icon, color: hasError ? _red : _hint, size: 16),
            const SizedBox(width: 9),
            Expanded(child: TextField(
              controller: ctrl, keyboardType: type, maxLines: maxLines,
              onChanged: onChanged,
              style: const TextStyle(fontSize: 13, color: Colors.white),
              decoration: InputDecoration(
                hintText: hint, isDense: true,
                contentPadding: EdgeInsets.zero, border: InputBorder.none,
                hintStyle: const TextStyle(fontSize: 13, color: _hint)),
            )),
          ]),
        ),
        if (hasError)
          Padding(
            padding: const EdgeInsets.only(top: 5, left: 4),
            child: Text(errorText,
              style: const TextStyle(fontSize: 10, color: _red)),
          ),
      ],
    );
  }

  Widget _passwordField() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
        decoration: BoxDecoration(
          color: _bg3, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _passwordError != null ? _red : _border)),
        child: Row(children: [
          Icon(Icons.lock_outline,
              color: _passwordError != null ? _red : _hint, size: 16),
          const SizedBox(width: 9),
          Expanded(child: TextField(
            controller: _passCtrl, obscureText: _obscurePass,
            onChanged: (v) =>
                setState(() => _passwordError = _validatePassword(v)),
            style: const TextStyle(fontSize: 13, color: Colors.white),
            decoration: InputDecoration(
              hintText: 'App lock password (optional)', isDense: true,
              contentPadding: EdgeInsets.zero, border: InputBorder.none,
              hintStyle: const TextStyle(fontSize: 13, color: _hint)),
          )),
          GestureDetector(
            onTap: () => setState(() => _obscurePass = !_obscurePass),
            child: Icon(_obscurePass
              ? Icons.visibility_off_outlined
              : Icons.visibility_outlined, color: _hint, size: 16)),
        ]),
      ),
      if (_passwordError != null)
        Padding(
          padding: const EdgeInsets.only(top: 5, left: 4),
          child: Text(_passwordError!,
            style: const TextStyle(fontSize: 10, color: _red)),
        ),
    ],
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