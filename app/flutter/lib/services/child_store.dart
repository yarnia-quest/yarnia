import 'package:shared_preferences/shared_preferences.dart';

/// The locally remembered child. Yarnia's promise is to remember the child across
/// nights, so the minted childId + name are persisted on-device after onboarding and
/// reloaded on launch. A stored child is our notion of "logged in": when present we
/// skip onboarding and go straight to the greeting; when absent we onboard.
class StoredChild {
  final String childId;
  final String name;
  const StoredChild(this.childId, this.name);
}

const _kChildId = 'yarnia.childId';
const _kChildName = 'yarnia.childName';

/// Returns the remembered child, or null if none has been onboarded on this device.
Future<StoredChild?> loadStoredChild() async {
  final prefs = await SharedPreferences.getInstance();
  final id = prefs.getString(_kChildId);
  final name = prefs.getString(_kChildName);
  if (id == null || name == null) return null;
  return StoredChild(id, name);
}

/// Remembers the freshly minted child so future launches skip onboarding.
Future<void> saveStoredChild(String childId, String name) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kChildId, childId);
  await prefs.setString(_kChildName, name);
}

/// Forgets the remembered child (the "logout" action), sending the next launch
/// back through onboarding. Used by the logout affordance to flip between flows.
Future<void> clearStoredChild() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_kChildId);
  await prefs.remove(_kChildName);
}
