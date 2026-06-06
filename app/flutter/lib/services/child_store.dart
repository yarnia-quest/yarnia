import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// A locally remembered child. Yarnia's promise is to remember the child across nights, so the
/// minted childId + name (+ per-child auth token) are persisted on-device after onboarding and
/// reloaded on launch. The device can hold MULTIPLE children (a household with siblings) and
/// switch between them; a stored, active child is our notion of "logged in".
class StoredChild {
  final String childId;
  final String name;

  /// Per-child auth token returned by POST /child. Sent as X-Child-Token so only this device
  /// can use the profile. Nullable for children migrated from before tokens existed.
  final String? token;

  const StoredChild(this.childId, this.name, {this.token});

  Map<String, dynamic> toJson() => {
        'childId': childId,
        'name': name,
        if (token != null) 'token': token,
      };

  factory StoredChild.fromJson(Map<String, dynamic> j) =>
      StoredChild(j['childId'] as String, j['name'] as String, token: j['token'] as String?);
}

const _kChildren = 'yarnia.children'; // JSON array of StoredChild
const _kActiveId = 'yarnia.activeChildId';
// Legacy single-child keys (pre multi-child); migrated on first read.
const _kLegacyId = 'yarnia.childId';
const _kLegacyName = 'yarnia.childName';

Future<List<StoredChild>> _readList(SharedPreferences prefs) async {
  final raw = prefs.getString(_kChildren);
  if (raw != null) {
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list.map(StoredChild.fromJson).toList();
  }
  // Migrate a legacy single child into the list, once.
  final id = prefs.getString(_kLegacyId);
  final name = prefs.getString(_kLegacyName);
  if (id != null && name != null) {
    final migrated = [StoredChild(id, name)];
    await _writeList(prefs, migrated);
    await prefs.setString(_kActiveId, id);
    return migrated;
  }
  return [];
}

Future<void> _writeList(SharedPreferences prefs, List<StoredChild> list) async {
  await prefs.setString(_kChildren, jsonEncode(list.map((c) => c.toJson()).toList()));
}

/// All children onboarded on this device.
Future<List<StoredChild>> loadChildren() async {
  final prefs = await SharedPreferences.getInstance();
  return _readList(prefs);
}

/// The active child (currently selected profile), or null if none onboarded.
Future<StoredChild?> loadStoredChild() async {
  final prefs = await SharedPreferences.getInstance();
  final list = await _readList(prefs);
  if (list.isEmpty) return null;
  final activeId = prefs.getString(_kActiveId);
  return list.firstWhere((c) => c.childId == activeId, orElse: () => list.first);
}

/// Adds or updates a child (by id) and makes it the active profile.
Future<void> saveStoredChild(String childId, String name, {String? token}) async {
  final prefs = await SharedPreferences.getInstance();
  final list = await _readList(prefs);
  final child = StoredChild(childId, name, token: token);
  final idx = list.indexWhere((c) => c.childId == childId);
  if (idx >= 0) {
    list[idx] = child;
  } else {
    list.add(child);
  }
  await _writeList(prefs, list);
  await prefs.setString(_kActiveId, childId);
}

/// Switches the active profile to an already-stored child.
Future<void> setActiveChild(String childId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kActiveId, childId);
}

/// Removes the active child (the "logout"/"remove profile" action). If siblings remain, the
/// first becomes active; otherwise the device returns to onboarding.
Future<void> clearStoredChild() async {
  final prefs = await SharedPreferences.getInstance();
  final list = await _readList(prefs);
  final activeId = prefs.getString(_kActiveId);
  list.removeWhere((c) => c.childId == activeId);
  await _writeList(prefs, list);
  if (list.isNotEmpty) {
    await prefs.setString(_kActiveId, list.first.childId);
  } else {
    await prefs.remove(_kActiveId);
  }
}
