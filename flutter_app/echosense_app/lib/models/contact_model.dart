class ContactModel {
  final String id;
  final String name;
  final String phone;

  const ContactModel({
    required this.id,
    required this.name,
    required this.phone,
  });

  Map<String, dynamic> toMap() => {
    'id':    id,
    'name':  name,
    'phone': phone,
  };

  factory ContactModel.fromMap(Map<String, dynamic> map) {
    return ContactModel(
      id:    map['id'],
      name:  map['name'],
      phone: map['phone'],
    );
  }

  // Format phone for display
  String get displayPhone {
    if (phone.length == 10) {
      return '${phone.substring(0,3)}-${phone.substring(3,6)}-${phone.substring(6)}';
    }
    return phone;
  }
}