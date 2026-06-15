import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:http/http.dart' as http;

import '../services/asr_session.dart';
import '../services/local_llm.dart';
import '../services/settings_service.dart';
import '../services/story_safety.dart';
import '../services/story_utils.dart';
import '../services/turn_decision.dart';
import '../services/tts_session.dart';
import 'settings_screen.dart';
import '../widgets/starfield.dart';
import '../theme.dart';

enum _State { setup, greeting, conversing, listening, thinking, narrating, paused, done, error }

class StoryScreen extends StatefulWidget {
  final String childName;
  final String childId;
  final String apiBase;
  final SettingsService settings;
  final Map<String, String> apiHeaders;
  final VoidCallback onDone;

  const StoryScreen({
    super.key,
    required this.childName,
    required this.childId,
    required this.apiBase,
    required this.settings,
    required this.apiHeaders,
    required this.onDone,
  });

  @override
  State<StoryScreen> createState() => _StoryScreenState();
}

class _StoryScreenState extends State<StoryScreen>
    with SingleTickerProviderStateMixin {
  // System STT
  final SpeechToText _speech = SpeechToText();
  bool _speechReady = false;

  // Whisper STT
  final AudioRecorder _recorder = AudioRecorder();
  AsrSession? _asrSession;
  StreamSubscription<AsrEvent>? _asrSub;
  StreamSubscription<Uint8List>? _audioSub;
  Uint8List _carry = Uint8List(0);

  // TTS + audio playback
  final AudioPlayer _player = AudioPlayer();
  final FlutterTts _systemTts = FlutterTts();
  TtsSession? _ttsSession;
  // Pre-spawn future: started at initState so the native library (libsherpa_onnx.so)
  // loads while the greeting text is displayed, not inside _speakLine where the cap
  // would race against the ~30s cold-start load time.
  Future<TtsSession>? _ttsSpawnFuture;

  late AnimationController _pulseController;
  late Animation<double> _pulse;

  _State _state = _State.greeting;
  // Transcript is split so a trailing empty partial can't wipe finalized text:
  // _committed holds decoded VAD segments; _partial is the live interim only.
  String _committed = '';
  String _partial = '';
  bool _decoding = false; // a segment finished and is being transcribed
  String? _sttError; // surfaced on screen if the recognizer fails to load
  bool _thinkingForTurn = false; // thinking state copy: turn vs initial story

  // Conversational turn-taking: when the child stops speaking, auto-advance
  // (no manual stop tap needed). Reset on each new speech, fires after silence.
  Timer? _silenceTimer;
  static const _silenceHold = Duration(milliseconds: 1600);

  // Generation error/retry so a slow/aborting backend never hangs on "weaving".
  String? _genError;
  String _lastInput = '';
  static const _genTimeout = Duration(seconds: 45);

  // First-run setup: download the on-device storyteller before anything else,
  // so the child never lands on a dead "not ready" screen.
  int? _setupProgress; // 0..100 while the model downloads
  String? _setupError;
  String _currentSentence = '';
  bool _isListening = false;

  // What the user has said so far (committed words + meaningful interim).
  String get _heard {
    final p = _partial == '(listening...)' ? '' : _partial;
    return '$_committed $p'.trim();
  }

  // Short status line under the caption so the user knows what is happening.
  String get _sttStatus {
    final engine = _usingWhisper ? 'Whisper' : 'System STT';
    if (_decoding) return '$engine · transcribing…';
    if (_isListening) return '$engine · listening';
    return engine;
  }
  // Live mic input level (0..1) for the listening indicator. A ValueNotifier so the
  // ring repaints on every audio frame without rebuilding the whole screen.
  final ValueNotifier<double> _micLevel = ValueNotifier(0);

  // Text entry fallback (for testing, Huawei, and users who prefer typing)
  final TextEditingController _textController = TextEditingController();

  // Conversational agent state
  bool _conversationMode = false; // true while chatting with the agent before story
  int _agentTurns = 0; // how many exchange turns have happened
  // Conversation history for cloud /agent/turn — list of {role, content} pairs.
  final List<Map<String, String>> _chatHistory = [];

  // Phase 1: checkpoint narration state
  List<String> _sentences = [];
  int _cursor = 0;           // index of the NEXT sentence to speak
  bool _interruptPending = false;

  // Phase 2b: hands-free VAD interrupt — stores the segment captured during
  // narration so it can be forwarded directly to _sendTurn without a re-listen.
  String? _pendingHandsFreeUtterance;

  bool get _usingWhisper =>
      widget.settings.effectiveSttEngine == SttEngine.whisperBase;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _pulse = Tween(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseController.repeat(reverse: true);
    _prewarmTts(); // fire-and-forget: loads libsherpa_onnx.so while greeting text shows
    _startSession();
  }

  // Spawns the TTS isolate immediately at startup so the native library cold-start
  // (~30s first run) happens in parallel with the greeting, not inside _speakLine.
  void _prewarmTts() {
    final engine = widget.settings.effectiveEngine;
    if (engine.isSystem || engine.kind == null || engine.modelDir == null) return;
    _ttsSpawnFuture = (() async {
      final support = await getApplicationSupportDirectory();
      final modelDir = p.join(support.path, engine.modelDir!);
      return TtsSession.spawn(
        kind: engine.kind!,
        modelDir: modelDir,
        outDir: support.path,
        seed: engine.seed,
      );
    })();
    _ttsSpawnFuture!.then((s) {
      if (mounted) _ttsSession = s;
      debugPrint('StoryScreen: TTS prewarm done (${engine.label})');
    }).catchError((Object e) {
      debugPrint('StoryScreen: TTS prewarm failed: $e');
    });
  }

  // Greet first (like an agent — Yarnia speaks before the child does), THEN load
  // STT in the background, THEN listen. The greeting must not wait behind the
  // slow Whisper model load, and it runs locally (no network).
  Future<void> _startSession() async {
    final agentCtx = await _greet();
    if (!mounted) return;
    await _initStt();
    if (!mounted || _state != _State.greeting) return;
    final engine = widget.settings.recommendedLlm;
    final llmReady = await LocalLlm.instance.modelFileReady(engine.url);
    if (llmReady) {
      await _startConversation(agentCtx);
    } else {
      setState(() => _state = _State.listening);
      await _startListening();
    }
  }

  Future<void> _startConversation([AgentContext? ctx]) async {
    _chatHistory.clear();
    // Seed the history with Yarnia's opening greeting so the cloud LLM has context.
    if (_currentSentence.isNotEmpty) {
      _chatHistory.add({'role': 'assistant', 'content': _currentSentence});
    }
    try {
      final engine = widget.settings.recommendedLlm;
      await LocalLlm.instance.activate(
        modelType: engine.modelType,
        fileType: engine.fileType,
        url: engine.url,
      );
      final system = buildAgentSystem(
        childName: widget.childName,
        lang: widget.settings.language,
        ctx: ctx,
      );
      await LocalLlm.instance.startChat(system, maxTokens: 256);
      setState(() {
        _conversationMode = true;
        _agentTurns = 0;
        _state = _State.listening;
      });
    } catch (e) {
      debugPrint('StoryScreen: startChat/activate failed: $e — falling back to direct listen');
      setState(() => _state = _State.listening);
    }
    await _startListening();
  }

  // Skip the conversation and generate a story from whatever topic was gathered.
  Future<void> _skipConversation() async {
    _conversationMode = false;
    await LocalLlm.instance.closeChat();
    final topic = _heard.isNotEmpty ? _heard : _defaultStoryTopic();
    setState(() => _state = _State.thinking);
    await _generateAndSpeak(topic);
  }

  String _defaultStoryTopic() => switch (widget.settings.language) {
    'de' => 'ein kleines Tier auf Abenteuersuche',
    'fr' => 'un petit animal en aventure',
    'es' => 'un pequeño animal en aventura',
    _ => 'a little animal on an adventure',
  };

  // Download the device-recommended storyteller model inline, then start.
  Future<void> _downloadStoryteller() async {
    if (_setupProgress != null) return;
    final engine = widget.settings.recommendedLlm;
    setState(() {
      _setupProgress = 0;
      _setupError = null;
    });
    try {
      await LocalLlm.instance.install(
        modelType: engine.modelType,
        fileType: engine.fileType,
        url: engine.url,
        onProgress: (p) {
          if (mounted) setState(() => _setupProgress = p);
        },
      );
      await widget.settings.markLlmInstalled(engine);
      await widget.settings.setLlmEngine(engine);
      if (!mounted) return;
      setState(() => _setupProgress = null);
      await _startSession(); // now installed → greet → listen
    } catch (e) {
      debugPrint('StoryScreen: storyteller download failed: $e');
      if (mounted) {
        setState(() {
          _setupError = 'Download failed: $e';
          _setupProgress = null;
        });
      }
    }
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsScreen(settings: widget.settings),
    ));
  }

  // Fetch a personalized LLM greeting from the API; fall back to a local template
  // if the network is unavailable or too slow. Returns both the greeting text and
  // optional agent context (child age/themes/fears/lastStory) for the conversation.
  Future<({String greeting, AgentContext? ctx})> _fetchGreeting() async {
    try {
      final res = await http.post(
        Uri.parse('${widget.apiBase}/greeting'),
        headers: {...widget.apiHeaders, 'content-type': 'application/json'},
        body: jsonEncode({
          'childId': widget.childId,
          'language': widget.settings.language,
        }),
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body) as Map<String, dynamic>;
        final text = (d['greeting'] as String?)?.trim() ?? '';
        AgentContext? ctx;
        if (d['agentContext'] is Map<String, dynamic>) {
          ctx = AgentContext.fromJson(d['agentContext'] as Map<String, dynamic>);
        }
        if (text.isNotEmpty) return (greeting: text, ctx: ctx);
      }
    } catch (e) {
      debugPrint('StoryScreen: /greeting failed → local fallback: $e');
    }
    return (greeting: _localGreeting(), ctx: null);
  }

  // Greet the child: show the animation immediately, then speak once we have text.
  Future<AgentContext?> _greet() async {
    setState(() {
      _state = _State.greeting;
      _currentSentence = '';
    });
    final result = await _fetchGreeting();
    if (!mounted) return null;
    setState(() => _currentSentence = result.greeting);
    final cap = widget.settings.effectiveEngine.isSystem
        ? const Duration(seconds: 9)
        : const Duration(seconds: 90);
    await Future.any([_speakLine(result.greeting), Future.delayed(cap)]);
    await Future.delayed(const Duration(milliseconds: 400));
    return result.ctx;
  }

  // Local fallback greeting used when /greeting is unreachable.
  String _localGreeting() {
    final n = widget.childName;
    switch (widget.settings.language) {
      case 'de':
        return 'Hallo $n! Schön, dass du da bist. Worum soll es in deiner Geschichte heute Abend gehen?';
      case 'fr':
        return "Bonjour $n! Je suis contente de te voir. De quoi veux-tu que parle ton histoire ce soir?";
      case 'es':
        return 'Hola $n! Me alegra que estés aquí. ¿De qué quieres que trate tu cuento esta noche?';
      default:
        return "Hello $n! I'm so glad you're here. What should tonight's story be about?";
    }
  }

  Future<void> _initStt() async {
    if (_usingWhisper) {
      await _initWhisper();
    } else {
      final ok = await _speech.initialize();
      if (mounted) setState(() => _speechReady = ok);
    }
  }

  Future<void> _initWhisper() async {
    try {
      final support = await getApplicationSupportDirectory();
      final modelDir = p.join(support.path,
          widget.settings.sttEngine.modelDir ?? 'sherpa-onnx-whisper-base');
      final vadPath = p.join(support.path, 'silero_vad.onnx');
      final session = await AsrSession.spawn(
        kind: 'whisperBase',
        dirs: {'model': modelDir, 'vad': vadPath},
        // Pin the decode language to the chosen one (auto-detect flip-flops
        // between languages per segment and wrecks accuracy).
        whisperLang: widget.settings.language,
      );
      if (!mounted) {
        session.dispose();
        return;
      }
      _asrSub = session.events.listen(_onAsrEvent);
      _asrSession = session;
      setState(() {
        _speechReady = true;
        _sttError = null;
      });
    } catch (e) {
      debugPrint('Whisper init failed, falling back to system STT: $e');
      // Surface it: a bad/missing model should be visible, not silent.
      final ok = await _speech.initialize();
      if (mounted) {
        setState(() {
          _speechReady = ok;
          _sttError = ok ? null : 'Whisper failed to load: $e';
        });
      }
    }
  }

  void _onAsrEvent(AsrEvent event) {
    if (!mounted) return;
    switch (event) {
      case AsrPartial(:final text):
        // Interim only — never touch _committed. An empty/placeholder partial
        // just clears the live text. (_decoding is managed by the stop path.)
        setState(() => _partial = text);
        // Speech is active again → don't auto-advance yet.
        if (text == '(listening...)') _silenceTimer?.cancel();
      case AsrSegment(:final text):
        final seg = text.trim();
        if (seg.isEmpty) return;
        // Phase 2b: during narration with hands-free enabled, a VAD segment is
        // treated as an interrupt utterance (>=2 words to dodge noise / TTS bleed).
        if (_state == _State.narrating &&
            widget.settings.handsFreeInterrupt &&
            seg.split(RegExp(r'\s+')).length >= 2) {
          setState(() => _interruptPending = true);
          _pendingHandsFreeUtterance = seg;
        } else {
          // Accumulate finalized segments; clear interim + decoding flag.
          setState(() {
            _committed = _committed.isEmpty ? seg : '$_committed $seg';
            _partial = '';
            _decoding = false;
          });
          // Conversational: once the child pauses, auto-advance (no stop tap).
          _armSilenceTimer();
        }
    }
  }

  // Auto-advance after the child stops talking for [_silenceHold]. Reset on each
  // new segment; cancelled when speech resumes or the mic is stopped manually.
  void _armSilenceTimer() {
    _silenceTimer?.cancel();
    if (!_isListening) return;
    _silenceTimer = Timer(_silenceHold, () {
      if (!mounted || !_isListening) return;
      if (_state == _State.listening) {
        _stopListeningAndGenerate();
      } else if (_state == _State.paused) {
        _stopPausedCaptureAndSend();
      }
    });
  }

  /// Submit typed text directly, bypassing the STT path entirely.
  Future<void> _submitTyped(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _textController.clear();
    if (_conversationMode) {
      setState(() { _state = _State.thinking; _thinkingForTurn = true; });
      await _doConverseTurn(trimmed);
    } else if (_state == _State.paused) {
      await _sendTurn(trimmed);
    } else {
      setState(() => _state = _State.thinking);
      await _generateAndSpeak(trimmed);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _micLevel.dispose();
    _textController.dispose();
    _silenceTimer?.cancel();
    _speech.stop();
    _asrSub?.cancel();
    _audioSub?.cancel();
    _recorder.dispose();
    _asrSession?.dispose();
    _player.dispose();
    _systemTts.stop();
    _ttsSession?.dispose();
    super.dispose();
  }

  // ── STT: start ────────────────────────────────────────────────────────────

  Future<void> _startListening() async {
    if (!_speechReady || _state != _State.listening) return;
    setState(() {
      _committed = '';
      _partial = '';
      _decoding = false;
      _isListening = true;
    });
    if (_usingWhisper && _asrSession != null) {
      await _startWhisperMic();
    } else {
      await _speech.listen(
        onResult: (r) => setState(() => _partial = r.recognizedWords),
        onSoundLevelChange: (level) =>
            _micLevel.value = ((level + 2) / 12).clamp(0.0, 1.0),
        listenOptions: SpeechListenOptions(
          listenFor: const Duration(seconds: 15),
          localeId: widget.settings.locale,
        ),
      );
    }
  }

  Future<void> _startWhisperMic() async {
    if (!await _recorder.hasPermission()) {
      if (mounted) setState(() => _isListening = false);
      return;
    }
    _carry = Uint8List(0);
    const sampleRate = 16000;
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: sampleRate,
      numChannels: 1,
    ));
    _audioSub = stream.listen((data) {
      var bytes = data;
      if (_carry.isNotEmpty) {
        bytes = Uint8List(_carry.length + data.length)
          ..setAll(0, _carry)
          ..setAll(_carry.length, data);
      }
      final usable = bytes.length & ~1;
      _carry = Uint8List.fromList(bytes.sublist(usable));
      if (usable == 0) return;
      final bd = ByteData.sublistView(bytes, 0, usable);
      final n = usable ~/ 2;
      final samples = Float32List(n);
      var sumSq = 0.0;
      for (var i = 0; i < n; i++) {
        final s = bd.getInt16(i * 2, Endian.little) / 32768.0;
        samples[i] = s;
        sumSq += s * s;
      }
      // RMS → 0..1 level for the on-screen mic indicator (scaled so normal speech
      // fills most of the ring; quiet room stays near zero).
      if (n > 0) {
        final rms = math.sqrt(sumSq / n);
        _micLevel.value = (rms * 6).clamp(0.0, 1.0);
      }
      _asrSession?.feed(samples);
    });
  }

  // ── STT: stop ────────────────────────────────────────────────────────────

  Future<void> _stopListeningAndGenerate() async {
    _silenceTimer?.cancel();
    setState(() {
      _isListening = false;
      _decoding = _usingWhisper; // a final segment may still be decoding
    });
    _micLevel.value = 0;
    if (_usingWhisper && _asrSession != null) {
      await _audioSub?.cancel();
      _audioSub = null;
      await _recorder.stop();
      _asrSession!.flush();
      // Give the isolate a moment to emit the final segment.
      await Future.delayed(const Duration(milliseconds: 400));
    } else {
      await _speech.stop();
    }
    if (mounted) setState(() => _decoding = false);
    final text = _heard;
    // Nothing was heard: stop and stay idle so the user can retry — do NOT loop
    // back into listening (that made the mic impossible to turn off).
    if (text.isEmpty) return;
    if (_conversationMode) {
      await _doConverseTurn(text);
    } else {
      setState(() => _state = _State.thinking);
      await _generateAndSpeak(text);
    }
  }

  // Run one agent conversation turn: send user utterance, parse reply, speak it.
  // If the reply signals the story is agreed ("READY:"), generate the story.
  // Call POST /agent/turn (cloud Qwen3). Returns the parsed response map on success,
  // null if the endpoint is unreachable or returns an error (triggering local fallback).
  Future<Map<String, dynamic>?> _tryCloudAgentTurn(String userMessage) async {
    try {
      final res = await http.post(
        Uri.parse('${widget.apiBase}/agent/turn'),
        headers: {...widget.apiHeaders, 'content-type': 'application/json'},
        body: jsonEncode({
          'childId': widget.childId,
          'language': widget.settings.language,
          'history': _chatHistory,
          'userMessage': userMessage,
        }),
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body) as Map<String, dynamic>;
        if (d['say'] is String) return d;
      }
    } catch (e) {
      debugPrint('StoryScreen: /agent/turn failed: $e');
    }
    return null;
  }

  // If still chatting, listen again. After 3 turns, force story generation.
  Future<void> _doConverseTurn(String userSaid) async {
    setState(() {
      _state = _State.thinking;
      _thinkingForTurn = true;
    });
    try {
      AgentParsed parsed;
      final cloudReply = await _tryCloudAgentTurn(userSaid);
      if (cloudReply != null) {
        // Cloud returned structured JSON — use it directly.
        final phase = cloudReply['phase'] as String? ?? 'chatting';
        final say = cloudReply['say'] as String? ?? '';
        final brief = cloudReply['brief'] as String?;
        parsed = (say: say, phase: phase, brief: brief);
        _chatHistory.add({'role': 'user', 'content': userSaid});
        _chatHistory.add({'role': 'assistant', 'content': say});
        debugPrint('StoryScreen: cloud agent turn: phase=$phase say=${say.substring(0, say.length.clamp(0, 120))}');
      } else {
        // Fall back to on-device LLM.
        final buf = StringBuffer();
        await for (final token in LocalLlm.instance.chatTurn(userSaid)) {
          buf.write(token);
          // Abort early if the model enters a repetition loop (same word 8+ times in a row)
          final current = buf.toString();
          if (current.length > 80) {
            final words = current.split(RegExp(r'[\s,.]+')).where((w) => w.length > 2).toList();
            if (words.length >= 8) {
              final last = words.last;
              if (words.sublist(words.length - 8).every((w) => w == last)) {
                debugPrint('StoryScreen: repetition loop detected — aborting generation');
                break;
              }
            }
          }
        }
        var response = buf.toString().trim();
        response = _derepeat(response);
        debugPrint('StoryScreen: local agent response: ${response.substring(0, response.length.clamp(0, 200))}');
        parsed = _parseAgentResponse(response);
      }
      _agentTurns++;
      if (!mounted) return;

      if (parsed.phase == 'ready' && parsed.brief != null) {
        // Transition: speak the line, then generate the story.
        setState(() { _state = _State.conversing; _currentSentence = parsed.say; });
        await _speakLine(parsed.say);
        if (!mounted) return;
        _conversationMode = false;
        await LocalLlm.instance.closeChat();
        setState(() => _state = _State.thinking);
        await _generateAndSpeak(parsed.brief!);
      } else if (_agentTurns >= 3) {
        // Max turns reached — use the whole transcript as the story topic.
        _conversationMode = false;
        await LocalLlm.instance.closeChat();
        final topic = userSaid.isNotEmpty ? userSaid : _defaultStoryTopic();
        setState(() => _state = _State.thinking);
        await _generateAndSpeak(topic);
      } else {
        // Still chatting — speak the reply and listen again.
        setState(() { _state = _State.conversing; _currentSentence = parsed.say; });
        await _speakLine(parsed.say);
        if (!mounted) return;
        setState(() {
          _state = _State.listening;
          _committed = '';
          _partial = '';
        });
        await _startListening();
      }
    } catch (e) {
      debugPrint('StoryScreen: _doConverseTurn failed: $e');
      if (!mounted) return;
      _conversationMode = false;
      await LocalLlm.instance.closeChat();
      setState(() => _state = _State.thinking);
      await _generateAndSpeak(userSaid.isNotEmpty ? userSaid : _defaultStoryTopic());
    }
  }

  AgentParsed _parseAgentResponse(String text) =>
      parseAgentResponse(text, widget.settings.language);

  // Remove trailing repetition artifacts from local LLM output.
  // Splits on sentences/commas, finds where a word starts repeating 4+ times, truncates.
  static String _derepeat(String text) {
    final words = text.split(RegExp(r'[\s,]+'));
    if (words.length < 8) return text;
    for (var i = words.length - 1; i >= 4; i--) {
      final w = words[i];
      if (w.length < 3) continue;
      var run = 1;
      while (i - run >= 0 && words[i - run] == w) run++;
      if (run >= 4) {
        // Truncate before the run and find the last sentence boundary
        final truncated = words.sublist(0, i - run + 1).join(' ');
        final lastPunct = truncated.lastIndexOf(RegExp(r'[.!?]'));
        return lastPunct > 0 ? truncated.substring(0, lastPunct + 1).trim() : truncated.trim();
      }
    }
    return text;
  }

  Future<void> _generateAndSpeak(String userInput) async {
    _thinkingForTurn = false;
    _lastInput = userInput;
    final choice = userInput;

    // 1. Try the cloud backend first (Qwen3 via DashScope — much better quality).
    //    Falls back to on-device only when the network is unavailable.
    String storyText;
    String system;
    String user;

    final cloudResult = await _tryCloudGenerate(userInput);
    if (cloudResult != null) {
      storyText = cloudResult.text;
      system = cloudResult.system;
      user = cloudResult.user;
    } else {
      // 2. Off-line fallback: on-device Qwen2.5-1.5B.
      if (!mounted) return;
      final localResult = await _tryLocalGenerate(userInput);
      if (localResult == null) return; // error already surfaced
      storyText = localResult.text;
      system = localResult.system;
      user = localResult.user;
    }
    if (!mounted) return;

    // 3. Safety check.
    if (!isStorySafe(storyText)) {
      debugPrint('StoryScreen: story failed safety check → safe fallback');
      storyText = safeFallbackStory(widget.childName);
    }

    // 4. Narrate and persist.
    _sentences = splitSentences(storyText);
    _cursor = 0;
    unawaited(_persistStory(choice: choice, text: storyText, system: system, user: user));
    await _narrateFrom(0);
  }

  // Cloud generation via /story/tell (Qwen3 on DashScope). Returns null on any failure.
  Future<({String text, String system, String user})?> _tryCloudGenerate(String userInput) async {
    try {
      final res = await http
          .post(
            Uri.parse('${widget.apiBase}/story/tell'),
            headers: {...widget.apiHeaders, 'content-type': 'application/json'},
            body: jsonEncode({
              'childId': widget.childId,
              'choice': userInput,
              'language': widget.settings.language,
            }),
          )
          .timeout(const Duration(seconds: 45));
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body) as Map<String, dynamic>;
        final text = (d['text'] as String?)?.trim() ?? '';
        if (text.isNotEmpty) {
          return (
            text: text,
            system: (d['system'] as String?) ?? _localStorySystem(),
            user: (d['user'] as String?) ?? _localStoryUser(userInput),
          );
        }
      }
      debugPrint('StoryScreen: /story/tell ${res.statusCode} → local fallback');
    } catch (e) {
      debugPrint('StoryScreen: /story/tell failed → local fallback: $e');
    }
    return null;
  }

  // Local generation via on-device Qwen2.5-1.5B. Returns null and surfaces error on failure.
  Future<({String text, String system, String user})?> _tryLocalGenerate(String userInput) async {
    // Try to get a personalized prompt from the backend first.
    String system;
    String user;
    try {
      final res = await http
          .post(
            Uri.parse('${widget.apiBase}/story/prompt'),
            headers: {...widget.apiHeaders, 'content-type': 'application/json'},
            body: jsonEncode({
              'childId': widget.childId,
              'choice': userInput,
              'language': widget.settings.language,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body) as Map<String, dynamic>;
        system = d['system'] as String? ?? _localStorySystem();
        user = d['user'] as String? ?? _localStoryUser(userInput);
      } else {
        system = _localStorySystem();
        user = _localStoryUser(userInput);
      }
    } catch (_) {
      system = _localStorySystem();
      user = _localStoryUser(userInput);
    }
    try {
      const engine = LlmEngine.qwen25_15b;
      await LocalLlm.instance.activate(
        modelType: engine.modelType,
        fileType: engine.fileType,
        url: engine.url,
      );
      final buf = StringBuffer();
      await for (final delta in LocalLlm.instance.generate(
        system: system,
        user: user,
        maxTokens: 1024,
      )) {
        buf.write(delta);
      }
      final text = cleanLlmOutput(buf.toString());
      if (text.isEmpty) {
        _showGenError(_l(widget.settings.language,
          en: 'The storyteller didn\'t generate a story. Please try again.',
          de: 'Yarnia konnte keine Geschichte erstellen. Bitte nochmal.',
          fr: 'Yarnia n\'a pas pu créer une histoire. Réessaie.',
          es: 'Yarnia no pudo crear una historia. Inténtalo de nuevo.',
        ));
        return null;
      }
      return (text: text, system: system, user: user);
    } catch (e) {
      debugPrint('StoryScreen: local LLM failed: $e');
      _showGenError(_l(widget.settings.language,
        en: 'The storyteller ran into a problem. Please try again.',
        de: 'Yarnia hatte ein Problem. Bitte nochmal.',
        fr: 'Yarnia a eu un problème. Réessaie.',
        es: 'Yarnia tuvo un problema. Inténtalo de nuevo.',
      ));
      return null;
    }
  }

  // Local fallback prompt (mirrors api/src/prompt.ts core, without the recall layer
  // which needs the backend). Used when /story/prompt is unreachable.
  String _localStorySystem() {
    final n = widget.childName;
    final langName = switch (widget.settings.language) {
      'de' => 'German',
      'fr' => 'French',
      'es' => 'Spanish',
      _ => 'English',
    };
    return 'You are Yarnia, a warm bedtime storyteller. '
        'Tell a story to $n in $langName. '
        'Write ONLY in $langName — not English, not any other language. '
        'The story must be gentle, soothing, and calm — no danger, no violence. '
        'The tone is cozy and dreamy, slowly winding $n toward sleep. '
        'Write 4–5 short flowing paragraphs. Give characters names and feelings. '
        'End with the character drifting peacefully to sleep. '
        'IMPORTANT: Write continuous prose — NO numbered lists, NO bullet points, NO headers. '
        'Write ONLY the story text itself, nothing else.';
  }

  String _localStoryUser(String choice) {
    final n = widget.childName;
    final langName = switch (widget.settings.language) {
      'de' => 'German',
      'fr' => 'French',
      'es' => 'Spanish',
      _ => 'English',
    };
    return 'Write a bedtime story in $langName for $n featuring: $choice. '
        'Flowing prose only. Begin the story immediately.';
  }

  // Best-effort save so per-child memory/recall keeps working next session.
  Future<void> _persistStory({
    required String choice,
    required String text,
    required String system,
    required String user,
  }) async {
    try {
      await http
          .post(
            Uri.parse('${widget.apiBase}/session/persist'),
            headers: {...widget.apiHeaders, 'content-type': 'application/json'},
            body: jsonEncode({
              'childId': widget.childId,
              'choice': choice,
              'text': text,
              'system': system,
              'user': user,
            }),
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('StoryScreen: session persist failed (non-fatal): $e');
    }
  }

  // Surface a generation failure with a retry instead of hanging on "thinking".
  void _showGenError(String message) {
    if (!mounted) return;
    setState(() {
      _genError = message;
      _state = _State.error;
    });
  }

  void _retryGeneration() {
    if (_lastInput.isEmpty) {
      _restart();
      return;
    }
    setState(() {
      _genError = null;
      _state = _State.thinking;
    });
    _generateAndSpeak(_lastInput);
  }

  // ── Phase 1: resumable narration loop ────────────────────────────────────

  /// Start (or resume) narration from sentence index [from].
  /// After the loop: if interrupted → send turn (hands-free) or pause; if finished → done.
  Future<void> _narrateFrom(int from) async {
    _cursor = from;
    _interruptPending = false;
    _pendingHandsFreeUtterance = null;
    setState(() => _state = _State.narrating);

    // Phase 2b: open the mic during narration when hands-free interrupt is enabled
    // and Whisper ASR is available. Hardware AEC should suppress Yarnia's own voice;
    // the 2-word debounce in _onAsrEvent is the software gate.
    if (widget.settings.handsFreeInterrupt &&
        _usingWhisper &&
        _asrSession != null) {
      try {
        await _startWhisperMic();
      } catch (e) {
        debugPrint('StoryScreen: hands-free mic start failed: $e');
        // Non-fatal: narration proceeds, hands-free is just unavailable.
      }
    }

    final engine = widget.settings.effectiveEngine;
    if (engine.isSystem) {
      await _narrateSystemFrom();
    } else {
      await _narratePocketFrom(engine);
    }

    // Stop the hands-free mic after narration ends (whether interrupted or done).
    if (widget.settings.handsFreeInterrupt && _usingWhisper) {
      try {
        await _audioSub?.cancel();
        _audioSub = null;
        await _recorder.stop();
      } catch (e) {
        debugPrint('StoryScreen: hands-free mic stop failed: $e');
      }
    }

    if (!mounted) return;
    if (_interruptPending) {
      // Phase 2b: if a hands-free utterance was captured, send it directly as a turn.
      final hfUtterance = _pendingHandsFreeUtterance;
      if (hfUtterance != null && hfUtterance.isNotEmpty) {
        _pendingHandsFreeUtterance = null;
        await _sendTurn(hfUtterance);
      } else {
        // Manual interrupt (button): show the paused view for user input.
        setState(() => _state = _State.paused);
      }
    } else if (_cursor >= _sentences.length) {
      setState(() => _state = _State.done);
    }
  }

  Future<void> _narrateSystemFrom() async {
    while (_cursor < _sentences.length && !_interruptPending) {
      if (!mounted) return;
      final sentence = _sentences[_cursor];
      setState(() => _currentSentence = sentence);
      await _speakSystemTts(sentence);
      _cursor++;
    }
  }

  Future<void> _narratePocketFrom(TtsEngine engine) async {
    final support = await getApplicationSupportDirectory();
    final modelDir = p.join(support.path, engine.modelDir!);
    final refWavPath = _refWavForEngine(engine, modelDir);
    // Playlist item i corresponds to sentence (startIndex + i). We resolve _cursor
    // from actual playback position, NOT synthesis (Pocket synthesizes ahead of audio).
    final startIndex = _cursor;

    _ttsSession?.dispose();
    _ttsSession = null;
    _ttsSpawnFuture = null; // prewarm consumed; next _speakLine will spawn fresh
    StreamSubscription<int?>? idxSub;
    try {
      final session = await TtsSession.spawn(
        kind: engine.kind!,
        modelDir: modelDir,
        outDir: support.path,
        seed: engine.seed,
      );
      _ttsSession = session;

      final remaining = _sentences.sublist(startIndex);
      final sentenceController = StreamController<String>();

      // Feed sentences into the stream, stopping feeding when an interrupt is pending.
      // The worker may still finish synthesizing the current sentence even after we stop
      // feeding — that is intentional (finish-current-sentence semantics).
      () async {
        for (final s in remaining) {
          if (_interruptPending) break;
          sentenceController.add(s);
        }
        await sentenceController.close();
      }();

      final playlist = ConcatenatingAudioSource(children: []);
      bool playerStarted = false;

      await for (final chunk in session.speakStream(
        sentenceController.stream,
        speed: widget.settings.ttsSpeed,
        refWavPath: refWavPath,
      )) {
        if (!mounted) return;
        await playlist.add(AudioSource.uri(Uri.file(chunk.wavPath)));
        if (!playerStarted) {
          await _player.stop(); // reset any prior state
          await _player.setVolume(1.0);
          await _player.setAudioSource(playlist, initialIndex: 0, initialPosition: Duration.zero);
          // Log errors so we can see if playback fails.
          _player.playbackEventStream.listen(
            (_) {},
            onError: (e, st) => debugPrint('StoryScreen: just_audio error: $e'),
          );
          // Show the sentence that is actually playing, not the one being synthesized.
          idxSub = _player.currentIndexStream.listen((i) {
            if (i == null || !mounted) return;
            final si = startIndex + i;
            if (si >= 0 && si < _sentences.length) {
              setState(() => _currentSentence = _sentences[si]);
            }
          });
          debugPrint('StoryScreen: starting audio playback wav=${chunk.wavPath}');
          await _player.play();
          playerStarted = true;
        }
        if (_interruptPending) {
          session.cancel();
          break;
        }
      }

      if (!playerStarted) return; // nothing synthesized

      if (_interruptPending) {
        // Finish-current-sentence: let the audible sentence complete, then stop.
        final heardIdx = _player.currentIndex ?? 0;
        await _player.playerStateStream.firstWhere((s) =>
            (_player.currentIndex ?? heardIdx) > heardIdx ||
            s.processingState == ProcessingState.completed);
        await _player.pause();
        _cursor = (startIndex + heardIdx + 1).clamp(0, _sentences.length);
      } else {
        // Ran through every sentence — wait for playback to drain.
        await _player.playerStateStream.firstWhere((s) {
          debugPrint('StoryScreen: player state=${s.processingState} playing=${s.playing}');
          return s.processingState == ProcessingState.completed ||
              s.processingState == ProcessingState.idle;
        });
        _cursor = _sentences.length;
      }
    } catch (e) {
      debugPrint('StoryScreen pocket TTS failed: $e');
      // Fall back to system TTS on error.
      await _narrateSystemFrom();
    } finally {
      await idxSub?.cancel();
    }
  }

  String? _refWavForEngine(TtsEngine engine, String modelDir) {
    final filename = switch (engine) {
      TtsEngine.pocketDe => 'juergen.wav',
      TtsEngine.pocketFr => 'developpeuse.wav',
      TtsEngine.pocketEs => 'juergen.wav',
      TtsEngine.pocketEn => 'bria.wav',
      _ => null,
    };
    if (filename == null) return null;
    final path = p.join(modelDir, 'test_wavs', filename);
    return File(path).existsSync() ? path : null;
  }

  // ── Interrupt + pause ────────────────────────────────────────────────────

  /// Signal that we want to pause after the current sentence finishes.
  void _requestInterrupt() {
    setState(() => _interruptPending = true);
  }

  void _restart() {
    _player.stop();
    _systemTts.stop();
    _conversationMode = false;
    _agentTurns = 0;
    LocalLlm.instance.closeChat().ignore();
    setState(() {
      _committed = '';
      _partial = '';
      _decoding = false;
      _currentSentence = '';
      _isListening = false;
      _sentences = [];
      _cursor = 0;
      _interruptPending = false;
      _pendingHandsFreeUtterance = null;
      _genError = null;
      _state = _State.listening;
    });
    _startListening();
  }

  // ── Phase 2: conversation turn ────────────────────────────────────────────

  /// Send the child's utterance to the on-device LLM (when active) or the backend,
  /// then apply the decision to the narration (continue / answer / revise).
  Future<void> _sendTurn(String utterance) async {
    setState(() {
      _state = _State.thinking;
      _thinkingForTurn = true;
    });
    try {
      final decision = LocalLlm.instance.hasActiveModel
          ? await _sendTurnLocal(utterance)
          : await _sendTurnApi(utterance);
      if (!mounted) return;
      await _applyTurnDecision(decision);
    } catch (e) {
      debugPrint('StoryScreen: _sendTurn failed: $e');
      if (mounted) await _narrateFrom(_cursor);
    }
  }

  Future<TurnDecision> _sendTurnLocal(String utterance) async {
    final prompt = buildLocalTurnPrompt(
      childName: widget.childName,
      sentences: _sentences,
      cursor: _cursor,
      utterance: utterance,
      language: widget.settings.language,
    );
    final buf = StringBuffer();
    await for (final token in LocalLlm.instance.generate(
      system: prompt.system,
      user: prompt.user,
      maxTokens: 512,
      temperature: 0.3,
    )) {
      buf.write(token);
    }
    debugPrint('StoryScreen: local turn raw: ${buf.toString().substring(0, buf.length.clamp(0, 300))}');
    return interpretTurn(buf.toString(), _cursor, _sentences.length);
  }

  Future<TurnDecision> _sendTurnApi(String utterance) async {
    final res = await http
        .post(
          Uri.parse('${widget.apiBase}/story/turn'),
          headers: {...widget.apiHeaders, 'content-type': 'application/json'},
          body: jsonEncode({
            'childId': widget.childId,
            'sentences': _sentences,
            'cursor': _cursor,
            'utterance': utterance,
            'language': widget.settings.language,
          }),
        )
        .timeout(_genTimeout);
    if (res.statusCode != 200) {
      debugPrint('StoryScreen: /story/turn returned ${res.statusCode}');
      return TurnDecision.safe(_cursor);
    }
    try {
      return interpretTurn(res.body, _cursor, _sentences.length);
    } catch (e) {
      debugPrint('StoryScreen: failed to parse /story/turn response: $e');
      return TurnDecision.safe(_cursor);
    }
  }

  Future<void> _applyTurnDecision(TurnDecision decision) async {
    switch (decision.intent) {
      case TurnIntent.answer:
        if (decision.say != null && decision.say!.isNotEmpty) {
          await _speakLine(decision.say!);
        }
        if (!mounted) return;
        setState(() => _state = _State.paused);

      case TurnIntent.revise:
        final rev = decision.revision;
        if (rev != null && rev.sentences.isNotEmpty) {
          _sentences.replaceRange(rev.fromSentence, _sentences.length, rev.sentences);
        }
        final revSay = decision.say ?? _defaultReviseLine(widget.settings.language);
        await _speakLine(revSay);
        if (!mounted) return;
        await _narrateFrom(rev?.fromSentence ?? decision.resumeAt);

      case TurnIntent.continueStory:
        if (decision.say != null && decision.say!.isNotEmpty) {
          await _speakLine(decision.say!);
        }
        if (!mounted) return;
        await _narrateFrom(decision.resumeAt);
    }
  }

  String _defaultReviseLine(String lang) => switch (lang) {
    'de' => 'Okay, ich ändere das — lass mich neu lesen.',
    'fr' => 'D\'accord, je change ça — laisse-moi relire.',
    'es' => 'Bien, lo cambio — deja que vuelva a leer.',
    _ => 'Okay, I changed that part — let me read it again.',
  };

  // ── Paused: capture one utterance from the child, then send it as a turn ────

  /// Open the mic while paused so the child can ask a question or change the story.
  Future<void> _startPausedCapture() async {
    if (!_speechReady || _isListening) return;
    setState(() {
      _committed = '';
      _partial = '';
      _decoding = false;
      _isListening = true;
    });
    if (_usingWhisper && _asrSession != null) {
      await _startWhisperMic();
    } else {
      await _speech.listen(
        onResult: (r) => setState(() => _partial = r.recognizedWords),
        listenOptions: SpeechListenOptions(
          listenFor: const Duration(seconds: 15),
          localeId: widget.settings.locale,
        ),
      );
    }
  }

  /// Stop the paused-mode mic and send whatever was said as a conversation turn.
  Future<void> _stopPausedCaptureAndSend() async {
    _silenceTimer?.cancel();
    setState(() {
      _isListening = false;
      _decoding = _usingWhisper;
    });
    _micLevel.value = 0;
    if (_usingWhisper && _asrSession != null) {
      await _audioSub?.cancel();
      _audioSub = null;
      await _recorder.stop();
      _asrSession!.flush();
      await Future.delayed(const Duration(milliseconds: 400));
    } else {
      await _speech.stop();
    }
    if (mounted) setState(() => _decoding = false);
    final text = _heard;
    if (text.isEmpty) return; // nothing said — stay paused
    await _sendTurn(text);
  }

  /// Resume narration from the paused view, stopping the mic first if it is open.
  Future<void> _resumeFromPaused() async {
    _silenceTimer?.cancel();
    if (_isListening) {
      setState(() => _isListening = false);
      await _audioSub?.cancel();
      _audioSub = null;
      try {
        await _recorder.stop();
      } catch (e) {
        debugPrint('StoryScreen: recorder stop on resume failed: $e');
      }
      await _speech.stop();
    }
    await _narrateFrom(_cursor);
  }

  /// Speak a single short line using the active TTS engine.
  Future<void> _speakLine(String line) async {
    final engine = widget.settings.effectiveEngine;
    if (engine.isSystem) {
      await _speakSystemTts(line);
    } else {
      try {
        final support = await getApplicationSupportDirectory();
        final modelDir = p.join(support.path, engine.modelDir!);
        final refWavPath = _refWavForEngine(engine, modelDir);
        // Reuse prewarm future if the session isn't ready yet (avoids spawning a
        // second isolate and racing with the first cold-start load).
        var session = _ttsSession;
        if (session == null) {
          if (_ttsSpawnFuture != null) {
            session = await _ttsSpawnFuture!;
          } else {
            session = await TtsSession.spawn(
              kind: engine.kind!,
              modelDir: modelDir,
              outDir: support.path,
              seed: engine.seed,
            );
          }
          _ttsSession = session;
        }
        // Use session.speak() so sentence splitting and stream setup are handled
        // correctly (no await on sc.close() which can race with the listener).
        // Use AudioSource.uri (not Concatenating) for simpler completion semantics.
        await for (final chunk in session.speak(line, speed: widget.settings.ttsSpeed, refWavPath: refWavPath)) {
          if (!mounted) return;
          debugPrint('StoryScreen: _speakLine chunk ${chunk.index} wav=${chunk.wavPath}');
          await _player.stop();
          await _player.setVolume(1.0);
          await _player.setAudioSource(AudioSource.uri(Uri.file(chunk.wavPath)));
          await _player.play();
          debugPrint('StoryScreen: _speakLine playing, waiting for completion');
          await _player.playerStateStream.firstWhere((s) {
            debugPrint('StoryScreen: _speakLine state=${s.processingState}');
            return s.processingState == ProcessingState.completed ||
                s.processingState == ProcessingState.idle;
          }).timeout(const Duration(seconds: 30), onTimeout: () {
            debugPrint('StoryScreen: _speakLine player timeout — audio done or stalled');
            return _player.playerState;
          });
          debugPrint('StoryScreen: _speakLine chunk done');
        }
        debugPrint('StoryScreen: _speakLine all chunks done');
      } catch (e) {
        debugPrint('StoryScreen: _speakLine on-device TTS failed: $e');
        // Fall back to system TTS with a timeout so a broken/blocked TTS
        // engine can't hang the entire app (happens on GrapheneOS).
        await _speakSystemTts(line);
      }
    }
  }

  /// Speak via system TTS. Includes a 6s timeout because on GrapheneOS the
  /// speech services app is BLOCKED by AppsFilter — the completion callback
  /// never fires, which would hang the caller indefinitely without the cap.
  Future<void> _speakSystemTts(String line) async {
    try {
      await _systemTts.setLanguage(widget.settings.locale);
      await _systemTts.setSpeechRate(0.5);
      final completer = Completer<void>();
      _systemTts.setCompletionHandler(() {
        if (!completer.isCompleted) completer.complete();
      });
      await _systemTts.speak(line);
      await completer.future.timeout(
        const Duration(seconds: 6),
        onTimeout: () {
          debugPrint('StoryScreen: system TTS timed out (likely blocked on GrapheneOS)');
        },
      );
    } catch (e) {
      debugPrint('StoryScreen: system TTS failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: navy,
      body: Stack(
        children: [
          const Positioned.fill(child: Starfield()),
          SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: switch (_state) {
                  _State.setup => _SetupView(
                      engineLabel: widget.settings.recommendedLlm.label,
                      sizeMb: widget.settings.recommendedLlm.sizeMb,
                      progress: _setupProgress,
                      error: _setupError,
                      onDownload: _downloadStoryteller,
                      onSettings: _openSettings,
                    ),
                  _State.greeting => _GreetingView(text: _currentSentence, pulse: _pulse),
                  _State.conversing => _ConversationView(
                      text: _currentSentence,
                      language: widget.settings.language,
                      pulse: _pulse,
                      onSkip: _skipConversation,
                    ),
                  _State.error => _ErrorView(
                      message: _genError ?? 'Something went wrong.',
                      onRetry: _retryGeneration,
                      onStartOver: _restart,
                      onSettings: _openSettings,
                    ),
                  _State.listening => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ListeningView(
                          childName: widget.childName,
                          language: widget.settings.language,
                          transcript: _heard,
                          status: _sttStatus,
                          error: _sttError,
                          speechReady: _speechReady,
                          pulse: _pulse,
                          level: _micLevel,
                          onMicTap: _isListening
                              ? _stopListeningAndGenerate
                              : _startListening,
                          isListening: _isListening,
                          textController: _textController,
                          onTextSubmit: _submitTyped,
                        ),
                        if (_conversationMode) ...[
                          const SizedBox(height: 20),
                          TextButton(
                            onPressed: _skipConversation,
                            child: Text(
                              switch (widget.settings.language) {
                                'de' => 'Einfach erzählen →',
                                'fr' => 'Juste raconter →',
                                'es' => 'Solo contar →',
                                _ => 'Just tell me a story →',
                              },
                              style: TextStyle(
                                fontFamily: 'Lora',
                                color: cream.withOpacity(0.45),
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  _State.thinking => _ThinkingView(
                      childName: widget.childName,
                      language: widget.settings.language,
                      forTurn: _thinkingForTurn),
                  _State.narrating => _NarratingView(
                      sentence: _currentSentence,
                      onInterrupt: _requestInterrupt,
                      pulse: _pulse,
                    ),
                  _State.paused => _PausedView(
                      onContinue: _resumeFromPaused,
                      onStartOver: _restart,
                      onMicTap: _isListening
                          ? _stopPausedCaptureAndSend
                          : _startPausedCapture,
                      isListening: _isListening,
                      speechReady: _speechReady,
                      transcript: _heard,
                      status: _sttStatus,
                      language: widget.settings.language,
                      pulse: _pulse,
                      level: _micLevel,
                      textController: _textController,
                      onTextSubmit: _submitTyped,
                    ),
                  _State.done => _DoneView(
                      onAgain: _restart,
                      onGoodnight: widget.onDone,
                      language: widget.settings.language,
                    ),
                },
              ),
            ),
          ),
          // Always-reachable settings (so the child/parent is never stuck).
          Positioned(
            top: 8,
            right: 8,
            child: SafeArea(
              child: IconButton(
                icon: Icon(Icons.settings_outlined, color: cream.withOpacity(0.6)),
                onPressed: _openSettings,
                tooltip: 'Settings',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Locale-aware label helper — keeps switch expressions off widget build methods.
String _l(String lang, {required String en, required String de, required String fr, required String es}) =>
    switch (lang) { 'de' => de, 'fr' => fr, 'es' => es, _ => en };

class _ListeningView extends StatelessWidget {
  final String childName;
  final String language;
  final String transcript;
  final String status;
  final String? error;
  final bool speechReady;
  final Animation<double> pulse;
  final ValueNotifier<double> level;
  final VoidCallback onMicTap;
  final bool isListening;
  final TextEditingController textController;
  final Future<void> Function(String) onTextSubmit;

  const _ListeningView({
    required this.childName,
    required this.language,
    required this.transcript,
    required this.status,
    required this.error,
    required this.speechReady,
    required this.pulse,
    required this.level,
    required this.onMicTap,
    required this.isListening,
    required this.textController,
    required this.onTextSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          _l(language,
            en: "Who's in tonight's story,\n$childName?",
            de: 'Worum soll deine Geschichte gehen,\n$childName?',
            fr: 'De quoi parlera ton histoire,\n$childName?',
            es: '¿De qué tratará tu historia,\n$childName?',
          ),
          style: const TextStyle(
            fontFamily: 'Fraunces',
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: cream,
            height: 1.4,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 40),
        Semantics(
          label: 'talk_button',
          button: true,
          child: GestureDetector(
          onTap: speechReady ? onMicTap : null,
          child: SizedBox(
            width: 88,
            height: 88,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Voice-reactive halo: grows and brightens with mic input so the
                // user can see it is actually hearing them.
                ValueListenableBuilder<double>(
                  valueListenable: level,
                  builder: (_, lvl, __) => Container(
                    width: 88 + lvl * 44,
                    height: 88 + lvl * 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: gold.withOpacity(isListening ? 0.10 + lvl * 0.30 : 0),
                    ),
                  ),
                ),
                AnimatedBuilder(
                  animation: pulse,
                  builder: (_, __) => Transform.scale(
                    scale: isListening ? pulse.value : 1.0,
                    child: Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: gold.withOpacity(isListening ? 0.4 : 0.1),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),
                Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: navyLight,
                    border: Border.all(color: gold, width: 1.5),
                  ),
                  child: Center(
                    child: Text(
                      isListening ? '⏹' : '🎙',
                      style: const TextStyle(fontSize: 28),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        ),
        const SizedBox(height: 24),
        // Live caption — committed + interim transcript, so it is visible that
        // speech is being heard and what was understood.
        _Caption(
          text: transcript,
          status: status,
          emptyHint: isListening
              ? _l(language, en: 'Listening…', de: 'Ich höre…', fr: "J'écoute…", es: 'Escuchando…')
              : _l(language, en: 'Tap to speak', de: 'Tippe zum Sprechen', fr: 'Appuie pour parler', es: 'Toca para hablar'),
        ),
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(
            error!,
            style: const TextStyle(
              fontFamily: 'Lora',
              color: Color(0xFFE2A0A0),
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 20),
        _TextEntryField(
          controller: textController,
          language: language,
          onSubmit: onTextSubmit,
        ),
      ],
    );
  }
}

// Shared live-caption block: the heard text (or a hint) plus a small status line.
class _Caption extends StatelessWidget {
  final String text;
  final String status;
  final String emptyHint;
  const _Caption(
      {required this.text, required this.status, required this.emptyHint});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Text(
            text.isNotEmpty ? '"$text"' : emptyHint,
            style: TextStyle(
              fontFamily: 'Lora',
              color: text.isNotEmpty ? gold : cream.withOpacity(0.4),
              fontSize: text.isNotEmpty ? 16 : 13,
              fontStyle:
                  text.isNotEmpty ? FontStyle.italic : FontStyle.normal,
              letterSpacing: text.isNotEmpty ? 0 : 1,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          status,
          style: TextStyle(
            fontFamily: 'Lora',
            color: cream.withOpacity(0.35),
            fontSize: 11,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

// Yarnia's spoken reply during the pre-story conversation, with a skip backstop.
class _ConversationView extends StatelessWidget {
  final String text;
  final String language;
  final Animation<double> pulse;
  final VoidCallback onSkip;
  const _ConversationView({required this.text, required this.language, required this.pulse, required this.onSkip});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('🌙', style: TextStyle(fontSize: 56)),
        const SizedBox(height: 20),
        AnimatedBuilder(
          animation: pulse,
          builder: (_, __) {
            final t = pulse.value;
            final h1 = 6 + (t - 1.0) * 56;
            final h2 = 6 + ((t - 1.0) * 0.6) * 56;
            final h3 = 6 + ((t - 1.0) * 0.85) * 56;
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _AudioBar(height: h1),
                const SizedBox(width: 5),
                _AudioBar(height: h3),
                const SizedBox(width: 5),
                _AudioBar(height: h2),
                const SizedBox(width: 5),
                _AudioBar(height: h1 * 0.7),
                const SizedBox(width: 5),
                _AudioBar(height: h3 * 1.1),
              ],
            );
          },
        ),
        const SizedBox(height: 20),
        Text(
          text.isEmpty ? '…' : text,
          style: const TextStyle(
            fontFamily: 'Fraunces',
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: cream,
            height: 1.5,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 28),
        TextButton(
          onPressed: onSkip,
          child: Text(
            _l(language, en: 'Skip →', de: 'Überspringen →', fr: 'Passer →', es: 'Saltar →'),
            style: TextStyle(
              fontFamily: 'Lora',
              color: cream.withOpacity(0.35),
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }
}

// Spoken-greeting screen: shows the greeting text while Yarnia says it, before
// auto-listening. Feels like an agent welcoming the child.
class _GreetingView extends StatelessWidget {
  final String text;
  final Animation<double> pulse;
  const _GreetingView({required this.text, required this.pulse});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('🌙', style: TextStyle(fontSize: 56)),
        const SizedBox(height: 20),
        // Audio bars — shows Yarnia is loading her voice / speaking.
        AnimatedBuilder(
          animation: pulse,
          builder: (_, __) {
            final t = pulse.value;
            final h1 = 6 + (t - 1.0) * 56;
            final h2 = 6 + ((t - 1.0) * 0.6) * 56;
            final h3 = 6 + ((t - 1.0) * 0.85) * 56;
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _AudioBar(height: h1),
                const SizedBox(width: 5),
                _AudioBar(height: h3),
                const SizedBox(width: 5),
                _AudioBar(height: h2),
                const SizedBox(width: 5),
                _AudioBar(height: h1 * 0.7),
                const SizedBox(width: 5),
                _AudioBar(height: h3 * 1.1),
              ],
            );
          },
        ),
        const SizedBox(height: 20),
        Text(
          text.isEmpty ? '…' : text,
          style: const TextStyle(
            fontFamily: 'Fraunces',
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: cream,
            height: 1.5,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

// Generation failed/timed out — offer retry instead of hanging on "thinking".
class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onStartOver;
  final VoidCallback onSettings;
  const _ErrorView({
    required this.message,
    required this.onRetry,
    required this.onStartOver,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('🌫️', style: TextStyle(fontSize: 48)),
        const SizedBox(height: 20),
        Text(
          message,
          style: TextStyle(
            fontFamily: 'Lora',
            color: cream.withOpacity(0.8),
            fontSize: 16,
            height: 1.4,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 28),
        _OutlineButton(label: 'Try again', onTap: onRetry),
        const SizedBox(height: 14),
        TextButton(
          onPressed: onSettings,
          child: Text('Open Settings',
              style: TextStyle(
                  fontFamily: 'Lora', color: gold.withOpacity(0.9), fontSize: 14)),
        ),
        TextButton(
          onPressed: onStartOver,
          child: Text(
            'Start over',
            style: TextStyle(
              fontFamily: 'Lora',
              color: cream.withOpacity(0.5),
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }
}

// First-run setup: download the on-device storyteller before the session starts.
class _SetupView extends StatelessWidget {
  final String engineLabel;
  final int sizeMb;
  final int? progress; // 0..100 while downloading
  final String? error;
  final VoidCallback onDownload;
  final VoidCallback onSettings;
  const _SetupView({
    required this.engineLabel,
    required this.sizeMb,
    required this.progress,
    required this.error,
    required this.onDownload,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final downloading = progress != null;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('🌙', style: TextStyle(fontSize: 56)),
        const SizedBox(height: 24),
        const Text(
          'Getting Yarnia ready',
          style: TextStyle(
            fontFamily: 'Fraunces',
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: cream,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        Text(
          downloading
              ? 'Downloading the storyteller… $progress%'
              : 'Yarnia tells stories right on your device. '
                  'Download her storyteller ($engineLabel, ~$sizeMb MB) once to begin.',
          style: TextStyle(
            fontFamily: 'Lora',
            color: cream.withOpacity(0.7),
            fontSize: 14,
            height: 1.5,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        if (downloading)
          SizedBox(
            width: 200,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress! > 0 ? progress! / 100.0 : null,
                minHeight: 5,
                backgroundColor: cream.withOpacity(0.15),
                valueColor: const AlwaysStoppedAnimation<Color>(gold),
              ),
            ),
          )
        else
          _OutlineButton(label: 'Download & start', onTap: onDownload),
        if (error != null) ...[
          const SizedBox(height: 16),
          Text(error!,
              style: const TextStyle(
                  fontFamily: 'Lora', color: Color(0xFFE2A0A0), fontSize: 12),
              textAlign: TextAlign.center),
        ],
        const SizedBox(height: 14),
        TextButton(
          onPressed: onSettings,
          child: Text('More options in Settings',
              style: TextStyle(
                  fontFamily: 'Lora', color: cream.withOpacity(0.5), fontSize: 13)),
        ),
      ],
    );
  }
}

class _ThinkingView extends StatelessWidget {
  final String childName;
  final String language;
  final bool forTurn; // a mid-story conversation turn vs the initial story
  const _ThinkingView({required this.childName, required this.language, this.forTurn = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('🌙', style: TextStyle(fontSize: 56)),
        const SizedBox(height: 24),
        Text(
          forTurn
            ? _l(language, en: 'One moment…', de: 'Einen Moment…', fr: 'Un instant…', es: 'Un momento…')
            : _l(language, en: 'Weaving your story…', de: 'Deine Geschichte wird gewoben…', fr: 'Ton histoire se tisse…', es: 'Tejiendo tu historia…'),
          style: TextStyle(
            fontFamily: 'Lora',
            color: cream.withOpacity(0.7),
            fontSize: 16,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 16),
        const CircularProgressIndicator(color: gold, strokeWidth: 1.5),
      ],
    );
  }
}

class _NarratingView extends StatelessWidget {
  final String sentence;
  final VoidCallback onInterrupt;
  final Animation<double> pulse;

  const _NarratingView({
    required this.sentence,
    required this.onInterrupt,
    required this.pulse,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('🌙', style: TextStyle(fontSize: 56)),
        const SizedBox(height: 24),
        // Audio bars — three bars pulsing at different phases to show narration is active.
        AnimatedBuilder(
          animation: pulse,
          builder: (_, __) {
            final t = pulse.value; // 1.0 → 1.25
            final h1 = 6 + (t - 1.0) * 56; // tallest
            final h2 = 6 + ((t - 1.0) * 0.6) * 56;
            final h3 = 6 + ((t - 1.0) * 0.85) * 56;
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _AudioBar(height: h1),
                const SizedBox(width: 5),
                _AudioBar(height: h3),
                const SizedBox(width: 5),
                _AudioBar(height: h2),
                const SizedBox(width: 5),
                _AudioBar(height: h1 * 0.7),
                const SizedBox(width: 5),
                _AudioBar(height: h3 * 1.1),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          child: Text(
            sentence,
            key: ValueKey(sentence),
            style: const TextStyle(
              fontFamily: 'Lora',
              color: cream,
              fontSize: 17,
              fontStyle: FontStyle.italic,
              height: 1.6,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 40),
        GestureDetector(
          onTap: onInterrupt,
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: navyLight,
              border: Border.all(color: gold.withOpacity(0.6), width: 1.5),
            ),
            child: const Center(
              child: Text('⏸', style: TextStyle(fontSize: 22)),
            ),
          ),
        ),
      ],
    );
  }
}

class _AudioBar extends StatelessWidget {
  final double height;
  const _AudioBar({required this.height});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 4,
      height: height.clamp(6.0, 36.0),
      decoration: BoxDecoration(
        color: gold.withOpacity(0.7),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// Shown when narration is paused mid-story.
/// Phase 1: resume or start over.
/// Phase 2: also captures an utterance and sends a turn.
class _PausedView extends StatelessWidget {
  final VoidCallback onContinue;
  final VoidCallback onStartOver;
  final VoidCallback onMicTap;
  final bool isListening;
  final bool speechReady;
  final String transcript;
  final String status;
  final String language;
  final Animation<double> pulse;
  final ValueNotifier<double> level;
  final TextEditingController textController;
  final Future<void> Function(String) onTextSubmit;

  const _PausedView({
    required this.onContinue,
    required this.onStartOver,
    required this.onMicTap,
    required this.isListening,
    required this.speechReady,
    required this.transcript,
    required this.status,
    required this.language,
    required this.pulse,
    required this.level,
    required this.textController,
    required this.onTextSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('🌙', style: TextStyle(fontSize: 56)),
        const SizedBox(height: 24),
        Text(
          _l(language, en: 'Paused', de: 'Pausiert', fr: 'En pause', es: 'Pausado'),
          style: const TextStyle(
            fontFamily: 'Fraunces',
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: cream,
          ),
        ),
        const SizedBox(height: 24),
        // Mic: tap to ask a question or change the story; tap again to send.
        GestureDetector(
          onTap: speechReady ? onMicTap : null,
          child: SizedBox(
            width: 80,
            height: 80,
            child: Stack(
              alignment: Alignment.center,
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: level,
                  builder: (_, lvl, __) => Container(
                    width: 80 + lvl * 40,
                    height: 80 + lvl * 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: gold.withOpacity(isListening ? 0.10 + lvl * 0.30 : 0),
                    ),
                  ),
                ),
                AnimatedBuilder(
                  animation: pulse,
                  builder: (_, __) => Transform.scale(
                    scale: isListening ? pulse.value : 1.0,
                    child: Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: gold.withOpacity(isListening ? 0.4 : 0.1),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),
                Container(
                  width: 62,
                  height: 62,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: navyLight,
                    border: Border.all(color: gold, width: 1.5),
                  ),
                  child: Center(
                    child: Text(
                      isListening ? '⏹' : '🎙',
                      style: const TextStyle(fontSize: 24),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _Caption(
          text: transcript,
          status: status,
          emptyHint: isListening
              ? _l(language, en: 'Listening…', de: 'Ich höre…', fr: "J'écoute…", es: 'Escuchando…')
              : _l(language, en: 'Tap to talk, or Continue', de: 'Tippe oder Weiter', fr: 'Appuie ou Continuer', es: 'Toca o Continuar'),
        ),
        const SizedBox(height: 16),
        _TextEntryField(
          controller: textController,
          language: language,
          onSubmit: onTextSubmit,
        ),
        const SizedBox(height: 24),
        _OutlineButton(
          label: _l(language, en: 'Continue', de: 'Weiter', fr: 'Continuer', es: 'Continuar'),
          onTap: onContinue,
        ),
        const SizedBox(height: 14),
        TextButton(
          onPressed: onStartOver,
          child: Text(
            _l(language, en: 'Start over', de: 'Nochmal', fr: 'Recommencer', es: 'Empezar de nuevo'),
            style: TextStyle(
              fontFamily: 'Lora',
              color: cream.withOpacity(0.5),
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }
}

class _DoneView extends StatelessWidget {
  final VoidCallback onAgain;
  final VoidCallback onGoodnight;
  final String language;

  const _DoneView({required this.onAgain, required this.onGoodnight, required this.language});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('✨', style: TextStyle(fontSize: 56)),
        const SizedBox(height: 24),
        Text(
          _l(language, en: 'Sweet dreams.', de: 'Träum süß.', fr: 'Fais de beaux rêves.', es: 'Que sueñes bonito.'),
          style: const TextStyle(
            fontFamily: 'Fraunces',
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: cream,
          ),
        ),
        const SizedBox(height: 40),
        _OutlineButton(
          label: _l(language, en: 'Another story', de: 'Noch eine Geschichte', fr: 'Une autre histoire', es: 'Otra historia'),
          onTap: onAgain,
        ),
        const SizedBox(height: 14),
        TextButton(
          onPressed: onGoodnight,
          child: Text(
            _l(language, en: 'Goodnight 🌙', de: 'Gute Nacht 🌙', fr: 'Bonne nuit 🌙', es: 'Buenas noches 🌙'),
            style: TextStyle(
              fontFamily: 'Lora',
              color: cream.withAlpha(140),
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }
}

// Text entry alternative to voice — always visible, subtle. Works on any device
// (no mic needed) and makes automated testing straightforward.
class _TextEntryField extends StatelessWidget {
  final TextEditingController controller;
  final String language;
  final Future<void> Function(String) onSubmit;

  const _TextEntryField({
    required this.controller,
    required this.language,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final hint = _l(language,
      en: 'or type here…',
      de: 'oder hier tippen…',
      fr: 'ou écrire ici…',
      es: 'o escribe aquí…',
    );
    return TextField(
      controller: controller,
      style: TextStyle(fontFamily: 'Lora', color: cream, fontSize: 14),
      textInputAction: TextInputAction.send,
      onSubmitted: onSubmit,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(fontFamily: 'Lora', color: cream.withAlpha(60), fontSize: 13),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide(color: cream.withAlpha(40), width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide(color: gold.withAlpha(160), width: 1.5),
        ),
        suffixIcon: IconButton(
          icon: Icon(Icons.send_rounded, color: gold.withAlpha(140), size: 18),
          onPressed: () => onSubmit(controller.text),
        ),
      ),
    );
  }
}

class _OutlineButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _OutlineButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 48),
        decoration: BoxDecoration(
          border: Border.all(color: gold, width: 1.5),
          borderRadius: BorderRadius.circular(40),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontFamily: 'Lora',
            color: gold,
            fontSize: 16,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }
}
