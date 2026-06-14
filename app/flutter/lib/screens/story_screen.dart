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

import 'package:flutter_gemma/flutter_gemma.dart' show ModelType;

import '../services/asr_session.dart';
import '../services/local_llm.dart';
import '../services/settings_service.dart';
import '../services/story_safety.dart';
import '../services/tts_session.dart';
import '../widgets/starfield.dart';
import '../theme.dart';

enum _State { greeting, listening, thinking, narrating, paused, done, error }

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
    _startSession();
  }

  // Greet first (like an agent — Yarnia speaks before the child does), THEN load
  // STT in the background, THEN listen. The greeting must not wait behind the
  // slow Whisper model load, and it runs locally (no network).
  Future<void> _startSession() async {
    await _greet();
    if (!mounted) return;
    await _initStt(); // load STT after the greeting is spoken
    if (!mounted || _state != _State.greeting) return;
    setState(() => _state = _State.listening);
    await _startListening();
  }

  // Local, instant, spoken greeting. (Backend/LLM-personalized greeting is Phase 2;
  // the backend can't reach Nebula and we're going fully on-device anyway.)
  Future<void> _greet() async {
    final greeting = _localGreeting();
    setState(() {
      _state = _State.greeting;
      _currentSentence = greeting;
    });
    // Let the greeting be readable even if TTS is silent/instant.
    await Future.any([
      _speakLine(greeting),
      Future.delayed(const Duration(seconds: 8)), // safety cap
    ]);
    await Future.delayed(const Duration(milliseconds: 400));
  }

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

  @override
  void dispose() {
    _pulseController.dispose();
    _micLevel.dispose();
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
    setState(() => _state = _State.thinking);
    await _generateAndSpeak(text);
  }

  Future<void> _generateAndSpeak(String userInput) async {
    _thinkingForTurn = false;
    _lastInput = userInput;

    // The LLM runs on-device now (the Worker can't reach Nebula). Need a model.
    if (!widget.settings.anyLlmInstalled) {
      _showGenError('Download a storyteller model in Settings first.');
      return;
    }

    // 1. Build the prompt. Prefer the backend (it adds per-child memory/recall from
    //    InstantDB), but fall back to a local prompt so generation works even when
    //    the backend is unreachable — the whole point is to not depend on the network.
    String system;
    String user;
    final choice = userInput;
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
          .timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body) as Map<String, dynamic>;
        system = d['system'] as String? ?? _localStorySystem();
        user = d['user'] as String? ?? _localStoryUser(userInput);
      } else {
        debugPrint('StoryScreen: /story/prompt ${res.statusCode} → local prompt');
        system = _localStorySystem();
        user = _localStoryUser(userInput);
      }
    } catch (e) {
      debugPrint('StoryScreen: /story/prompt failed → local prompt: $e');
      system = _localStorySystem();
      user = _localStoryUser(userInput);
    }
    if (!mounted) return;

    // 2. Generate the story fully on-device.
    final engine = widget.settings.llmEngine;
    String storyText;
    try {
      await LocalLlm.instance.activate(modelType: ModelType.qwen, url: engine.url);
      final buf = StringBuffer();
      await for (final delta
          in LocalLlm.instance.generate(system: system, user: user)) {
        buf.write(delta);
      }
      storyText = buf.toString().trim();
    } catch (e) {
      debugPrint('StoryScreen: local LLM generation failed: $e');
      _showGenError('The storyteller model could not run on this device.');
      return;
    }
    if (!mounted) return;

    // 3. Safety-vet on-device; fall back to a guaranteed-safe story if needed.
    if (storyText.isEmpty || !isStorySafe(storyText)) {
      debugPrint('StoryScreen: story empty/unsafe → safe fallback');
      storyText = safeFallbackStory(widget.childName);
    }

    // 4. Narrate via the existing checkpoint loop, then persist (best-effort).
    _sentences = splitSentences(storyText);
    _cursor = 0;
    unawaited(_persistStory(choice: choice, text: storyText, system: system, user: user));
    await _narrateFrom(0);
  }

  // Local fallback prompt (mirrors api/src/prompt.ts core, without the recall layer
  // which needs the backend). Used when /story/prompt is unreachable.
  String _localStorySystem() {
    final n = widget.childName;
    return 'You are Yarnia, a warm, calm bedtime storyteller for the child named $n. '
        'The story must be gentle, soothing, and nonviolent — no peril, no scary or '
        'startling moments. The tone winds the child DOWN toward sleep. Keep it short '
        '(a handful of short paragraphs).';
  }

  String _localStoryUser(String choice) {
    final n = widget.childName;
    final parts = [
      'Tell $n a short bedtime story.',
      'Tonight $n chose this to be in the story: $choice.',
    ];
    final lang = switch (widget.settings.language) {
      'de' => 'German',
      'fr' => 'French',
      'es' => 'Spanish',
      _ => null,
    };
    if (lang != null) {
      parts.add('Tell the entire story in $lang. Every word must be in that language.');
    }
    return parts.join(' ');
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
    await _systemTts.setLanguage(widget.settings.locale);
    await _systemTts.setSpeechRate(0.5);

    while (_cursor < _sentences.length && !_interruptPending) {
      if (!mounted) return;
      final sentence = _sentences[_cursor];
      setState(() => _currentSentence = sentence);
      final completer = Completer<void>();
      _systemTts.setCompletionHandler(() => completer.complete());
      await _systemTts.speak(sentence);
      await completer.future;
      _cursor++; // advance AFTER the sentence finishes = checkpoint
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
        refWavPath: refWavPath,
      )) {
        if (!mounted) return;
        await playlist.add(AudioSource.uri(Uri.file(chunk.wavPath)));
        if (!playerStarted) {
          await _player.setAudioSource(playlist);
          // Show the sentence that is actually playing, not the one being synthesized.
          idxSub = _player.currentIndexStream.listen((i) {
            if (i == null || !mounted) return;
            final si = startIndex + i;
            if (si >= 0 && si < _sentences.length) {
              setState(() => _currentSentence = _sentences[si]);
            }
          });
          unawaited(_player.play());
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
        await _player.playerStateStream.firstWhere(
          (s) => s.processingState == ProcessingState.completed,
        );
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
    setState(() {
      _state = _State.listening;
      _committed = '';
      _partial = '';
      _decoding = false;
      _currentSentence = '';
      _isListening = false;
      _sentences = [];
      _cursor = 0;
      _interruptPending = false;
      _pendingHandsFreeUtterance = null;
    });
  }

  // ── Phase 2: conversation turn ────────────────────────────────────────────

  /// Send the child's utterance to the backend and apply the decision.
  Future<void> _sendTurn(String utterance) async {
    setState(() {
      _state = _State.thinking;
      _thinkingForTurn = true;
    });
    try {
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
      if (!mounted) return;
      if (res.statusCode != 200) {
        debugPrint('StoryScreen: /story/turn returned ${res.statusCode}');
        await _narrateFrom(_cursor);
        return;
      }
      final Map<String, dynamic> decision;
      try {
        decision = jsonDecode(res.body) as Map<String, dynamic>;
      } catch (e) {
        debugPrint('StoryScreen: failed to parse /story/turn response: $e');
        await _narrateFrom(_cursor);
        return;
      }

      final intent = decision['intent'] as String? ?? 'continue';
      final say = decision['say'] as String?;
      final resumeAt = (decision['resumeAt'] as num?)?.toInt() ?? _cursor;

      switch (intent) {
        case 'answer':
          if (say != null && say.isNotEmpty) await _speakLine(say);
          if (!mounted) return;
          // Show a "Continue?" prompt — the user can tap Continue or speak again.
          setState(() => _state = _State.paused);

        case 'revise':
          final revision = decision['revision'] as Map<String, dynamic>?;
          final newSentences = (revision?['sentences'] as List?)
              ?.map((e) => e as String)
              .toList();
          final fromSentence = (revision?['fromSentence'] as num?)?.toInt();
          if (newSentences != null && newSentences.isNotEmpty && fromSentence != null) {
            _sentences.replaceRange(fromSentence, _sentences.length, newSentences);
          }
          final revSay = say ?? "Okay, I changed that part — let me read it again.";
          await _speakLine(revSay);
          if (!mounted) return;
          await _narrateFrom(fromSentence ?? resumeAt);

        case 'continue':
        default:
          if (say != null && say.isNotEmpty) await _speakLine(say);
          if (!mounted) return;
          await _narrateFrom(resumeAt);
      }
    } catch (e) {
      debugPrint('StoryScreen: _sendTurn failed: $e');
      if (mounted) await _narrateFrom(_cursor);
    }
  }

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
      await _systemTts.setLanguage(widget.settings.locale);
      await _systemTts.setSpeechRate(0.5);
      final completer = Completer<void>();
      _systemTts.setCompletionHandler(() => completer.complete());
      await _systemTts.speak(line);
      await completer.future;
    } else {
      try {
        final support = await getApplicationSupportDirectory();
        final modelDir = p.join(support.path, engine.modelDir!);
        final refWavPath = _refWavForEngine(engine, modelDir);
        // Spawn a session if none exists yet (e.g. the greeting speaks before any
        // story narration has created one) — otherwise the line is silently dropped.
        var session = _ttsSession;
        if (session == null) {
          session = await TtsSession.spawn(
            kind: engine.kind!,
            modelDir: modelDir,
            outDir: support.path,
            seed: engine.seed,
          );
          _ttsSession = session;
        }
        final sc = StreamController<String>();
        sc.add(line);
        await sc.close();
        await for (final chunk in session.speakStream(sc.stream, refWavPath: refWavPath)) {
          if (!mounted) return;
          final playlist = ConcatenatingAudioSource(children: []);
          await playlist.add(AudioSource.uri(Uri.file(chunk.wavPath)));
          await _player.setAudioSource(playlist);
          await _player.play();
          await _player.playerStateStream.firstWhere(
            (s) => s.processingState == ProcessingState.completed,
          );
        }
      } catch (e) {
        debugPrint('StoryScreen: _speakLine pocket TTS failed: $e');
        // Fall back to system TTS for the line.
        await _systemTts.setLanguage(widget.settings.locale);
        await _systemTts.setSpeechRate(0.5);
        final completer = Completer<void>();
        _systemTts.setCompletionHandler(() => completer.complete());
        await _systemTts.speak(line);
        await completer.future;
      }
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
                  _State.greeting => _GreetingView(text: _currentSentence),
                  _State.error => _ErrorView(
                      message: _genError ?? 'Something went wrong.',
                      onRetry: _retryGeneration,
                      onStartOver: _restart,
                    ),
                  _State.listening => _ListeningView(
                      childName: widget.childName,
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
                    ),
                  _State.thinking => _ThinkingView(
                      childName: widget.childName, forTurn: _thinkingForTurn),
                  _State.narrating => _NarratingView(
                      sentence: _currentSentence,
                      onInterrupt: _requestInterrupt,
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
                      pulse: _pulse,
                      level: _micLevel,
                    ),
                  _State.done => _DoneView(
                      onAgain: _restart,
                      onGoodnight: widget.onDone,
                    ),
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ListeningView extends StatelessWidget {
  final String childName;
  final String transcript;
  final String status;
  final String? error;
  final bool speechReady;
  final Animation<double> pulse;
  final ValueNotifier<double> level;
  final VoidCallback onMicTap;
  final bool isListening;

  const _ListeningView({
    required this.childName,
    required this.transcript,
    required this.status,
    required this.error,
    required this.speechReady,
    required this.pulse,
    required this.level,
    required this.onMicTap,
    required this.isListening,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          "Who's in tonight's story,\n$childName?",
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
        GestureDetector(
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
        const SizedBox(height: 24),
        // Live caption — committed + interim transcript, so it is visible that
        // speech is being heard and what was understood.
        _Caption(
          text: transcript,
          status: status,
          emptyHint: isListening ? 'Listening…' : 'Tap to speak',
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

// Spoken-greeting screen: shows the greeting text while Yarnia says it, before
// auto-listening. Feels like an agent welcoming the child.
class _GreetingView extends StatelessWidget {
  final String text;
  const _GreetingView({required this.text});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('🌙', style: TextStyle(fontSize: 56)),
        const SizedBox(height: 28),
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
  const _ErrorView({
    required this.message,
    required this.onRetry,
    required this.onStartOver,
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

class _ThinkingView extends StatelessWidget {
  final String childName;
  final bool forTurn; // a mid-story conversation turn vs the initial story
  const _ThinkingView({required this.childName, this.forTurn = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('🌙', style: TextStyle(fontSize: 56)),
        const SizedBox(height: 24),
        Text(
          forTurn ? 'One moment…' : 'Weaving your story…',
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

  const _NarratingView({
    required this.sentence,
    required this.onInterrupt,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('🌙', style: TextStyle(fontSize: 56)),
        const SizedBox(height: 32),
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
  final Animation<double> pulse;
  final ValueNotifier<double> level;

  const _PausedView({
    required this.onContinue,
    required this.onStartOver,
    required this.onMicTap,
    required this.isListening,
    required this.speechReady,
    required this.transcript,
    required this.status,
    required this.pulse,
    required this.level,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('🌙', style: TextStyle(fontSize: 56)),
        const SizedBox(height: 24),
        const Text(
          'Paused',
          style: TextStyle(
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
          emptyHint: isListening ? 'Listening…' : 'Tap to talk, or Continue',
        ),
        const SizedBox(height: 32),
        _OutlineButton(label: 'Continue', onTap: onContinue),
        const SizedBox(height: 14),
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

class _DoneView extends StatelessWidget {
  final VoidCallback onAgain;
  final VoidCallback onGoodnight;

  const _DoneView({required this.onAgain, required this.onGoodnight});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('✨', style: TextStyle(fontSize: 56)),
        const SizedBox(height: 24),
        const Text(
          'Sweet dreams.',
          style: TextStyle(
            fontFamily: 'Fraunces',
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: cream,
          ),
        ),
        const SizedBox(height: 40),
        _OutlineButton(label: 'Another story', onTap: onAgain),
        const SizedBox(height: 14),
        TextButton(
          onPressed: onGoodnight,
          child: Text(
            'Goodnight 🌙',
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
