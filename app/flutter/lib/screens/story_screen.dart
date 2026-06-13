import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:http/http.dart' as http;

import '../services/settings_service.dart';
import '../services/tts_session.dart';
import '../widgets/starfield.dart';
import '../theme.dart';

enum _State { listening, thinking, narrating, done }

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
  final SpeechToText _speech = SpeechToText();
  final AudioPlayer _player = AudioPlayer();
  final FlutterTts _systemTts = FlutterTts();

  late AnimationController _pulseController;
  late Animation<double> _pulse;

  _State _state = _State.listening;
  String _transcript = '';
  String _currentSentence = '';
  bool _speechReady = false;
  TtsSession? _ttsSession;

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
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    final ok = await _speech.initialize();
    if (mounted) setState(() => _speechReady = ok);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _speech.stop();
    _player.dispose();
    _systemTts.stop();
    _ttsSession?.dispose();
    super.dispose();
  }

  Future<void> _startListening() async {
    if (!_speechReady || _state != _State.listening) return;
    setState(() => _transcript = '');
    await _speech.listen(
      onResult: (r) => setState(() => _transcript = r.recognizedWords),
      listenOptions: SpeechListenOptions(
        listenFor: const Duration(seconds: 15),
        localeId: widget.settings.locale,
      ),
    );
  }

  Future<void> _stopListeningAndGenerate() async {
    await _speech.stop();
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
      setState(() => _state = _State.narrating);
      await _speakStory(storyText);
    } catch (e) {
      debugPrint('StoryScreen: generate/speak failed: $e');
      if (mounted) setState(() => _state = _State.listening);
    }
  }

  Future<void> _speakStory(String text) async {
    final engine = widget.settings.effectiveEngine;
    if (engine.isSystem) {
      await _speakSystem(text);
    } else {
      await _speakPocket(text, engine);
    }
    if (mounted) setState(() => _state = _State.done);
  }

  Future<void> _speakSystem(String text) async {
    await _systemTts.setLanguage(widget.settings.locale);
    await _systemTts.setSpeechRate(0.5);
    final sentences = splitSentences(text);
    for (final sentence in sentences) {
      if (!mounted) return;
      setState(() => _currentSentence = sentence);
      final completer = Completer<void>();
      _systemTts.setCompletionHandler(() => completer.complete());
      await _systemTts.speak(sentence);
      await completer.future;
    }
  }

  Future<void> _speakPocket(String text, TtsEngine engine) async {
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

      final playlist = ConcatenatingAudioSource(children: []);
      bool playerStarted = false;

      await for (final chunk in session.speak(text, refWavPath: refWavPath)) {
        if (!mounted) return;
        setState(() => _currentSentence = chunk.text);
        await playlist.add(AudioSource.uri(Uri.file(chunk.wavPath)));
        if (!playerStarted) {
          await _player.setAudioSource(playlist);
          unawaited(_player.play());
          playerStarted = true;
        }
      }
      // Wait for playback to complete.
      await _player.playerStateStream.firstWhere(
        (s) => s.processingState == ProcessingState.completed,
      );
    } catch (e) {
      debugPrint('StoryScreen pocket TTS failed: $e');
      // Fall back to system TTS on error.
      await _speakSystem(text);
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

  void _restart() {
    _player.stop();
    _systemTts.stop();
    setState(() {
      _state = _State.listening;
      _transcript = '';
      _currentSentence = '';
    });
    _startListening();
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
                      onMicTap: _speech.isListening
                          ? _stopListeningAndGenerate
                          : _startListening,
                      isListening: _speech.isListening,
                    ),
                  _State.thinking => _ThinkingView(childName: widget.childName),
                  _State.narrating => _NarratingView(sentence: _currentSentence),
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
  const _NarratingView({required this.sentence});

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
