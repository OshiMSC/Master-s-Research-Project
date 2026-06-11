import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// ResQNet — Local SQLite Database
/// Stores: user profile, emergency contacts, alert history
class DatabaseService {
  static Database? _db;

  static Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    final path = join(await getDatabasesPath(), 'resqnet.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        // User profile table
        await db.execute('''
          CREATE TABLE user (
            id          INTEGER PRIMARY KEY,
            name        TEXT NOT NULL,
            phone       TEXT NOT NULL,
            email       TEXT,
            password    TEXT,
            medical     TEXT,
            created_at  TEXT
          )
        ''');

        // Emergency contacts table
        await db.execute('''
          CREATE TABLE contacts (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            name        TEXT NOT NULL,
            phone       TEXT NOT NULL,
            role        TEXT DEFAULT "Emergency",
            created_at  TEXT
          )
        ''');

        // Alert history table
        await db.execute('''
          CREATE TABLE alerts (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            sound_type  TEXT NOT NULL,
            confidence  REAL NOT NULL,
            latitude    REAL,
            longitude   REAL,
            sms_sent    INTEGER DEFAULT 0,
            dash_sent   INTEGER DEFAULT 0,
            timestamp   TEXT
          )
        ''');
      },
    );
  }

  // ── User ──────────────────────────────────────────────────────
  static Future<void> saveUser(UserModel user) async {
    final db = await database;
    await db.insert('user', user.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    print('DB: User saved — ${user.name}');
  }

  static Future<UserModel?> getUser() async {
    final db   = await database;
    final rows = await db.query('user', limit: 1);
    if (rows.isEmpty) return null;
    return UserModel.fromMap(rows.first);
  }

  static Future<bool> isRegistered() async {
    final user = await getUser();
    return user != null;
  }

  // ── Contacts ──────────────────────────────────────────────────
  static Future<void> saveContact(ContactModel c) async {
    final db = await database;
    await db.insert('contacts', c.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    print('DB: Contact saved — ${c.name} ${c.phone}');
  }

  static Future<List<ContactModel>> getContacts() async {
    final db   = await database;
    final rows = await db.query('contacts');
    return rows.map(ContactModel.fromMap).toList();
  }

  static Future<void> deleteContact(int id) async {
    final db = await database;
    await db.delete('contacts', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> updateContact(ContactModel c) async {
    final db = await database;
    await db.update('contacts', c.toMap(),
        where: 'id = ?', whereArgs: [c.id]);
  }

  // ── Alert history ─────────────────────────────────────────────
  static Future<void> saveAlert(AlertRecord a) async {
    final db = await database;
    await db.insert('alerts', a.toMap());
  }

  static Future<List<AlertRecord>> getAlerts() async {
    final db   = await database;
    final rows = await db.query('alerts', orderBy: 'id DESC', limit: 50);
    return rows.map(AlertRecord.fromMap).toList();
  }
}

// ── Models ────────────────────────────────────────────────────

class UserModel {
  final int?   id;
  final String name, phone;
  final String? email, password, medical;
  final String? createdAt;

  const UserModel({
    this.id, required this.name, required this.phone,
    this.email, this.password, this.medical, this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'id':         id ?? 1,
    'name':       name,
    'phone':      phone,
    'email':      email ?? '',
    'password':   password ?? '',
    'medical':    medical ?? '',
    'created_at': createdAt ?? DateTime.now().toIso8601String(),
  };

  factory UserModel.fromMap(Map<String, dynamic> m) => UserModel(
    id:        m['id'] as int?,
    name:      m['name'] as String,
    phone:     m['phone'] as String,
    email:     m['email'] as String?,
    password:  m['password'] as String?,
    medical:   m['medical'] as String?,
    createdAt: m['created_at'] as String?,
  );
}

class ContactModel {
  final int?   id;
  final String name, phone, role;
  final String? createdAt;

  const ContactModel({
    this.id, required this.name, required this.phone,
    this.role = 'Emergency', this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'name':       name,
    'phone':      phone,
    'role':       role,
    'created_at': createdAt ?? DateTime.now().toIso8601String(),
  };

  factory ContactModel.fromMap(Map<String, dynamic> m) => ContactModel(
    id:        m['id'] as int?,
    name:      m['name'] as String,
    phone:     m['phone'] as String,
    role:      m['role'] as String? ?? 'Emergency',
    createdAt: m['created_at'] as String?,
  );
}

class AlertRecord {
  final int?   id;
  final String soundType;
  final double confidence;
  final double? latitude, longitude;
  final bool   smsSent, dashSent;
  final String? timestamp;

  const AlertRecord({
    this.id, required this.soundType, required this.confidence,
    this.latitude, this.longitude,
    this.smsSent = false, this.dashSent = false, this.timestamp,
  });

  Map<String, dynamic> toMap() => {
    'sound_type': soundType,
    'confidence': confidence,
    'latitude':   latitude,
    'longitude':  longitude,
    'sms_sent':   smsSent  ? 1 : 0,
    'dash_sent':  dashSent ? 1 : 0,
    'timestamp':  timestamp ?? DateTime.now().toIso8601String(),
  };

  factory AlertRecord.fromMap(Map<String, dynamic> m) => AlertRecord(
    id:         m['id'] as int?,
    soundType:  m['sound_type'] as String,
    confidence: m['confidence'] as double,
    latitude:   m['latitude'] as double?,
    longitude:  m['longitude'] as double?,
    smsSent:    (m['sms_sent'] as int) == 1,
    dashSent:   (m['dash_sent'] as int) == 1,
    timestamp:  m['timestamp'] as String?,
  );
}