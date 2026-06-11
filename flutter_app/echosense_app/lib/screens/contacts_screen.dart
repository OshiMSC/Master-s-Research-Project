import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import '../services/database_service.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});
  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  List<ContactModel> _contacts = [];
  bool _loading = true;

  static const _black  = Color(0xFF000000);
  static const _bg2    = Color(0xFF0F0F0F);
  static const _bg3    = Color(0xFF161616);
  static const _red    = Color(0xFFFF3B30);
  static const _green  = Color(0xFF34C759);
  static const _blue   = Color(0xFF0A84FF);
  static const _orange = Color(0xFFFF9500);
  static const _border = Color(0xFF1A1A1A);
  static const _hint   = Color(0xFF555555);

  final List<Color> _avatarColors = [_red, _green, _blue, _orange];

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    setState(() => _loading = true);
    final saved = await DatabaseService.getContacts();
    setState(() { _contacts = saved; _loading = false; });
    print('ContactsScreen: Loaded ${_contacts.length} contacts from DB');
  }

  Future<void> _pickFromPhone() async {
    try {
      if (!await FlutterContacts.requestPermission()) {
        _snack('Contacts permission denied');
        return;
      }
      final contact = await FlutterContacts.openExternalPick();
      if (contact == null) return;
      final full = await FlutterContacts.getContact(contact.id);
      if (full == null || full.phones.isEmpty) {
        _snack('Contact has no phone number');
        return;
      }
      final newContact = ContactModel(
        name:  full.displayName,
        phone: full.phones.first.number.replaceAll(' ', ''),
        role:  'Emergency',
      );
      await DatabaseService.saveContact(newContact);
      await _loadContacts();
      _snack('✓ ${full.displayName} added');
    } catch (e) {
      _snack('Could not open contacts: $e');
    }
  }

  void _showAddSheet() {
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
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const Text('Add Contact', style: TextStyle(
              fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
            const Spacer(),
            GestureDetector(onTap: () => Navigator.pop(context),
              child: const Icon(Icons.close, color: _hint)),
          ]),
          const SizedBox(height: 14),
          // From phone contacts button
          GestureDetector(
            onTap: () { Navigator.pop(context); _pickFromPhone(); },
            child: Container(
              width: double.infinity, padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _blue.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _blue.withOpacity(0.3))),
              child: const Row(mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.contacts_outlined, color: _blue, size: 16),
                  SizedBox(width: 8),
                  Text('Pick from Phone Contacts', style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: _blue)),
                ]),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Row(children: [
              Expanded(child: Divider(color: Color(0xFF1A1A1A))),
              Padding(padding: EdgeInsets.symmetric(horizontal: 10),
                child: Text('or type manually',
                  style: TextStyle(fontSize: 10, color: _hint))),
              Expanded(child: Divider(color: Color(0xFF1A1A1A))),
            ]),
          ),
          _field(nameCtrl,  'Full name',     Icons.person_outline),
          const SizedBox(height: 10),
          _field(phoneCtrl, 'Phone number',  Icons.phone_outlined,
              type: TextInputType.phone),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () async {
              if (nameCtrl.text.isEmpty || phoneCtrl.text.isEmpty) {
                _snack('Fill both fields');
                return;
              }
              await DatabaseService.saveContact(ContactModel(
                name:  nameCtrl.text.trim(),
                phone: phoneCtrl.text.trim(),
                role:  'Emergency',
              ));
              Navigator.pop(context);
              await _loadContacts();
              _snack('✓ Contact saved');
            },
            child: Container(
              width: double.infinity, padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _red, borderRadius: BorderRadius.circular(14),
                boxShadow: [BoxShadow(color: _red.withOpacity(0.35), blurRadius: 16)]),
              child: const Center(child: Text('Save Contact',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700,
                  color: Colors.white))),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _deleteContact(ContactModel c) async {
    if (c.id == null) return;
    await DatabaseService.deleteContact(c.id!);
    await _loadContacts();
    _snack('Contact removed');
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: _red,
        duration: const Duration(seconds: 2)));
  }

  Color _colorFor(int i) => _avatarColors[i % _avatarColors.length];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _black,
      body: Stack(children: [
        Positioned.fill(child: CustomPaint(painter: _GridPainter())),
        SafeArea(child: Column(children: [
          // Header
          Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(children: [
              const Text('Contacts', style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
              const Spacer(),
              Text('${_contacts.length} saved',
                style: const TextStyle(fontSize: 11, color: _hint)),
            ])),
          const SizedBox(height: 12),

          // Body
          Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator(color: _red))
            : _contacts.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 80),
                  itemCount: _contacts.length,
                  itemBuilder: (_, i) => Dismissible(
                    key: ValueKey(_contacts[i].id ?? _contacts[i].phone),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: _red.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(16)),
                      child: const Icon(Icons.delete_outline, color: _red)),
                    onDismissed: (_) => _deleteContact(_contacts[i]),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _buildCard(_contacts[i], i)),
                  ),
                )),
        ])),

        // FAB
        Positioned(bottom: 24, right: 24,
          child: GestureDetector(
            onTap: _showAddSheet,
            child: Container(width: 52, height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle, color: _red,
                boxShadow: [BoxShadow(color: _red.withOpacity(0.45), blurRadius: 20)]),
              child: const Icon(Icons.add, color: Colors.white, size: 26)))),
      ]),
    );
  }

  Widget _buildCard(ContactModel c, int i) {
    final color = _colorFor(i);
    final initial = c.name.isNotEmpty ? c.name[0].toUpperCase() : '?';
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: _bg2, borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border)),
      child: Row(children: [
        Container(width: 44, height: 44,
          decoration: BoxDecoration(
            color: color.withOpacity(0.18),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withOpacity(0.35))),
          child: Center(child: Text(initial, style: TextStyle(
            fontSize: 16, fontWeight: FontWeight.w700, color: color)))),
        const SizedBox(width: 11),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c.name, style: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
          const SizedBox(height: 3),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
            child: Text(c.role, style: TextStyle(
              fontSize: 9, fontWeight: FontWeight.w500, color: color))),
          const SizedBox(height: 2),
          Text(c.phone, style: const TextStyle(
            fontFamily: 'Courier New', fontSize: 10, color: _hint)),
        ])),
        Row(children: [
          _actionBtn(Icons.call_outlined, _green),
          const SizedBox(width: 6),
          _actionBtn(Icons.delete_outline, _hint,
            onTap: () => _deleteContact(c)),
        ]),
      ]),
    );
  }

  Widget _buildEmptyState() => Center(
    child: Padding(padding: const EdgeInsets.all(40),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 60, height: 60,
          decoration: BoxDecoration(
            color: _red.withOpacity(0.1), shape: BoxShape.circle,
            border: Border.all(color: _red.withOpacity(0.3))),
          child: const Center(child: Icon(Icons.contacts_outlined,
            color: _red, size: 26))),
        const SizedBox(height: 14),
        const Text('No emergency contacts', style: TextStyle(
          fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white)),
        const SizedBox(height: 6),
        const Text('Add contacts who will receive SOS alerts automatically',
          style: TextStyle(fontSize: 12, color: _hint, height: 1.5),
          textAlign: TextAlign.center),
        const SizedBox(height: 20),
        GestureDetector(
          onTap: _showAddSheet,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              color: _red, borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: _red.withOpacity(0.35), blurRadius: 16)]),
            child: const Text('Add First Contact', style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)))),
      ])));

  Widget _actionBtn(IconData icon, Color color, {VoidCallback? onTap}) =>
    GestureDetector(
      onTap: onTap ?? () {},
      child: Container(width: 30, height: 30,
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: color.withOpacity(0.3))),
        child: Icon(icon, color: color, size: 14)));

  Widget _field(TextEditingController ctrl, String hint, IconData icon,
      {TextInputType? type}) =>
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
      decoration: BoxDecoration(
        color: _bg3, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border)),
      child: Row(children: [
        Icon(icon, color: _hint, size: 16),
        const SizedBox(width: 9),
        Expanded(child: TextField(
          controller: ctrl, keyboardType: type,
          style: const TextStyle(fontSize: 13, color: Colors.white),
          decoration: InputDecoration(
            hintText: hint, isDense: true,
            contentPadding: EdgeInsets.zero, border: InputBorder.none,
            hintStyle: const TextStyle(fontSize: 13, color: _hint)))),
      ]));
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