// Spike 1a (plans/post-hackathon-soul-and-direction.md): can this phone tell a
// story fully offline? Trimmed to the engines that match the product's
// language needs (EN + DE, ideally TR): Piper voices per language, plus the
// platform/system TTS (Google / device voices, the accessibility stack) as
// the comparison fallback the plan doc describes.
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
    'Bir zamanlar, deniz kenarindaki sessiz bir kasabada, Lumi adinda kucuk '
    'bir tilki bir turlu uyuyamiyordu. Ay dolunaydi, dalgalar yumusacikti ve '
    'uzaklarda bir yerde bir baykus geceye en sevdigi sirrini anlatiyordu. '
    'Lumi gozlerini kapatip dinledi ve o sir yavas yavas bir ruyaya donustu.';

const _samples = [_sampleText, _sampleTextDe, _sampleTextTr];

enum _Engine {
  piperEn('Piper EN (94 MB, 904 voices)', 'vits-piper-en_US-libritts_r-medium'),
  piperDe('Piper DE Thorsten (76 MB)', 'vits-piper-de_DE-thorsten-medium'),
  piperTr('Piper TR Fahrettin', 'vits-piper-tr_TR-fahrettin-medium'),
  device('System TTS (Google / device voices)', '');

  const _Engine(this.label, this.dir);

  final String label;
  final String dir;
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
    _deviceTts.stop();
    _session?.dispose();
    super.dispose();
  }

  Future<void> _scanAndLoad() async {
    final support = await getApplicationSupportDirectory();
    setState(() {
      _available.addAll(_Engine.values.where((e) =>
          e != _Engine.device &&
          Directory(p.join(support.path, e.dir)).existsSync()));
    });
    await _load(_available.contains(_engine) ? _engine : _available.first);
  }

  String _sampleFor(_Engine engine) {
    if (engine == _Engine.piperDe) return _sampleTextDe;
    if (engine == _Engine.piperTr) return _sampleTextTr;
    if (engine == _Engine.device) {
      return switch (_deviceLang) {
        'de-DE' => _sampleTextDe,
        'tr-TR' => _sampleTextTr,
        _ => _sampleText,
      };
    }
    return _sampleText;
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
          kind: engine.name, modelDir: modelDir, outDir: support.path);
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
          sid: _sid, speed: _speed)) {
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
            if (isPiper)
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
            FilledButton.icon(
              onPressed:
                  (_busy || (isPiper && _session == null)) ? null : _speak,
              icon: const Icon(Icons.record_voice_over),
              label: Text(_busy ? 'Working...' : 'Synthesize and play'),
            ),
          ],
        ));
  }
}
