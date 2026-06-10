// Spike 1a (plans/post-hackathon-soul-and-direction.md): can this phone tell a
// story fully offline? Loads a Piper VITS voice via sherpa_onnx, synthesizes a
// bedtime paragraph on-device, plays it, and reports timing (init, synth, RTF).
//
// Not part of the product flow. Reached only when built with
// --dart-define=TTS_SPIKE=true. The model is NOT bundled; push it once with:
//
//   adb push vits-piper-en_US-libritts_r-medium /data/local/tmp/
//   adb shell run-as quest.yarnia.yarnia cp -r \
//       /data/local/tmp/vits-piper-en_US-libritts_r-medium files/

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import '../theme.dart';

const _modelDir = 'vits-piper-en_US-libritts_r-medium';
const _modelName = 'en_US-libritts_r-medium.onnx';

const _sampleText =
    'Once upon a time, in a quiet town by the sea, a little fox named Lumi '
    'could not fall asleep. The moon was full, the waves were soft, and '
    'somewhere far away an owl was telling the night its favorite secret. '
    'So Lumi closed her eyes and listened, and the secret slowly became a dream.';

class TtsSpikeScreen extends StatefulWidget {
  const TtsSpikeScreen({super.key});

  @override
  State<TtsSpikeScreen> createState() => _TtsSpikeScreenState();
}

class _TtsSpikeScreenState extends State<TtsSpikeScreen> {
  final _textController = TextEditingController(text: _sampleText);
  final _player = AudioPlayer();

  sherpa_onnx.OfflineTts? _tts;
  String _status = 'Initializing...';
  String _metrics = '';
  int _sid = 0;
  double _speed = 0.9;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _textController.dispose();
    _player.dispose();
    _tts?.free();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final support = await getApplicationSupportDirectory();
      final modelPath = p.join(support.path, _modelDir, _modelName);
      if (!File(modelPath).existsSync()) {
        setState(() {
          _status = 'Model not found:\n$modelPath\n\n'
              'Push it via adb (see comment at the top of '
              'tts_spike_screen.dart).';
        });
        return;
      }

      sherpa_onnx.initBindings();
      final sw = Stopwatch()..start();
      final config = sherpa_onnx.OfflineTtsConfig(
        model: sherpa_onnx.OfflineTtsModelConfig(
          vits: sherpa_onnx.OfflineTtsVitsModelConfig(
            model: modelPath,
            tokens: p.join(support.path, _modelDir, 'tokens.txt'),
            dataDir: p.join(support.path, _modelDir, 'espeak-ng-data'),
          ),
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        ),
        maxNumSenetences: 1,
      );
      final tts = sherpa_onnx.OfflineTts(config);
      sw.stop();
      setState(() {
        _tts = tts;
        _status = 'Model loaded in ${sw.elapsedMilliseconds} ms '
            '(${tts.numSpeakers} speakers). Pick a voice and speak.';
      });
    } catch (e) {
      debugPrint('tts spike init failed: $e');
      setState(() => _status = 'Init failed: $e');
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
      final wav = p.join(dir.path, 'spike-sid$_sid.wav');
      final ok = sherpa_onnx.writeWave(
        filename: wav,
        samples: audio.samples,
        sampleRate: audio.sampleRate,
      );
      if (!ok) throw Exception('writeWave failed');

      setState(() {
        _status = 'Playing (sid $_sid, speed $_speed).';
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

  @override
  Widget build(BuildContext context) {
    const label = TextStyle(color: Colors.white70, fontSize: 13);
    return Scaffold(
      backgroundColor: navy,
      appBar: AppBar(
        backgroundColor: navy,
        foregroundColor: Colors.white,
        title: const Text('TTS spike: on-device voice'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
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
                    value: _sid.toDouble(),
                    min: 0,
                    max: ((_tts?.numSpeakers ?? 1) - 1).toDouble(),
                    onChanged: _tts == null
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
        ),
      ),
    );
  }
}
