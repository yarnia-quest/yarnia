import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:elevenlabs_agents/elevenlabs_agents.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../api_config.dart';
import '../services/agent_session_prefetch.dart';
import '../widgets/starfield.dart';
import '../widgets/history_panel.dart';
import '../theme.dart';

class AgentScreen extends StatefulWidget {
  final String childName;
  final String childId;
  final String apiBase;
  final VoidCallback onDone;
  final VoidCallback onFallback;

  const AgentScreen({
    super.key,
    required this.childName,
    required this.childId,
    required this.apiBase,
    required this.onDone,
    required this.onFallback,
  });

  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends State<AgentScreen> with TickerProviderStateMixin {
  late ConversationClient _client;
  late AnimationController _orbController;
  late AnimationController _dimController;

  ConversationStatus _status = ConversationStatus.disconnected;
  bool _isSpeaking = false;
  bool _done = false;
  String? _error;
  String? _conversationId;
  bool _storySaving = false;

  @override
  void initState() {
    super.initState();
    // Hold the wakelock during the live conversation so the device does not lock and cut the
    // ElevenLabs audio. The screen dims to a dark orb (see _dimController) for the screen-off
    // feel; the wakelock is released in dispose().
    WakelockPlus.enable();

    _orbController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    _dimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _client = ConversationClient(
      callbacks: ConversationCallbacks(
        onConnect: ({required conversationId}) {
          _conversationId = conversationId;
          if (mounted) {
            setState(() => _status = ConversationStatus.connected);
            _dimController.forward();
          }
        },
        onDisconnect: (details) {
          _saveSession();
          if (mounted) setState(() => _done = true);
        },
        onModeChange: ({required mode}) {
          if (mounted) {
            setState(() => _isSpeaking = mode == ConversationMode.speaking);
          }
        },
        onError: (message, [context]) {
          // Log the raw SDK message for debugging, but show the parent a calm, plain message.
          debugPrint('ElevenLabs error: $message ${context ?? ""}');
          if (mounted) {
            setState(() => _error = "Yarnia's voice had a hiccup. Let's try again.");
          }
        },
      ),
    );

    _bootstrap();
  }

  // The story is persisted server-side by the ElevenLabs post-call webhook
  // (POST /agent/webhook), independent of this app — so the save survives the phone being
  // locked, killed, or offline at the end of the call. We don't trigger the save from here
  // anymore (that double-wrote the session); we just poll the child's sessions until the
  // webhook-written episode lands, showing a saving indicator meanwhile. If it hasn't landed
  // by the timeout the save still completes server-side; it simply appears next time history
  // opens.
  Future<void> _saveSession() async {
    if (_conversationId == null) return;
    if (mounted) setState(() => _storySaving = true);
    await _pollUntilSaved();
  }

  Future<void> _pollUntilSaved() async {
    // Capture the count BEFORE invalidating, so we wait for a genuinely NEW episode
    // (a returning child already has sessions; we must not treat those as "saved").
    final previousCount = getCachedSessions()?.length ?? 0;
    invalidateHistoryCache();
    // The webhook fires after ElevenLabs assembles the transcript, which can take a little
    // while. Poll with exponential backoff (2s, 3s, 5s, 8s, 12s, 12s...) up to a ~45s budget
    // instead of a flat 3s every tick — far fewer API calls when the webhook is quick, same
    // worst-case wait. The data is safe regardless; it just appears in history next open.
    var elapsedMs = 0;
    var delayMs = 2000;
    const budgetMs = 45000;
    const maxDelayMs = 12000;
    while (elapsedMs < budgetMs) {
      await Future.delayed(Duration(milliseconds: delayMs));
      elapsedMs += delayMs;
      delayMs = math.min(maxDelayMs, (delayMs * 1.6).round());
      try {
        final res = await http.get(
          Uri.parse('${widget.apiBase}/child/${widget.childId}/sessions'),
          headers: apiHeaders(),
        );
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          final sessions = (data['sessions'] as List).cast<Map<String, dynamic>>();
          if (sessions.length > previousCount) {
            warmHistoryCache(sessions);
            if (mounted) setState(() => _storySaving = false);
            return;
          }
        }
      } catch (e) {
        debugPrint('Poll failed: $e');
      }
    }
    if (mounted) setState(() => _storySaving = false);
  }

  bool _micDenied = false;

  Future<void> _bootstrap() async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      // iOS won't re-prompt once denied — the only recovery is Settings. Surface a button.
      if (mounted) {
        setState(() {
          _micDenied = true;
          _error = 'Microphone access is off. Turn it on in Settings, then tap Begin again.';
        });
      }
      return;
    }

    // Latency tuning (if turn-around feels slow):
    // 1. ElevenLabs dashboard > agent > LLM: use a faster model (e.g. gpt-4o-mini).
    // 2. ElevenLabs dashboard > agent > Turn detection: lower silence duration (ms)
    //    so the agent cuts in sooner after the user stops speaking. Too low = agent
    //    interrupts mid-sentence; ~300-500ms is a good starting point.
    // 3. Background noise fools VAD into keeping the mic "open" longer — test in
    //    a quiet environment before tuning the threshold.
    try {
      // Use the session warmed by GreetingScreen if it's ready; otherwise fetch now.
      // Either way the parse + connect path below is identical.
      final session = await (takeAgentSession(widget.childId) ?? _fetchSession());
      final signedUrl = session.signedUrl;
      final agentId = session.agentId;
      final dynamicVariables = session.dynamicVariables;

      if (signedUrl != null) {
        // Pass dynamicVariables here too: the signed URL only authenticates the
        // connection — child_name, greeting, fears, etc. still travel with the
        // session. Omitting them strips all personalization (the common path,
        // since the Worker returns a signedUrl whenever the EL key is set).
        await _client.startSession(
          conversationToken: signedUrl,
          dynamicVariables: dynamicVariables,
        );
      } else if (agentId != null) {
        await _client.startSession(
          agentId: agentId,
          dynamicVariables: dynamicVariables,
        );
      } else {
        throw Exception('No agentId or signedUrl in session response');
      }
    } catch (e) {
      debugPrint('Agent bootstrap failed: $e');
      if (mounted) setState(() => _error = 'Could not reach Yarnia. Check your connection and try again.');
    }
  }

  // Fallback when GreetingScreen didn't prefetch (e.g. a restarted session): same
  // GET /agent/session the prefetch uses, so the connect path stays identical.
  Future<AgentSessionData> _fetchSession() async {
    final res = await http.get(
      Uri.parse('${widget.apiBase}/agent/session?childId=${widget.childId}'),
      headers: apiHeaders(),
    );
    if (res.statusCode != 200) {
      throw Exception('Session ${res.statusCode}: ${res.body}');
    }
    return AgentSessionData.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  @override
  void dispose() {
    _client.dispose();
    _orbController.dispose();
    _dimController.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return _DoneScreen(onRestart: widget.onDone, childId: widget.childId, apiBase: widget.apiBase, storySaving: _storySaving);

    return Scaffold(
      backgroundColor: navy,
      body: Stack(
        children: [
          const Positioned.fill(child: Starfield()),

          AnimatedBuilder(
            animation: _dimController,
            builder: (_, __) => Positioned.fill(
              child: Container(
                color: Color.fromRGBO(18, 19, 42, (_dimController.value * 0.82).clamp(0, 1)),
              ),
            ),
          ),

          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _Orb(
                    controller: _orbController,
                    isSpeaking: _isSpeaking,
                    isConnecting: _status == ConversationStatus.disconnected,
                  ),
                  const SizedBox(height: 40),
                  _StatusLabel(
                    status: _status,
                    isSpeaking: _isSpeaking,
                    error: _error,
                  ),
                  if (_micDenied) ...[
                    const SizedBox(height: 20),
                    TextButton(
                      onPressed: () => openAppSettings(),
                      child: Text(
                        'Open Settings',
                        style: TextStyle(color: gold, fontFamily: 'Lora', fontSize: 16),
                      ),
                    ),
                  ] else if (_error != null) ...[
                    const SizedBox(height: 20),
                    TextButton(
                      onPressed: () {
                        setState(() => _error = null);
                        _bootstrap();
                      },
                      child: Text(
                        'Try again',
                        style: TextStyle(color: gold, fontFamily: 'serif', fontSize: 16),
                      ),
                    ),
                  ],
                  // Whenever the live voice agent can't run, offer the tap-to-choose
                  // co-creation fallback (works without the microphone).
                  if (_micDenied || _error != null) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: widget.onFallback,
                      child: Text(
                        'Tell me a story another way',
                        style: TextStyle(color: cream.withOpacity(0.6), fontFamily: 'Lora', fontSize: 14),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          if (_status == ConversationStatus.connected)
            Positioned(
              bottom: 48,
              left: 0,
              right: 0,
              child: Center(
                child: GestureDetector(
                  onTap: () async {
                    await _client.endSession();
                    if (mounted) setState(() => _done = true);
                  },
                  child: Opacity(
                    opacity: 0.25,
                    child: Text(
                      'end story',
                      style: TextStyle(
                        fontFamily: 'Lora',
                        color: cream,
                        fontSize: 13,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Orb ───────────────────────────────────────────────────────────────────────

class _Orb extends StatelessWidget {
  final AnimationController controller;
  final bool isSpeaking;
  final bool isConnecting;

  const _Orb({
    required this.controller,
    required this.isSpeaking,
    required this.isConnecting,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final t = isConnecting
            ? 0.5 + 0.5 * math.sin(controller.value * math.pi)
            : isSpeaking
                ? 0.5 + 0.5 * math.sin(controller.value * math.pi * 2)
                : 0.3 + 0.2 * math.sin(controller.value * math.pi);
        final scale = 1.0 + t * 0.18;
        final opacity = 0.5 + t * 0.5;

        final color = isConnecting
            ? navyLight
            : isSpeaking
                ? gold
                : cream;

        return Transform.scale(
          scale: scale,
          child: Opacity(
            opacity: opacity,
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [color, color.withAlpha(0)],
                  stops: const [0.0, 1.0],
                ),
                boxShadow: [
                  BoxShadow(
                    color: color.withAlpha((opacity * 80).toInt()),
                    blurRadius: 40,
                    spreadRadius: 10,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─── Status label ──────────────────────────────────────────────────────────────

class _StatusLabel extends StatelessWidget {
  final ConversationStatus status;
  final bool isSpeaking;
  final String? error;

  const _StatusLabel({
    required this.status,
    required this.isSpeaking,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    // Show the real error text (not an opaque "Something went wrong") so failures are
    // actionable on-device — e.g. the mic-permission message routes to Open Settings.
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          error!,
          style: TextStyle(fontFamily: 'Lora', color: cream.withAlpha(200), fontSize: 15),
          textAlign: TextAlign.center,
        ),
      );
    }

    final text = status == ConversationStatus.disconnected
        ? 'Travelling to Yarnia…'
        : isSpeaking
            ? 'Yarnia is speaking…'
            : 'Your turn…';

    return Text(
      text,
      style: TextStyle(
        fontFamily: 'Lora',
        color: cream.withAlpha(180),
        fontSize: 15,
        letterSpacing: 0.5,
      ),
      textAlign: TextAlign.center,
    );
  }
}

// ─── Done ──────────────────────────────────────────────────────────────────────

class _DoneScreen extends StatelessWidget {
  final VoidCallback onRestart;
  final String childId;
  final String apiBase;
  final bool storySaving;

  const _DoneScreen({required this.onRestart, required this.childId, required this.apiBase, required this.storySaving});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: navy,
      body: Stack(
        children: [
          const Positioned.fill(child: Starfield()),
          Positioned(
            top: 48,
            right: 20,
            child: IconButton(
              icon: Icon(Icons.history, color: cream.withAlpha(120), size: 22),
              onPressed: () => showHistoryPanel(context, childId: childId, apiBase: apiBase),
            ),
          ),
          if (storySaving)
            Positioned(
              bottom: 48,
              left: 0,
              right: 0,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12, height: 12,
                      child: CircularProgressIndicator(color: gold.withAlpha(160), strokeWidth: 1.5),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Saving story…',
                      style: TextStyle(fontFamily: 'Lora', color: cream.withAlpha(100), fontSize: 12, letterSpacing: 0.5),
                    ),
                  ],
                ),
              ),
            ),
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('✨', style: TextStyle(fontSize: 56)),
                const SizedBox(height: 24),
                Text(
                  'The end.',
                  style: TextStyle(
                    fontFamily: 'Lora',
                    fontSize: 28,
                    color: cream,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 48),
                GestureDetector(
                  onTap: onRestart,
                  child: Opacity(
                    opacity: 0.4,
                    child: Text(
                      'Another night →',
                      style: TextStyle(
                        fontFamily: 'Lora',
                        color: cream,
                        fontSize: 14,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
