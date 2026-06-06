import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:elevenlabs_agents/elevenlabs_agents.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../widgets/starfield.dart';
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

  @override
  void initState() {
    super.initState();
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
          if (mounted) {
            setState(() => _status = ConversationStatus.connected);
            _dimController.forward();
          }
        },
        onDisconnect: (details) {
          if (mounted) setState(() => _done = true);
        },
        onModeChange: ({required mode}) {
          if (mounted) {
            setState(() => _isSpeaking = mode == ConversationMode.speaking);
          }
        },
        onError: (message, [context]) {
          debugPrint('ElevenLabs error: $message ${context ?? ""}');
          if (mounted) setState(() => _error = message);
        },
      ),
    );

    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      widget.onFallback();
      return;
    }

    try {
      final res = await http.get(
        Uri.parse('${widget.apiBase}/agent/session?childId=${widget.childId}'),
      );
      if (res.statusCode != 200) throw Exception('Session ${res.statusCode}');

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final signedUrl = data['signedUrl'] as String?;
      final agentId = data['agentId'] as String?;
      final dynamicVariables = data['dynamicVariables'] as Map<String, dynamic>?;

      if (signedUrl != null) {
        await _client.startSession(conversationToken: signedUrl);
      } else if (agentId != null) {
        await _client.startSession(
          agentId: agentId,
          dynamicVariables: dynamicVariables,
        );
      } else {
        throw Exception('No agentId or signedUrl in response');
      }
    } catch (e) {
      debugPrint('Agent bootstrap failed: $e');
      if (mounted) widget.onFallback();
    }
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
    if (_done) return _DoneScreen(onRestart: widget.onDone);

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
                        fontFamily: 'serif',
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
    final text = error != null
        ? 'Something went wrong'
        : status == ConversationStatus.disconnected
            ? 'Preparing your story…'
            : isSpeaking
                ? 'Yarnia is speaking…'
                : 'Your turn…';

    return Text(
      text,
      style: TextStyle(
        fontFamily: 'serif',
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

  const _DoneScreen({required this.onRestart});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: navy,
      body: Stack(
        children: [
          const Positioned.fill(child: Starfield()),
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('✨', style: TextStyle(fontSize: 56)),
                const SizedBox(height: 24),
                Text(
                  'The end.',
                  style: TextStyle(
                    fontFamily: 'serif',
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
                        fontFamily: 'serif',
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
