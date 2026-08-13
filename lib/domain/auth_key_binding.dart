import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class AuthKeyBinding {
  const AuthKeyBinding({
    required this.id,
    required this.name,
    required this.uuid,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String uuid;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'uuid': uuid,
        'updatedAt': updatedAt.toIso8601String(),
      };

  static AuthKeyBinding? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = value['name'];
    final uuid = value['uuid'];
    final updatedAt = DateTime.tryParse(value['updatedAt']?.toString() ?? '');
    if (id is! String || name is! String || uuid is! String || updatedAt == null) {
      return null;
    }
    return AuthKeyBinding(id: id, name: name, uuid: uuid, updatedAt: updatedAt);
  }
}

class AuthKeyBindingStore {
  static const _preferenceKey = 'authkey_bindings';

  Future<List<AuthKeyBinding>> read() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_preferenceKey);
    final bindings = <AuthKeyBinding>[];
    if (encoded != null) {
      try {
        final values = jsonDecode(encoded);
        if (values is List) {
          for (final value in values) {
            final binding = AuthKeyBinding.fromJson(value);
            if (binding != null) bindings.add(binding);
          }
        }
      } on Object {
        // Ignore malformed metadata and let the user create a fresh binding.
      }
    }
    bindings.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return bindings;
  }

  Future<void> write(List<AuthKeyBinding> bindings) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _preferenceKey,
      jsonEncode(bindings.map((binding) => binding.toJson()).toList()),
    );
  }
}
