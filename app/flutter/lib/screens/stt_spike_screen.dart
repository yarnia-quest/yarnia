// Spike 2 (plans/post-hackathon-soul-and-direction.md): realtime on-device
// STT, "the key" piece. Streams 16kHz PCM from the mic into a streaming
// Zipformer transducer via sherpa_onnx and shows the live transcript.
// The child's voice never leaves the device.
//
// Model (push once, like the TTS ones):
//   adb push sherpa-onnx-streaming-zipformer-en-2023-06-26 /data/local/tmp/
//   adb shell run-as quest.yarnia.yarnia cp -r \
//       /data/local/tmp/sherpa-onnx-streaming-zipformer-en-2023-06-26 files/

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

const _asrDir = 'sherpa-onnx-streaming-zipformer-en-2023-06-26';
const _sampleRate = 16000;

Float32List _bytesToFloat32(Uint8List bytes) {
  final values = Int16List.view(bytes.buffer, bytes.offsetInBytes,
      bytes.lengthInBytes ~/ 2);
  final out = Float32List(values.length);
  for (var i = 0; i < values.length; i++) {
    out[i] = values[i] / 32768.0;
  }
  return out;
}

class SttSpikeScreen extends StatefulWidget {
  const SttSpikeScreen({super.key});

  @override
  State<SttSpikeScreen> createState() => _SttSpikeScreenState();
}

class _SttSpikeScreenState extends State<SttSpikeScreen>
    with AutomaticKeepAliveClientMixin {
  final _recorder = AudioRecorder();

  sherpa_onnx.OnlineRecognizer? _recognizer;
  sherpa_onnx.OnlineStream? _stream;
  StreamSubscription<Uint8List>? _audioSub;

  String _status = 'Initializing...';
  String _partial = '';
  final List<String> _segments = [];
  bool _listening = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _audioSub?.cancel();
    _recorder.dispose();
    _stream?.free();
    _recognizer?.free();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final support = await getApplicationSupportDirectory();
      final modelDir = p.join(support.path, _asrDir);
      if (!Directory(modelDir).existsSync()) {
        setState(() {
          _status = 'ASR model not found:\n$modelDir\n\n'
              'Push it via adb (see comment at the top of '
              'stt_spike_screen.dart).';
        });
        return;
      }

      sherpa_onnx.initBindings();
      final sw = Stopwatch()..start();
      final recognizer = sherpa_onnx.OnlineRecognizer(
        sherpa_onnx.OnlineRecognizerConfig(
          model: sherpa_onnx.OnlineModelConfig(
            transducer: sherpa_onnx.OnlineTransducerModelConfig(
              encoder: p.join(modelDir,
                  'encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx'),
              decoder: p.join(
                  modelDir, 'decoder-epoch-99-avg-1-chunk-16-left-128.onnx'),
              joiner: p.join(
                  modelDir, 'joiner-epoch-99-avg-1-chunk-16-left-128.onnx'),
            ),
            tokens: p.join(modelDir, 'tokens.txt'),
            modelType: 'zipformer2',
          ),
          ruleFsts: '',
        ),
      );
      sw.stop();
      setState(() {
        _recognizer = recognizer;
        _status = 'ASR loaded in ${sw.elapsedMilliseconds} ms. '
            'Tap the mic and talk; everything stays on this phone.';
      });
    } catch (e) {
      debugPrint('stt spike init failed: $e');
      setState(() => _status = 'Init failed: $e');
    }
  }

  Future<void> _toggle() async {
    if (_listening) {
      await _stop();
    } else {
      await _start();
    }
  }

  Future<void> _start() async {
    final recognizer = _recognizer;
    if (recognizer == null) return;
    try {
      if (!await _recorder.hasPermission()) {
        setState(() => _status = 'Microphone permission denied.');
        return;
      }
      _stream?.free();
      _stream = recognizer.createStream();

      final audio = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
      ));
      _audioSub = audio.listen((data) {
        final stream = _stream;
        if (stream == null) return;
        stream.acceptWaveform(
            samples: _bytesToFloat32(data), sampleRate: _sampleRate);
        while (recognizer.isReady(stream)) {
          recognizer.decode(stream);
        }
        final text = recognizer.getResult(stream).text;
        var finalized = false;
        if (recognizer.isEndpoint(stream)) {
          recognizer.reset(stream);
          if (text.trim().isNotEmpty) {
            _segments.insert(0, text.trim());
            finalized = true;
          }
        }
        setState(() => _partial = finalized ? '' : text);
      });
      setState(() {
        _listening = true;
        _status = 'Listening (on-device, streaming)...';
      });
    } catch (e) {
      debugPrint('stt spike start failed: $e');
      setState(() => _status = 'Start failed: $e');
    }
  }

  Future<void> _stop() async {
    try {
      await _audioSub?.cancel();
      _audioSub = null;
      await _recorder.stop();
    } catch (e) {
      debugPrint('stt spike stop failed: $e');
    }
    setState(() {
      _listening = false;
      _status = 'Stopped. Tap the mic to listen again.';
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_status, style: const TextStyle(color: Colors.white)),
            const SizedBox(height: 16),
            Text(
              _partial.isEmpty ? '...' : _partial,
              style: const TextStyle(
                  color: Colors.amberAccent,
                  fontSize: 18,
                  fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                children: [
                  for (final s in _segments)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(s,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 16)),
                    ),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: _recognizer == null ? null : _toggle,
              icon: Icon(_listening ? Icons.stop : Icons.mic),
              label: Text(_listening ? 'Stop' : 'Listen'),
            ),
          ],
        ),
      ),
    );
  }
}
