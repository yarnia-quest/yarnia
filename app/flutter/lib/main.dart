import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'api_config.dart';
import 'screens/onboarding_screen.dart';
import 'screens/greeting_screen.dart';
import 'screens/agent_screen.dart';
import 'screens/cocreation_screen.dart';
import 'screens/playback_screen.dart';
import 'screens/tts_spike_screen_stub.dart'
    if (dart.library.io) 'screens/tts_spike_screen.dart';
import 'services/child_store.dart';
import 'widgets/history_panel.dart';
import 'widgets/profile_picker.dart';
import 'widgets/starfield.dart';
import 'theme.dart';

// Base URL of the api/ Worker, chosen at BUILD time via a --dart-define (no runtime
// detection). Defaults to the deployed prod backend, so any build that forgets the flag
// still hits api.yarnia.quest and never localhost. Opt into a local dev server explicitly
// with --dart-define-from-file=dart_defines/local.json (see README).
const _apiBase = String.fromEnvironment('API_BASE', defaultValue: 'https://api.yarnia.quest');

// Spike 1a: build with --dart-define=TTS_SPIKE=true to boot straight into the
// on-device TTS experiment instead of the product (see tts_spike_screen.dart).
const _ttsSpike = bool.fromEnvironment('TTS_SPIKE');

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
      // Lora (the deck's body serif) is the app-wide default so any unstyled or
      // Material-default text inherits it; screens opt into Fraunces for headlines.
      theme: ThemeData(scaffoldBackgroundColor: navy, fontFamily: 'Lora'),
      builder: (context, child) => _PhoneFrame(child: child!),
      home: _ttsSpike ? const TtsSpikeScreen() : const YarniaRoot(),
    );
  }
}

// Yarnia is a phone-first product, but it also ships to the web (app.yarnia.quest).
// On a wide browser window a full-bleed mobile layout looks stretched and wrong, so
// every screen is centered inside a phone-width column with a darker backdrop on
// either side — it reads like a mobile app running on desktop. On a real phone (or
// any window narrower than the frame) the constraint is a no-op and the app fills
// the screen as usual.
class _PhoneFrame extends StatelessWidget {
  const _PhoneFrame({required this.child});

  final Widget child;

  // A typical large-phone logical width. Wide enough to feel roomy, narrow enough
  // to keep the mobile layout honest.
  static const double _maxWidth = 430;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Narrower than the frame (real phones): pass through untouched.
        if (constraints.maxWidth <= _maxWidth) return child;

        final media = MediaQuery.of(context);
        // Report the constrained width to descendants so anything sized to
        // MediaQuery.size (e.g. the starfield) lays out against the column,
        // not the full window.
        final framedMedia = media.copyWith(
          size: Size(_maxWidth, media.size.height),
        );
        return ColoredBox(
          // A shade darker than the app navy so the phone column stands out.
          color: const Color(0xFF090A18),
          child: Center(
            child: SizedBox(
              width: _maxWidth,
              child: MediaQuery(data: framedMedia, child: child),
            ),
          ),
        );
      },
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
  // All profiles onboarded on this device (a household can have several children).
  List<StoredChild> _children = [];

  @override
  void initState() {
    super.initState();
    _restoreChild();
  }

  // Makes a stored child the active profile: updates local state and the token sent on
  // child-scoped API calls, then shows the greeting and warms history.
  void _activate(StoredChild child) {
    activeChildToken = child.token;
    setState(() {
      _childId = child.childId;
      _childName = child.name;
      _screen = 'greeting';
    });
    _prefetchHistory();
  }

  Future<void> _restoreChild() async {
    final children = await loadChildren();
    final stored = await loadStoredChild();
    if (!mounted) return;
    _children = children;
    if (stored != null) {
      _activate(stored);
    } else {
      setState(() => _screen = 'onboarding');
    }
  }

  // Called when onboarding succeeds: persist the freshly minted child (with its auth token)
  // so future launches skip onboarding, then activate it.
  Future<void> _handleOnboarded(String childId, String name, String? token) async {
    await saveStoredChild(childId, name, token: token);
    _children = await loadChildren();
    if (!mounted) return;
    _activate(StoredChild(childId, name, token: token));
  }

  // Switch to an already-stored sibling profile.
  Future<void> _handleSelectProfile(StoredChild child) async {
    await setActiveChild(child.childId);
    if (!mounted) return;
    _activate(child);
  }

  // "Add a child" from the profile picker -> onboarding mints another profile.
  void _handleAddChild() => setState(() => _screen = 'onboarding');

  void _handleOpenProfiles() => setState(() => _screen = 'profiles');

  // Remove the active profile. If a sibling remains, switch to it; otherwise onboard.
  Future<void> _handleLogout() async {
    await clearStoredChild();
    _children = await loadChildren();
    final next = await loadStoredChild();
    if (!mounted) return;
    _storyText = null;
    _audioUrl = null;
    if (next != null) {
      _activate(next);
    } else {
      activeChildToken = null;
      setState(() {
        _childId = null;
        _childName = null;
        _screen = 'onboarding';
      });
    }
  }

  Future<void> _prefetchHistory() async {
    final childId = _childId;
    if (childId == null) return;
    try {
      final res = await http.get(
        Uri.parse('$_apiBase/child/$childId/sessions'),
        headers: apiHeaders(),
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
    // Show a "weaving your story" state while POST /story runs (gen + narration can take a few
    // seconds) instead of flashing an empty playback screen.
    setState(() => _screen = 'generating');
    try {
      final res = await http.post(
        Uri.parse('$_apiBase/story'),
        headers: apiHeaders(json: true),
        body: jsonEncode({'childId': childId, 'choice': choice}),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _storyText = data['text'] as String?;
          // POST /story returns `audio` already as a full data: URI
          // (data:audio/mpeg;base64,...) or null. PlaybackScreen plays it as-is.
          _audioUrl = data['audio'] as String?;
          _screen = 'playback';
        });
      } else {
        // Surface the failure instead of a blank playback screen: return to co-creation so
        // the parent can try another idea.
        debugPrint('Story request failed: ${res.statusCode} ${res.body}');
        if (mounted) setState(() => _screen = 'cocreation');
      }
    } catch (e) {
      debugPrint('Story fetch failed: $e');
      if (mounted) setState(() => _screen = 'cocreation');
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
          // Show the profile switcher when this household has more than one child.
          onSwitchProfile: _children.length > 1 ? _handleOpenProfiles : null,
        ),
      'profiles' => ProfilePicker(
          children: _children,
          activeChildId: childId,
          onSelect: _handleSelectProfile,
          onAddChild: _handleAddChild,
          onBack: () => setState(() => _screen = 'greeting'),
        ),
      'agent' => AgentScreen(
          childName: childName,
          childId: childId,
          apiBase: _apiBase,
          onDone: _handleRestart,
          // If the live voice agent can't run (mic denied, network, ElevenLabs error), fall
          // back to the tap/voice co-creation flow, which generates + narrates a story via
          // POST /story. Graceful degradation instead of a dead end.
          onFallback: () => setState(() => _screen = 'cocreation'),
        ),
      'cocreation' => CoCreationScreen(
          childName: childName,
          onChoice: _handleChoice,
        ),
      'generating' => const Scaffold(
          backgroundColor: navy,
          body: Stack(
            children: [
              Positioned.fill(child: Starfield()),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('🌙', style: TextStyle(fontSize: 40)),
                    SizedBox(height: 20),
                    Text(
                      'Weaving your story…',
                      style: TextStyle(fontFamily: 'Lora', color: cream, fontSize: 16, letterSpacing: 1),
                    ),
                  ],
                ),
              ),
            ],
          ),
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
