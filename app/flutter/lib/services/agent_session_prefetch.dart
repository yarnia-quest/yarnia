import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import '../api_config.dart';

/// Result of GET /agent/session — the handful of fields AgentScreen needs to start
/// the ElevenLabs conversation. Kept as a plain holder so it can be cached and handed
/// over without re-parsing.
class AgentSessionData {
  final String? signedUrl;
  final String? agentId;
  final Map<String, dynamic>? dynamicVariables;

  const AgentSessionData({this.signedUrl, this.agentId, this.dynamicVariables});

  factory AgentSessionData.fromJson(Map<String, dynamic> json) => AgentSessionData(
        signedUrl: json['signedUrl'] as String?,
        agentId: json['agentId'] as String?,
        dynamicVariables: json['dynamicVariables'] as Map<String, dynamic>?,
      );
}

// In-flight (or completed) prefetch, keyed by childId. The GreetingScreen warms this
// while the parent reads "Good night, X" so AgentScreen can skip the /agent/session
// round-trip when "Begin" is tapped — collapsing the visible "Travelling to Yarnia"
// wait down to just the ElevenLabs connect. Mirrors the history-panel cache pattern.
Future<AgentSessionData>? _pending;
String? _pendingChildId;

/// Kick off the agent-session fetch (and an early mic-permission request) without
/// awaiting. Safe to call repeatedly: a prefetch already running for this child is
/// reused rather than duplicated. The mic prompt is moved out of the post-"Begin"
/// critical path so the first-run dialog no longer sits inside the visible wait.
void prefetchAgentSession(String apiBase, String childId) {
  if (_pendingChildId == childId && _pending != null) return;
  _pendingChildId = childId;
  _pending = _fetch(apiBase, childId);
  // Fire-and-forget: warm the mic permission too. Idempotent — if already granted this
  // resolves instantly; AgentScreen still re-checks before connecting.
  Permission.microphone.request().ignore();
}

/// Hand the prefetched session to AgentScreen. Single-use: clears the cache so a later
/// session re-fetches fresh (signed tokens are short-lived). Returns null if nothing was
/// prefetched for this child, in which case the caller should fetch normally.
Future<AgentSessionData>? takeAgentSession(String childId) {
  if (_pendingChildId != childId) return null;
  final p = _pending;
  _pending = null;
  _pendingChildId = null;
  return p;
}

Future<AgentSessionData> _fetch(String apiBase, String childId) async {
  final res = await http.get(Uri.parse('$apiBase/agent/session?childId=$childId'), headers: apiHeaders());
  if (res.statusCode != 200) {
    throw Exception('Session ${res.statusCode}: ${res.body}');
  }
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  debugPrint('Agent session prefetched for $childId');
  return AgentSessionData.fromJson(data);
}
