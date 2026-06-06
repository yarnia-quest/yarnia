import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'screens/greeting_screen.dart';
import 'screens/agent_screen.dart';
import 'screens/cocreation_screen.dart';
import 'screens/playback_screen.dart';
import 'widgets/history_panel.dart';
import 'theme.dart';

// Base URL of the api/ Worker — chosen at BUILD time via a --dart-define (no runtime
// detection). Default localhost covers web + iOS simulator (they share the Mac's network).
// A physical device can't reach the Mac's localhost, so its run config passes the Tailscale
// URL. Selected per target via VS Code launch configs or dart_defines/*.json (see README).
const _apiBase = String.fromEnvironment('API_BASE', defaultValue: 'http://localhost:8787');
const _demoChildId = '11111111-1111-4111-8111-111111111111';
const _demoChildName = 'Lisa';

void main() {
  runApp(const YarniaApp());
}

class YarniaApp extends StatelessWidget {
  const YarniaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Yarnia',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(scaffoldBackgroundColor: navy),
      home: const YarniaRoot(),
    );
  }
}

class YarniaRoot extends StatefulWidget {
  const YarniaRoot({super.key});

  @override
  State<YarniaRoot> createState() => _YarniaRootState();
}

class _YarniaRootState extends State<YarniaRoot> {
  String _screen = 'greeting';
  String? _storyText;
  String? _audioUrl;

  @override
  void initState() {
    super.initState();
    // Warm the history cache in the background so the panel opens instantly.
    _prefetchHistory();
  }

  Future<void> _prefetchHistory() async {
    try {
      final res = await http.get(
        Uri.parse('$_apiBase/child/$_demoChildId/sessions'),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        warmHistoryCache((data['sessions'] as List).cast<Map<String, dynamic>>());
      }
    } catch (e) {
      debugPrint('History prefetch failed: $e');
    }
  }

  Future<void> _handleChoice(String choice) async {
    setState(() => _screen = 'playback');
    try {
      final res = await http.post(
        Uri.parse('$_apiBase/story'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'childId': _demoChildId, 'choice': choice}),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final base64Audio = data['audio'] as String?;
        setState(() {
          _storyText = data['text'] as String?;
          _audioUrl = data['audioUrl'] as String? ??
              (base64Audio != null ? 'data:audio/mpeg;base64,$base64Audio' : null);
        });
      }
    } catch (e) {
      debugPrint('Story fetch failed: $e');
    }
  }

  void _handleRestart() {
    setState(() {
      _screen = 'greeting';
      _storyText = null;
      _audioUrl = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return switch (_screen) {
      'greeting' => GreetingScreen(
          childName: _demoChildName,
          childId: _demoChildId,
          apiBase: _apiBase,
          onBegin: () => setState(() => _screen = 'agent'),
        ),
      'agent' => AgentScreen(
          childName: _demoChildName,
          childId: _demoChildId,
          apiBase: _apiBase,
          onDone: _handleRestart,
          onFallback: _handleRestart,
        ),
      'cocreation' => CoCreationScreen(
          childName: _demoChildName,
          onChoice: _handleChoice,
        ),
      _ => PlaybackScreen(
          childName: _demoChildName,
          storyText: _storyText,
          audioUrl: _audioUrl,
          onRestart: _handleRestart,
        ),
    };
  }
}
