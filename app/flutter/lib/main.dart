import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'screens/onboarding_screen.dart';
import 'screens/greeting_screen.dart';
import 'screens/agent_screen.dart';
import 'screens/cocreation_screen.dart';
import 'screens/playback_screen.dart';
import 'services/child_store.dart';
import 'widgets/history_panel.dart';
import 'widgets/starfield.dart';
import 'theme.dart';

// Base URL of the api/ Worker — chosen at BUILD time via a --dart-define (no runtime
// detection). Default localhost covers web + iOS simulator (they share the Mac's network).
// A physical device can't reach the Mac's localhost, so its run config passes the deployed
// api.yarnia.quest URL. Selected per target via VS Code launch configs or dart_defines/*.json (see README).
const _apiBase = String.fromEnvironment('API_BASE', defaultValue: 'http://localhost:8787');

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
  // Boots in 'loading' while we read the remembered child off-device. A stored child
  // (onboarded on a previous night) is our notion of "logged in": we skip onboarding
  // and go straight to the greeting. No stored child -> onboarding mints one. This is
  // what lets Yarnia remember the child across nights instead of re-onboarding each launch.
  String _screen = 'loading';
  String? _childId;
  String? _childName;
  String? _storyText;
  String? _audioUrl;

  @override
  void initState() {
    super.initState();
    _restoreChild();
  }

  Future<void> _restoreChild() async {
    final stored = await loadStoredChild();
    if (!mounted) return;
    if (stored != null) {
      setState(() {
        _childId = stored.childId;
        _childName = stored.name;
        _screen = 'greeting';
      });
      _prefetchHistory();
    } else {
      setState(() => _screen = 'onboarding');
    }
  }

  // Called when onboarding succeeds: persist the freshly minted child (so future
  // launches skip onboarding), warm the history cache, and move on to the greeting.
  void _handleOnboarded(String childId, String name) {
    saveStoredChild(childId, name);
    setState(() {
      _childId = childId;
      _childName = name;
      _screen = 'greeting';
    });
    _prefetchHistory();
  }

  // "Logout": forget the remembered child and return to onboarding, so the two flows
  // can be exercised on one device.
  Future<void> _handleLogout() async {
    await clearStoredChild();
    if (!mounted) return;
    setState(() {
      _childId = null;
      _childName = null;
      _storyText = null;
      _audioUrl = null;
      _screen = 'onboarding';
    });
  }

  Future<void> _prefetchHistory() async {
    final childId = _childId;
    if (childId == null) return;
    try {
      final res = await http.get(
        Uri.parse('$_apiBase/child/$childId/sessions'),
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
    final childId = _childId;
    if (childId == null) return;
    setState(() => _screen = 'playback');
    try {
      final res = await http.post(
        Uri.parse('$_apiBase/story'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'childId': childId, 'choice': choice}),
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
    // While restoring the remembered child, show the starfield (no flash of onboarding
    // before we know whether a child is stored). The read is near-instant.
    if (_screen == 'loading') {
      return const Scaffold(
        backgroundColor: navy,
        body: Starfield(),
      );
    }

    // Onboarding is the only screen reachable before a child exists; every other
    // screen runs after _childId / _childName are set, so the non-null reads are safe.
    if (_screen == 'onboarding' || _childId == null) {
      return OnboardingScreen(
        apiBase: _apiBase,
        onComplete: _handleOnboarded,
      );
    }

    final childId = _childId!;
    final childName = _childName!;
    return switch (_screen) {
      'greeting' => GreetingScreen(
          childName: childName,
          childId: childId,
          apiBase: _apiBase,
          onBegin: () => setState(() => _screen = 'agent'),
          onLogout: _handleLogout,
        ),
      'agent' => AgentScreen(
          childName: childName,
          childId: childId,
          apiBase: _apiBase,
          onDone: _handleRestart,
          onFallback: _handleRestart,
        ),
      'cocreation' => CoCreationScreen(
          childName: childName,
          onChoice: _handleChoice,
        ),
      _ => PlaybackScreen(
          childName: childName,
          storyText: _storyText,
          audioUrl: _audioUrl,
          onRestart: _handleRestart,
        ),
    };
  }
}
