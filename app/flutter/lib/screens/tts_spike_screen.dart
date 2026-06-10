// Spike 1a (plans/post-hackathon-soul-and-direction.md): can this phone tell a
// story fully offline? Loads a local TTS engine via sherpa_onnx (Piper VITS or
// Kokoro), synthesizes a bedtime paragraph on-device, plays it, and reports
// timing (init, synth, RTF). An engine switcher allows A/B-ing quality vs cost
// on the actual phone speaker.
//
// Not part of the product flow. Reached only when built with
// --dart-define=TTS_SPIKE=true. Models are NOT bundled; push each model dir
// once to /data/local/tmp via adb, then copy it into the app's files/ with
// `adb shell run-as quest.yarnia.yarnia cp -r /data/local/tmp/<dir> files/`.
// Engines whose model dir is missing show up disabled in the dropdown.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

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

enum _Engine {
  piperEn('Piper EN (94 MB, 904 voices)', 'vits-piper-en_US-libritts_r-medium'),
  piperDe('Piper DE Thorsten (76 MB)', 'vits-piper-de_DE-thorsten-medium'),
  kokoro('Kokoro EN (354 MB, best quality)', 'kokoro-en-v0_19'),
  kitten('Kitten nano EN (25 MB, tiny)', 'kitten-nano-en-v0_8-fp32');

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

  sherpa_onnx.OfflineTts? _tts;
  _Engine _engine = _Engine.piperEn;
  final Set<_Engine> _available = {};
  String _status = 'Initializing...';
  String _metrics = '';
  int _sid = 0;
  double _speed = 0.9;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _scanAndLoad();
  }

  Future<void> _scanAndLoad() async {
    final support = await getApplicationSupportDirectory();
    setState(() {
      _available.addAll(_Engine.values
          .where((e) => Directory(p.join(support.path, e.dir)).existsSync()));
    });
    await _load(_available.contains(_engine)
        ? _engine
        : (_available.firstOrNull ?? _engine));
  }

  @override
  void dispose() {
    _textController.dispose();
    _player.dispose();
    _tts?.free();
    super.dispose();
  }

  Future<void> _load(_Engine engine) async {
    setState(() {
      _busy = true;
      _engine = engine;
      _status = 'Loading ${engine.label}...';
      _metrics = '';
    });
    try {
      _tts?.free();
      _tts = null;

      final support = await getApplicationSupportDirectory();
      final modelDir = p.join(support.path, engine.dir);
      if (!Directory(modelDir).existsSync()) {
        setState(() {
          _status = '${engine.label} model not found:\n$modelDir\n\n'
              'Push it via adb (see comment at the top of '
              'tts_spike_screen.dart).';
        });
        return;
      }

      sherpa_onnx.initBindings();
      final sw = Stopwatch()..start();
      final tokens = p.join(modelDir, 'tokens.txt');
      final dataDir = p.join(modelDir, 'espeak-ng-data');
      final modelConfig = switch (engine) {
        _Engine.piperEn => sherpa_onnx.OfflineTtsModelConfig(
            vits: sherpa_onnx.OfflineTtsVitsModelConfig(
              model: p.join(modelDir, 'en_US-libritts_r-medium.onnx'),
              tokens: tokens,
              dataDir: dataDir,
            ),
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
        _Engine.piperDe => sherpa_onnx.OfflineTtsModelConfig(
            vits: sherpa_onnx.OfflineTtsVitsModelConfig(
              model: p.join(modelDir, 'de_DE-thorsten-medium.onnx'),
              tokens: tokens,
              dataDir: dataDir,
            ),
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
        _Engine.kokoro => sherpa_onnx.OfflineTtsModelConfig(
            kokoro: sherpa_onnx.OfflineTtsKokoroModelConfig(
              model: p.join(modelDir, 'model.onnx'),
              voices: p.join(modelDir, 'voices.bin'),
              tokens: tokens,
              dataDir: dataDir,
            ),
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
        _Engine.kitten => sherpa_onnx.OfflineTtsModelConfig(
            kitten: sherpa_onnx.OfflineTtsKittenModelConfig(
              model: p.join(modelDir, 'model.fp32.onnx'),
              voices: p.join(modelDir, 'voices.bin'),
              tokens: tokens,
              dataDir: dataDir,
            ),
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
      };
      final tts = sherpa_onnx.OfflineTts(sherpa_onnx.OfflineTtsConfig(
        model: modelConfig,
        maxNumSenetences: 1,
      ));
      sw.stop();
      setState(() {
        _tts = tts;
        _sid = 0;
        // Give the German engine German text to read (and vice versa), unless
        // the user already typed their own.
        if (_textController.text == _sampleText ||
            _textController.text == _sampleTextDe) {
          _textController.text =
              engine == _Engine.piperDe ? _sampleTextDe : _sampleText;
        }
        _status = '${engine.label} loaded in ${sw.elapsedMilliseconds} ms '
            '(${tts.numSpeakers} voices). Pick a voice and speak.';
      });
    } catch (e) {
      debugPrint('tts spike init failed: $e');
      setState(() => _status = 'Init failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _speak() async {
    final tts = _tts;
    if (tts == null || _busy) return;
    setState(() {
      _busy = true;
      _status = 'Synthesizing on-device (2 threads)...';
      _metrics = '';
    });
    try {
      await _player.stop();
      final text = _textController.text.trim();
      final sw = Stopwatch()..start();
      final audio = tts.generate(text: text, sid: _sid, speed: _speed);
      sw.stop();

      final audioSec = audio.samples.length / audio.sampleRate;
      final synthSec = sw.elapsedMilliseconds / 1000.0;
      final rtf = synthSec / audioSec;

      final dir = await getApplicationSupportDirectory();
      final wav = p.join(dir.path, 'spike-${_engine.name}-sid$_sid.wav');
      final ok = sherpa_onnx.writeWave(
        filename: wav,
        samples: audio.samples,
        sampleRate: audio.sampleRate,
      );
      if (!ok) throw Exception('writeWave failed');

      setState(() {
        _status = 'Playing ${_engine.label} (sid $_sid, speed '
            '${_speed.toStringAsFixed(2)}).';
        _metrics = 'synth: ${synthSec.toStringAsFixed(2)} s\n'
            'audio: ${audioSec.toStringAsFixed(2)} s @ ${audio.sampleRate} Hz\n'
            'RTF: ${rtf.toStringAsFixed(3)} '
            '(${(1 / rtf).toStringAsFixed(1)}x faster than realtime)';
      });
      await _player.setFilePath(wav);
      await _player.play();
    } catch (e) {
      debugPrint('tts spike synthesis failed: $e');
      setState(() => _status = 'Synthesis failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  double get _maxSid => ((_tts?.numSpeakers ?? 1) - 1).toDouble();

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    const label = TextStyle(color: Colors.white70, fontSize: 13);
    return SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<_Engine>(
              initialValue: _engine,
              dropdownColor: const Color(0xFF1B2A4A),
              style: const TextStyle(color: Colors.white, fontSize: 15),
              iconEnabledColor: Colors.white70,
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
            Row(
              children: [
                const Text('Voice (sid)', style: label),
                Expanded(
                  child: Slider(
                    value: _sid
                        .toDouble()
                        .clamp(0, _maxSid)
                        .toDouble(),
                    min: 0,
                    max: _maxSid,
                    onChanged: (_tts == null || _maxSid == 0)
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
              onPressed: (_tts == null || _busy) ? null : _speak,
              icon: const Icon(Icons.record_voice_over),
              label: Text(_busy ? 'Working...' : 'Synthesize and play'),
            ),
          ],
        ));
  }
}
