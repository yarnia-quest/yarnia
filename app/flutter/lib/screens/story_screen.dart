import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
import '../services/settings_service.dart';
import '../services/tts_session.dart';
import '../widgets/starfield.dart';
import '../theme.dart';

enum _State { listening, thinking, narrating, paused, done }

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

  _State _state = _State.listening;
  String _transcript = '';
  String _currentSentence = '';
  bool _isListening = false;

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
    _initStt();
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
      );
      if (!mounted) {
        session.dispose();
        return;
      }
      _asrSub = session.events.listen(_onAsrEvent);
      _asrSession = session;
      setState(() => _speechReady = true);
    } catch (e) {
      debugPrint('Whisper init failed, falling back to system STT: $e');
      final ok = await _speech.initialize();
      if (mounted) setState(() => _speechReady = ok);
    }
  }

  void _onAsrEvent(AsrEvent event) {
    if (!mounted) return;
    switch (event) {
      case AsrPartial(:final text):
        setState(() => _transcript = text);
      case AsrSegment(:final text):
        // Phase 2b: during narration with hands-free enabled, a VAD segment is
        // treated as an interrupt utterance — finish the current sentence then
        // process the turn. Debounced to segments with at least 2 words to
        // reduce false triggers from background noise and Yarnia's own voice
        // (hardware AEC should suppress self-triggering; this is an extra gate).
        if (_state == _State.narrating &&
            widget.settings.handsFreeInterrupt &&
            text.trim().split(RegExp(r'\s+')).length >= 2) {
          setState(() => _interruptPending = true);
          // Store the segment so _enterPaused can pass it directly to _sendTurn
          // instead of waiting for a re-listen.
          _pendingHandsFreeUtterance = text.trim();
        } else {
          // Normal listening mode: accumulate segments as transcript.
          setState(() => _transcript = _transcript.isEmpty
              ? text
              : '$_transcript $text');
        }
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
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
    setState(() { _transcript = ''; _isListening = true; });
    if (_usingWhisper && _asrSession != null) {
      await _startWhisperMic();
    } else {
      await _speech.listen(
        onResult: (r) => setState(() => _transcript = r.recognizedWords),
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
      for (var i = 0; i < n; i++) {
        samples[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
      }
      _asrSession?.feed(samples);
    });
  }

  // ── STT: stop ────────────────────────────────────────────────────────────

  Future<void> _stopListeningAndGenerate() async {
    setState(() => _isListening = false);
    if (_usingWhisper && _asrSession != null) {
      await _audioSub?.cancel();
      _audioSub = null;
      await _recorder.stop();
      _asrSession!.flush();
      // Give the isolate a moment to emit the final segment.
      await Future.delayed(const Duration(milliseconds: 300));
    } else {
      await _speech.stop();
    }
    final text = _transcript.trim();
    if (text.isEmpty) {
      _startListening();
      return;
    }
    setState(() => _state = _State.thinking);
    await _generateAndSpeak(text);
  }

  Future<void> _generateAndSpeak(String userInput) async {
    try {
      final res = await http.post(
        Uri.parse('${widget.apiBase}/story'),
        headers: {...widget.apiHeaders, 'content-type': 'application/json'},
        body: jsonEncode({
          'childId': widget.childId,
          'choice': userInput,
          'language': widget.settings.language,
        }),
      );
      if (!mounted) return;
      if (res.statusCode != 200) {
        setState(() => _state = _State.listening);
        return;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final storyText = data['text'] as String? ?? '';
      if (storyText.isEmpty) {
        setState(() => _state = _State.listening);
        return;
      }
      // Build the sentence checkpoint list and start narrating from the top.
      _sentences = splitSentences(storyText);
      _cursor = 0;
      await _narrateFrom(0);
    } catch (e) {
      debugPrint('StoryScreen: generate/speak failed: $e');
      if (mounted) setState(() => _state = _State.listening);
    }
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

    _ttsSession?.dispose();
    try {
      final session = await TtsSession.spawn(
        kind: engine.kind!,
        modelDir: modelDir,
        outDir: support.path,
        seed: engine.seed,
      );
      _ttsSession = session;

      final remaining = _sentences.sublist(_cursor);
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

      // _cursor tracks "synthesized" position, which is acceptable for checkpointing.
      // If precise "spoken" position is needed, advance off _player.currentIndex instead.
      await for (final chunk in session.speakStream(
        sentenceController.stream,
        refWavPath: refWavPath,
      )) {
        if (!mounted) return;
        setState(() => _currentSentence = chunk.text);
        await playlist.add(AudioSource.uri(Uri.file(chunk.wavPath)));
        if (!playerStarted) {
          await _player.setAudioSource(playlist);
          unawaited(_player.play());
          playerStarted = true;
        }
        _cursor++; // advance as each chunk is synthesized
        if (_interruptPending) {
          session.cancel();
          break;
        }
      }

      // Wait for playback to complete if we ran through all sentences.
      if (!_interruptPending && playerStarted) {
        await _player.playerStateStream.firstWhere(
          (s) => s.processingState == ProcessingState.completed,
        );
      }
    } catch (e) {
      debugPrint('StoryScreen pocket TTS failed: $e');
      // Fall back to system TTS on error.
      await _narrateSystemFrom();
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
      _transcript = '';
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
    setState(() => _state = _State.thinking);
    try {
      final res = await http.post(
        Uri.parse('${widget.apiBase}/story/turn'),
        headers: {...widget.apiHeaders, 'content-type': 'application/json'},
        body: jsonEncode({
          'childId': widget.childId,
          'sentences': _sentences,
          'cursor': _cursor,
          'utterance': utterance,
          'language': widget.settings.language,
        }),
      );
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
        final session = _ttsSession;
        if (session != null) {
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
                  _State.listening => _ListeningView(
                      childName: widget.childName,
                      transcript: _transcript,
                      speechReady: _speechReady,
                      pulse: _pulse,
                      onMicTap: _isListening
                          ? _stopListeningAndGenerate
                          : _startListening,
                      isListening: _isListening,
                    ),
                  _State.thinking => _ThinkingView(childName: widget.childName),
                  _State.narrating => _NarratingView(
                      sentence: _currentSentence,
                      onInterrupt: _requestInterrupt,
                    ),
                  _State.paused => _PausedView(
                      onContinue: () => _narrateFrom(_cursor),
                      onStartOver: _restart,
                      onUtterance: _sendTurn,
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
  final bool speechReady;
  final Animation<double> pulse;
  final VoidCallback onMicTap;
  final bool isListening;

  const _ListeningView({
    required this.childName,
    required this.transcript,
    required this.speechReady,
    required this.pulse,
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
        if (transcript.isNotEmpty)
          Text(
            '"$transcript"',
            style: const TextStyle(
              fontFamily: 'Lora',
              color: gold,
              fontSize: 15,
              fontStyle: FontStyle.italic,
            ),
            textAlign: TextAlign.center,
          )
        else
          Text(
            isListening ? 'Listening…' : 'Tap to speak',
            style: TextStyle(
              fontFamily: 'Lora',
              color: cream.withOpacity(0.4),
              fontSize: 13,
              letterSpacing: 1,
            ),
          ),
      ],
    );
  }
}

class _ThinkingView extends StatelessWidget {
  final String childName;
  const _ThinkingView({required this.childName});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('🌙', style: TextStyle(fontSize: 56)),
        const SizedBox(height: 24),
        Text(
          'Weaving your story…',
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
  final void Function(String utterance) onUtterance;

  const _PausedView({
    required this.onContinue,
    required this.onStartOver,
    required this.onUtterance,
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
        const SizedBox(height: 8),
        Text(
          'Say something or tap Continue',
          style: TextStyle(
            fontFamily: 'Lora',
            color: cream.withOpacity(0.5),
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 40),
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
