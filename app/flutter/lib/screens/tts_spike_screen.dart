// Spike 1a (plans/post-hackathon-soul-and-direction.md): can this phone tell a
// story fully offline? Trimmed to the engines that match the product's
// language needs (EN + DE, ideally TR): Piper voices per language, Kyutai
// Pocket TTS (EN export; natural story prosody + zero-shot voice cloning from
// a ~20 s reference recording), plus the platform/system TTS (Google / device
// voices, the accessibility stack) as the comparison fallback the plan doc
// describes.
//
// Piper synthesis runs in a worker isolate (lib/services/tts_session.dart),
// sentence by sentence: playback starts after the first sentence while the
// rest still generates. Metrics show time-to-first-audio and effective RTF.
//
// Reached only when built with --dart-define=TTS_SPIKE=true. Piper models are
// NOT bundled; push each model dir once to /data/local/tmp via adb, then copy
// it into the app's files/ with
// `adb shell run-as quest.yarnia.yarnia cp -r /data/local/tmp/<dir> files/`.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../services/tts_session.dart';

const _sampleText =
    'Once upon a time, in a quiet town by the sea, a little fox named Lumi '
    'could not fall asleep. The moon was full, the waves were soft, and '
    'somewhere far away an owl was telling the night its favorite secret. '
    'So Lumi closed her eyes and listened, and the secret slowly became a dream.';

const _sampleTextDe =
    'Es war einmal ein kleiner Fuchs namens Lumi, der in einer stillen Stadt '
    'am Meer nicht einschlafen konnte. Der Mond war voll, die Wellen waren '
    'sanft, und irgendwo weit weg erzaehlte eine Eule der Nacht ihr liebstes '
    'Geheimnis. Also schloss Lumi die Augen und lauschte, und das Geheimnis '
    'wurde langsam zu einem Traum.';


const _sampleTextTr =
    'Bir zamanlar, deniz kenarındaki sessiz bir kasabada, Lumi adında küçük '
    'bir tilki bir türlü uyuyamıyordu. Ay dolunaydı, dalgalar yumuşacıktı ve '
    'uzaklarda bir yerde bir baykuş geceye en sevdiği sırrını anlatıyordu. '
    'Lumi gözlerini kapatıp dinledi ve o sır yavaş yavaş bir rüyaya dönüştü.';

const _sampleTextFr =
    'Il était une fois, dans une ville tranquille au bord de la mer, un petit '
    'renard nommé Lumi qui ne pouvait pas s\'endormir. La lune était pleine, '
    'les vagues étaient douces, et quelque part au loin une chouette racontait '
    'à la nuit son secret préféré. Alors Lumi ferma les yeux et écouta, et le '
    'secret devint lentement un rêve.';

const _sampleTextEs =
    'Había una vez, en un pueblo tranquilo junto al mar, un pequeño zorro '
    'llamado Lumi que no podía dormirse. La luna estaba llena, las olas eran '
    'suaves, y en algún lugar lejano un búho le contaba a la noche su secreto '
    'favorito. Así que Lumi cerró los ojos y escuchó, y el secreto se fue '
    'convirtiendo lentamente en un sueño.';

const _samples = [_sampleText, _sampleTextDe, _sampleTextTr, _sampleTextFr, _sampleTextEs];

// Screen-level engine list. Each entry pairs a UI label + model directory with
// a TtsEngineKind from tts_session.dart. TtsEngineKind is the single source of
// truth for model file layout — add a new engine there first; the compiler then
// enforces that its modelConfig() case is handled before the build succeeds.
enum _Engine {
  piperEn(
    'Piper EN (94 MB, 904 voices)',
    'vits-piper-en_US-libritts_r-medium',
    TtsEngineKind.piperEn,
  ),
  piperDe(
    'Piper DE Thorsten (76 MB)',
    'vits-piper-de_DE-thorsten-medium',
    TtsEngineKind.piperDe,
  ),
  piperTr(
    'Piper TR Fahrettin',
    'vits-piper-tr_TR-fahrettin-medium',
    TtsEngineKind.piperTr,
  ),
  pocket(
    'Pocket TTS EN (98 MB, clones any voice)',
    'sherpa-onnx-pocket-tts-int8-2026-01-26',
    TtsEngineKind.pocket,
  ),
  pocketDe(
    'Pocket TTS DE 6-layer (~152 MB)',
    'pocket-tts-de',
    TtsEngineKind.pocketDe,
  ),
  pocketDe24l(
    'Pocket TTS DE 24-layer (large)',
    'pocket-tts-de-24l',
    TtsEngineKind.pocketDe24l,
  ),
  pocketFr24l(
    'Pocket TTS FR 24-layer (~152 MB)',
    'pocket-tts-fr-24l',
    TtsEngineKind.pocketFr24l,
  ),
  pocketEs(
    'Pocket TTS ES 6-layer (~152 MB)',
    'pocket-tts-es',
    TtsEngineKind.pocketEs,
  ),
  device('System TTS (Google / device voices)', '', null);

  const _Engine(this.label, this.dir, this.kind);

  final String label;
  final String dir;
  // null only for the device/system engine which bypasses TtsSession entirely.
  final TtsEngineKind? kind;
}

class TtsSpikeScreen extends StatefulWidget {
  const TtsSpikeScreen({super.key});

  @override
  State<TtsSpikeScreen> createState() => _TtsSpikeScreenState();
}

class _TtsSpikeScreenState extends State<TtsSpikeScreen>
    with AutomaticKeepAliveClientMixin {
  final _textController = TextEditingController(text: _sampleText);
  final _player = AudioPlayer();
  final _deviceTts = FlutterTts();
  final _refRecorder = AudioRecorder();

  TtsSession? _session;
  _Engine _engine = _Engine.piperEn;
  final Set<_Engine> _available = {_Engine.device};
  String _status = 'Initializing...';
  String _metrics = '';
  int _sid = 0;
  double _speed = 0.9;
  String _deviceLang = 'en-US';
  bool _busy = false;
  ConcatenatingAudioSource? _playlist;

  // Pocket voice cloning: which reference wav narrates. 'built-in' is bria.wav
  // shipped in the model dir; 'mine' is a per-language ~20 s recording saved
  // to <support>/pocket-ref-<lang>.wav so each language captures natural
  // prosody in that language.
  String? _supportPath;
  bool _useMyVoice = false;
  bool get _isPocket => _engine.kind?.isPocket ?? false;

  // Language tag used for the per-language voice file.
  String get _langTag => switch (_engine) {
        _Engine.pocketDe || _Engine.pocketDe24l => 'de',
        _Engine.pocketFr24l                      => 'fr',
        _Engine.pocketEs                         => 'es',
        _                                        => 'en',
      };

  String get _myVoicePath =>
      p.join(_supportPath!, 'pocket-ref-$_langTag.wav');

  bool get _hasMyVoice =>
      _supportPath != null && File(_myVoicePath).existsSync();

  String get _refWavPath => _useMyVoice && _hasMyVoice
      ? _myVoicePath
      : p.join(_supportPath!, _engine.dir, 'test_wavs', 'bria.wav');

  // Prompt text shown while recording a voice reference. Any ~20 s of natural
  // speech works — this just gives users something comfortable to read aloud.
  String get _voicePrompt {
    switch (_engine) {
      case _Engine.pocketDe:
      case _Engine.pocketDe24l:
        return 'Es war ein ruhiger Herbstmorgen. Die Sonne schien durch die '
            'Blätter der alten Eichen, und irgendwo in der Ferne sang ein '
            'Vogel. Ich stand am Fenster mit einer Tasse Tee in der Hand und '
            'dachte an die vergangene Woche — an die kleinen Momente, die man '
            'so leicht vergisst: ein Lächeln auf der Straße, ein gutes '
            'Gespräch, der Duft von frisch gebackenem Brot.';
      case _Engine.pocketFr24l:
        return "C'était un matin d'automne paisible. Le soleil filtrait à "
            "travers les feuilles des vieux chênes, et quelque part au loin "
            "un oiseau chantait. Je me tenais près de la fenêtre, une tasse "
            "de thé à la main, en pensant à la semaine écoulée — à ces petits "
            "moments qu'on oublie si vite : un sourire dans la rue, une bonne "
            "conversation, l'odeur du pain tout juste sorti du four.";
      case _Engine.pocketEs:
        return 'Era una tranquila mañana de otoño. El sol se filtraba entre '
            'las hojas de los viejos robles, y en algún lugar a lo lejos '
            'cantaba un pájaro. Me quedé junto a la ventana con una taza de '
            'té en la mano, pensando en la semana pasada — en esos pequeños '
            'momentos que tan fácilmente se olvidan: una sonrisa en la calle, '
            'una buena conversación, el olor del pan recién horneado.';
      default:
        return 'It was a quiet autumn morning. Sunlight filtered through the '
            'leaves of the old oak trees, and somewhere in the distance a '
            'bird was singing. I stood by the window with a cup of tea in my '
            'hand, thinking about the past week — about the small moments you '
            'so easily forget: a smile on the street, a good conversation, '
            'the smell of freshly baked bread.';
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scanAndLoad();
  }

  @override
  void dispose() {
    _textController.dispose();
    _player.dispose();
    _refRecorder.dispose();
    _deviceTts.stop();
    _session?.dispose();
    super.dispose();
  }

  Future<void> _scanAndLoad() async {
    final support = await getApplicationSupportDirectory();
    _supportPath = support.path;
    setState(() {
      _available.addAll(_Engine.values.where((e) =>
          e != _Engine.device &&
          Directory(p.join(support.path, e.dir)).existsSync()));
    });
    await _load(_available.contains(_engine) ? _engine : _available.first);
  }

  String _sampleFor(_Engine engine) {
    return switch (engine) {
      _Engine.piperDe || _Engine.pocketDe || _Engine.pocketDe24l => _sampleTextDe,
      _Engine.piperTr => _sampleTextTr,
      _Engine.pocketFr24l => _sampleTextFr,
      _Engine.pocketEs => _sampleTextEs,
      _Engine.device => switch (_deviceLang) {
        'de-DE' => _sampleTextDe,
        'tr-TR' => _sampleTextTr,
        _ => _sampleText,
      },
      _ => _sampleText,
    };
  }

  Future<void> _load(_Engine engine) async {
    setState(() {
      _busy = true;
      _engine = engine;
      _status = 'Loading ${engine.label}...';
      _metrics = '';
    });
    try {
      await _player.stop();
      await _deviceTts.stop();
      _session?.dispose();
      _session = null;

      if (_samples.contains(_textController.text)) {
        _textController.text = _sampleFor(engine);
      }

      if (engine == _Engine.device) {
        final voices = await _deviceTts.getVoices;
        setState(() => _status =
            'System TTS ready (${(voices as List?)?.length ?? '?'} device '
            'voices). This uses the OS accessibility stack, not our models.');
        return;
      }

      final support = await getApplicationSupportDirectory();
      final modelDir = p.join(support.path, engine.dir);
      final session = await TtsSession.spawn(
          kind: engine.kind!, modelDir: modelDir, outDir: support.path);
      if (!mounted) {
        session.dispose();
        return;
      }
      setState(() {
        _session = session;
        _sid = 0;
        _status = '${engine.label} loaded in ${session.initMs} ms '
            '(${session.numSpeakers} voices). Pick a voice and speak.';
      });
    } catch (e) {
      debugPrint('tts spike init failed: $e');
      setState(() => _status = 'Init failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _speak() async {
    if (_busy) return;
    if (_engine == _Engine.device) {
      await _speakDevice();
      return;
    }
    final session = _session;
    if (session == null) return;
    setState(() {
      _busy = true;
      _status = 'Synthesizing sentence by sentence (off-thread)...';
      _metrics = '';
    });
    try {
      await _player.stop();
      final playlist = ConcatenatingAudioSource(children: []);
      _playlist = playlist;

      final total = Stopwatch()..start();
      int? firstAudioMs;
      var synthMs = 0;
      var audioSec = 0.0;
      var chunks = 0;

      await for (final chunk in session.speak(_textController.text.trim(),
          sid: _sid,
          speed: _speed,
          refWavPath: _isPocket ? _refWavPath : null)) {
        if (_playlist != playlist) return; // superseded by a newer speak
        synthMs += chunk.synthMs;
        audioSec += chunk.audioSec;
        chunks++;
        await playlist.add(AudioSource.uri(Uri.file(chunk.wavPath)));
        if (firstAudioMs == null) {
          firstAudioMs = total.elapsedMilliseconds;
          await _player.setAudioSource(playlist);
          // Playback starts NOW, while later sentences still synthesize.
          unawaited(_player.play());
        }
        setState(() {
          _status = 'Playing (sentence $chunks${chunk.last ? ', done' : '...'})';
          _metrics = 'first audio after: ${firstAudioMs! / 1000.0} s\n'
              'synth so far: ${(synthMs / 1000).toStringAsFixed(2)} s '
              'for ${audioSec.toStringAsFixed(1)} s audio '
              '(RTF ${(synthMs / 1000 / audioSec).toStringAsFixed(3)})';
        });
      }
    } catch (e) {
      debugPrint('tts spike synthesis failed: $e');
      setState(() => _status = 'Synthesis failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    _session?.cancel();
    await _player.stop();
    await _deviceTts.stop();
    setState(() {
      _busy = false;
      _status = 'Stopped.';
    });
  }

  /// Opens a full-screen modal that counts down 3-2-1 then records the voice
  /// reference for the current language. Saves to pocket-ref-<lang>.wav.
  Future<void> _openRefRecordingModal() async {
    if (!await _refRecorder.hasPermission()) {
      setState(() => _status = 'Microphone permission denied.');
      return;
    }
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _VoiceRecordDialog(
        recorder: _refRecorder,
        savePath: _myVoicePath,
        prompt: _voicePrompt,
      ),
    );
    if (saved == true) {
      setState(() {
        _useMyVoice = true;
        _status = 'Voice saved for ${_langTag.toUpperCase()}. Using it now.';
      });
    }
  }

  Future<void> _speakDevice() async {
    setState(() {
      _busy = true;
      _status = 'Speaking via system TTS ($_deviceLang)...';
      _metrics = '';
    });
    try {
      await _deviceTts.stop();
      await _deviceTts.setLanguage(_deviceLang);
      // flutter_tts rate: ~0.5 is normal speed on Android.
      await _deviceTts.setSpeechRate(_speed * 0.55);
      final sw = Stopwatch()..start();
      await _deviceTts.speak(_textController.text.trim());
      setState(() {
        _status = 'System TTS speaking.';
        _metrics =
            'started after: ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)} s '
            '(no RTF: synthesis happens inside the OS)';
      });
    } catch (e) {
      debugPrint('device tts failed: $e');
      setState(() => _status = 'System TTS failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  double get _maxSid => ((_session?.numSpeakers ?? 1) - 1).toDouble();

  @override
  Widget build(BuildContext context) {
    super.build(context);
    const label = TextStyle(color: Colors.white70, fontSize: 13);
    final isPiper = _engine != _Engine.device;
    return SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<_Engine>(
              initialValue: _engine,
              isExpanded: true,
              dropdownColor: const Color(0xFF1B2A4A),
              style: const TextStyle(color: Colors.white, fontSize: 15),
              iconEnabledColor: Colors.white70,
              // Keep the selected label readable while disabled during load.
              disabledHint: Text(_engine.label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 15)),
              decoration: const InputDecoration(
                labelText: 'Engine',
                labelStyle: label,
                enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white54)),
              ),
              items: [
                for (final e in _Engine.values)
                  DropdownMenuItem(
                    value: e,
                    enabled: _available.contains(e),
                    child: Text(
                      _available.contains(e)
                          ? e.label
                          : '${e.label} - not pushed',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: _available.contains(e)
                              ? Colors.white
                              : Colors.white38),
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (e) {
                      if (e != null && e != _engine) _load(e);
                    },
            ),
            if (_busy) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(minHeight: 2),
            ],
            if (_isPocket) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Narrator', style: label),
                  const SizedBox(width: 12),
                  ChoiceChip(
                    label: const Text('Built-in'),
                    selected: !_useMyVoice,
                    onSelected: _busy
                        ? null
                        : (sel) {
                            if (sel) setState(() => _useMyVoice = false);
                          },
                  ),
                  if (_hasMyVoice) ...[
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('My voice'),
                      selected: _useMyVoice,
                      onSelected: _busy
                          ? null
                          : (sel) {
                              if (sel) setState(() => _useMyVoice = true);
                            },
                    ),
                  ],
                  const Spacer(),
                  IconButton(
                    tooltip: 'Record my voice (${_langTag.toUpperCase()})',
                    icon: const Icon(Icons.mic, color: Colors.white70),
                    onPressed: _busy ? null : _openRefRecordingModal,
                  ),
                ],
              ),
            ],
            if (_engine == _Engine.device) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Language', style: label),
                  const SizedBox(width: 12),
                  for (final lang in ['en-US', 'de-DE', 'tr-TR'])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(lang.substring(0, 2).toUpperCase()),
                        selected: _deviceLang == lang,
                        onSelected: _busy
                            ? null
                            : (sel) {
                                if (sel) {
                                  setState(() {
                                    _deviceLang = lang;
                                    if (_samples
                                        .contains(_textController.text)) {
                                      _textController.text =
                                          _sampleFor(_Engine.device);
                                    }
                                  });
                                }
                              },
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Text(_status, style: const TextStyle(color: Colors.white)),
            if (_metrics.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_metrics,
                  style: const TextStyle(
                      color: Colors.amberAccent,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _textController,
              maxLines: 6,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Story text',
                labelStyle: label,
                enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white54)),
              ),
            ),
            const SizedBox(height: 16),
            if (isPiper && !_isPocket)
              Row(
                children: [
                  const Text('Voice (sid)', style: label),
                  Expanded(
                    child: Slider(
                      value: _sid.toDouble().clamp(0, _maxSid).toDouble(),
                      min: 0,
                      max: _maxSid,
                      onChanged: (_session == null || _maxSid == 0)
                          ? null
                          : (v) => setState(() => _sid = v.round()),
                    ),
                  ),
                  Text('$_sid', style: const TextStyle(color: Colors.white)),
                ],
              ),
            Row(
              children: [
                const Text('Speed', style: label),
                Expanded(
                  child: Slider(
                    value: _speed,
                    min: 0.5,
                    max: 1.5,
                    divisions: 20,
                    onChanged: (v) => setState(() => _speed = v),
                  ),
                ),
                Text(_speed.toStringAsFixed(2),
                    style: const TextStyle(color: Colors.white)),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        (_busy || (isPiper && _session == null)) ? null : _speak,
                    icon: const Icon(Icons.record_voice_over),
                    label: const Text('Synthesize and play'),
                  ),
                ),
                if (_busy) ...[
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Stop',
                    style: IconButton.styleFrom(
                        backgroundColor: Colors.redAccent.withValues(alpha: 0.8)),
                    icon: const Icon(Icons.stop),
                    onPressed: _stop,
                  ),
                ],
              ],
            ),
          ],
        ));
  }
}

/// Full-screen dialog for recording a voice reference with a 3-2-1 countdown.
class _VoiceRecordDialog extends StatefulWidget {
  const _VoiceRecordDialog({
    required this.recorder,
    required this.savePath,
    required this.prompt,
  });

  final AudioRecorder recorder;
  final String savePath;
  final String prompt;

  @override
  State<_VoiceRecordDialog> createState() => _VoiceRecordDialogState();
}

class _VoiceRecordDialogState extends State<_VoiceRecordDialog> {
  // Phases: 'ready' → 'countdown' → 'recording' → done (pop)
  String _phase = 'ready';
  int _countdown = 3;
  bool _recording = false;

  Future<void> _startCountdown() async {
    setState(() { _phase = 'countdown'; _countdown = 3; });
    for (int i = 3; i >= 1; i--) {
      setState(() => _countdown = i);
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
    }
    await _beginRecording();
  }

  Future<void> _beginRecording() async {
    try {
      await widget.recorder.start(
        const RecordConfig(
            encoder: AudioEncoder.wav, sampleRate: 24000, numChannels: 1),
        path: widget.savePath,
      );
      setState(() { _phase = 'recording'; _recording = true; });
    } catch (e) {
      debugPrint('voice record failed: $e');
      if (mounted) Navigator.of(context).pop(false);
    }
  }

  Future<void> _stopRecording() async {
    await widget.recorder.stop();
    setState(() => _recording = false);
    if (mounted) Navigator.of(context).pop(File(widget.savePath).existsSync());
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: const Color(0xFF0D1B2E),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Spacer(),
                  if (_phase == 'ready')
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.of(context).pop(false),
                    ),
                ],
              ),
              const Spacer(),
              if (_phase == 'ready') ...[
                const Icon(Icons.mic_none, size: 64, color: Colors.white54),
                const SizedBox(height: 24),
                const Text('Record your voice',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                const Text(
                  'Find a quiet spot. You\'ll read a short text aloud — '
                  'about 20 seconds.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 16, height: 1.5),
                ),
                const SizedBox(height: 8),
                Tooltip(
                  message: 'You can say anything you like — a story, a memory, '
                      'whatever feels natural. Just aim for ~20 seconds '
                      'in a quiet room.',
                  triggerMode: TooltipTriggerMode.tap,
                  showDuration: const Duration(seconds: 6),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.info_outline, size: 14, color: Colors.white38),
                      SizedBox(width: 4),
                      Text('Or speak freely',
                          style: TextStyle(color: Colors.white38, fontSize: 13)),
                    ],
                  ),
                ),
                const SizedBox(height: 36),
                FilledButton(
                  onPressed: _startCountdown,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Text('Start', style: TextStyle(fontSize: 18)),
                  ),
                ),
              ] else if (_phase == 'countdown') ...[
                Text(
                  '$_countdown',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 120,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                const Text('Get ready…',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 18)),
              ] else ...[
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.fiber_manual_record,
                        color: Colors.redAccent, size: 16),
                    SizedBox(width: 8),
                    Text('Recording',
                        style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 28),
                Text(
                  widget.prompt,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 18, height: 1.7),
                ),
                const SizedBox(height: 36),
                FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.redAccent),
                  onPressed: _recording ? _stopRecording : null,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Text('Done', style: TextStyle(fontSize: 18)),
                  ),
                ),
              ],
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
