import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'home_screen.dart';
import 'contacts_screen.dart';
import 'history_screen.dart';
import 'settings_screen.dart';




class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});
  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    HomeScreen(),
    ContactsScreen(),
    HistoryScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor:           Colors.transparent,
      statusBarIconBrightness:  Brightness.light,
      systemNavigationBarColor: Color(0xFF0F0F0F),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0F0F0F),
          border: Border(top: BorderSide(color: Color(0xFF1A1A1A))),
        ),
        child: SafeArea(
          top: false,
          child: BottomNavigationBar(
            currentIndex: _currentIndex,
            onTap: (i) => setState(() => _currentIndex = i),
            backgroundColor: Colors.transparent,
            elevation:       0,
            type:            BottomNavigationBarType.fixed,
            selectedItemColor:    const Color(0xFFFF3B30),
            unselectedItemColor:  const Color(0xFF555555),
            selectedLabelStyle:   const TextStyle(
              fontSize: 10, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 10),
            items: const [
              BottomNavigationBarItem(
                icon:       Icon(Icons.shield_outlined),
                activeIcon: Icon(Icons.shield),
                label:      'Home',
              ),
              BottomNavigationBarItem(
                icon:       Icon(Icons.contacts_outlined),
                activeIcon: Icon(Icons.contacts),
                label:      'Contacts',
              ),
              BottomNavigationBarItem(
                icon:       Icon(Icons.history_outlined),
                activeIcon: Icon(Icons.history),
                label:      'History',
              ),
              BottomNavigationBarItem(
                icon:       Icon(Icons.settings_outlined),
                activeIcon: Icon(Icons.settings),
                label:      'Settings',
              ),
            ],
          ),
        ),
      ),
    );
  }
}