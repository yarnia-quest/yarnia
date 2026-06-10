// Spike 2 (plans/post-hackathon-soul-and-direction.md): realtime on-device
// STT, "the key" piece. Two engines, selectable:
//
// - Zipformer EN: streaming transducer, instant partials, English only,
//   small-model accuracy.
// - Whisper base (VAD): Silero VAD segments speech at pauses, multilingual
//   Whisper transcribes each segment (German works, language auto-detected).
//   No live partials, but much better accuracy. This matches the bedtime
//   turn-taking shape anyway.
//
// The child's voice never leaves the device in either mode.
//
// Models (push once, like the TTS ones):
//   adb push sherpa-onnx-streaming-zipformer-en-2023-06-26 /data/local/tmp/
//   adb push sherpa-onnx-whisper-base /data/local/tmp/
//   adb push silero_vad.onnx /data/local/tmp/
//   adb shell run-as quest.yarnia.yarnia sh -c 'cp -r /data/local/tmp/<each> files/'

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

const _zipformerDir = 'sherpa-onnx-streaming-zipformer-en-2023-06-26';
const _whisperDir = 'sherpa-onnx-whisper-base';
const _vadFile = 'silero_vad.onnx';
const _sampleRate = 16000;

enum _Asr {
  zipformer('Zipformer EN (streaming, fast)'),
  whisper('Whisper base (VAD, multilingual incl. DE)');

  const _Asr(this.label);

  final String label;
}

// The record stream hands out chunks at arbitrary byte offsets, so an
// Int16List.view is not allowed (2-byte alignment) and a chunk may even split
// a 16-bit sample. Read via ByteData (alignment-safe) instead.
Float32List _bytesToFloat32(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final n = bytes.lengthInBytes ~/ 2;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
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

  // Streaming engine (zipformer)
  sherpa_onnx.OnlineRecognizer? _onlineRecognizer;
  sherpa_onnx.OnlineStream? _onlineStream;

  // VAD + offline engine (whisper)
  sherpa_onnx.OfflineRecognizer? _offlineRecognizer;
  sherpa_onnx.VoiceActivityDetector? _vad;
  sherpa_onnx.CircularBuffer? _vadBuffer;
  int _vadWindowSize = 512;

  StreamSubscription<Uint8List>? _audioSub;

  _Asr _asr = _Asr.whisper;
  String _status = 'Initializing...';
  String _partial = '';
  String _metrics = '';
  final List<String> _segments = [];
  bool _listening = false;
  bool _busy = false;
  Uint8List _carry = Uint8List(0);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load(_asr);
  }

  @override
  void dispose() {
    _audioSub?.cancel();
    _recorder.dispose();
    _onlineStream?.free();
    _onlineRecognizer?.free();
    _offlineRecognizer?.free();
    _vad?.free();
    _vadBuffer?.free();
    super.dispose();
  }

  Future<void> _load(_Asr asr) async {
    if (_listening) await _stop();
    setState(() {
      _busy = true;
      _asr = asr;
      _status = 'Loading ${asr.label}...';
      _partial = '';
      _metrics = '';
    });
    try {
      final support = await getApplicationSupportDirectory();
      sherpa_onnx.initBindings();
      final sw = Stopwatch()..start();

      switch (asr) {
        case _Asr.zipformer:
          if (_onlineRecognizer == null) {
            final dir = p.join(support.path, _zipformerDir);
            if (!Directory(dir).existsSync()) {
              setState(() => _status = 'Zipformer model not found:\n$dir');
              return;
            }
            _onlineRecognizer = sherpa_onnx.OnlineRecognizer(
              sherpa_onnx.OnlineRecognizerConfig(
                model: sherpa_onnx.OnlineModelConfig(
                  transducer: sherpa_onnx.OnlineTransducerModelConfig(
                    encoder: p.join(dir,
                        'encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx'),
                    decoder: p.join(
                        dir, 'decoder-epoch-99-avg-1-chunk-16-left-128.onnx'),
                    joiner: p.join(
                        dir, 'joiner-epoch-99-avg-1-chunk-16-left-128.onnx'),
                  ),
                  tokens: p.join(dir, 'tokens.txt'),
                  modelType: 'zipformer2',
                ),
                ruleFsts: '',
              ),
            );
          }
        case _Asr.whisper:
          if (_offlineRecognizer == null) {
            final dir = p.join(support.path, _whisperDir);
            final vadPath = p.join(support.path, _vadFile);
            if (!Directory(dir).existsSync() || !File(vadPath).existsSync()) {
              setState(() => _status =
                  'Whisper model or VAD not found:\n$dir\n$vadPath');
              return;
            }
            _offlineRecognizer = sherpa_onnx.OfflineRecognizer(
              sherpa_onnx.OfflineRecognizerConfig(
                model: sherpa_onnx.OfflineModelConfig(
                  whisper: sherpa_onnx.OfflineWhisperModelConfig(
                    encoder: p.join(dir, 'base-encoder.int8.onnx'),
                    decoder: p.join(dir, 'base-decoder.int8.onnx'),
                    // empty language = per-segment auto-detect (EN and DE both
                    // work); set 'de' to pin German.
                    language: '',
                    task: 'transcribe',
                  ),
                  tokens: p.join(dir, 'base-tokens.txt'),
                  modelType: 'whisper',
                  numThreads: 2,
                ),
              ),
            );
            final vadConfig = sherpa_onnx.VadModelConfig(
              sileroVad: sherpa_onnx.SileroVadModelConfig(
                model: vadPath,
                minSilenceDuration: 0.4,
                minSpeechDuration: 0.25,
                maxSpeechDuration: 12.0,
              ),
              numThreads: 1,
              debug: false,
            );
            _vadWindowSize = vadConfig.sileroVad.windowSize;
            _vad = sherpa_onnx.VoiceActivityDetector(
                config: vadConfig, bufferSizeInSeconds: 30);
            _vadBuffer =
                sherpa_onnx.CircularBuffer(capacity: 30 * _sampleRate);
          }
      }
      sw.stop();
      setState(() {
        _status = '${asr.label} ready in ${sw.elapsedMilliseconds} ms. '
            'Tap the mic and talk; everything stays on this phone.';
      });
    } catch (e) {
      debugPrint('stt spike init failed: $e');
      setState(() => _status = 'Init failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _toggle() async {
    if (_listening) {
      await _stop();
    } else {
      await _start();
    }
  }

  bool get _engineReady => _asr == _Asr.zipformer
      ? _onlineRecognizer != null
      : (_offlineRecognizer != null && _vad != null);

  Future<void> _start() async {
    if (!_engineReady) return;
    try {
      if (!await _recorder.hasPermission()) {
        setState(() => _status = 'Microphone permission denied.');
        return;
      }
      if (_asr == _Asr.zipformer) {
        _onlineStream?.free();
        _onlineStream = _onlineRecognizer!.createStream();
      }

      _carry = Uint8List(0);
      final audio = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
      ));
      _audioSub = audio.listen((data) {
        // Re-join the carry byte from the previous chunk so 16-bit samples
        // split across chunk boundaries are not corrupted.
        var bytes = data;
        if (_carry.isNotEmpty) {
          bytes = Uint8List(_carry.length + data.length)
            ..setAll(0, _carry)
            ..setAll(_carry.length, data);
        }
        final usable = bytes.length & ~1;
        _carry = Uint8List.fromList(bytes.sublist(usable));
        if (usable == 0) return;
        final samples =
            _bytesToFloat32(Uint8List.sublistView(bytes, 0, usable));
        if (_asr == _Asr.zipformer) {
          _feedZipformer(samples);
        } else {
          _feedWhisper(samples);
        }
      });
      setState(() {
        _listening = true;
        _status = _asr == _Asr.zipformer
            ? 'Listening (streaming, on-device)...'
            : 'Listening (VAD-segmented, on-device). Pause to transcribe.';
      });
    } catch (e) {
      debugPrint('stt spike start failed: $e');
      setState(() => _status = 'Start failed: $e');
    }
  }

  void _feedZipformer(Float32List samples) {
    final recognizer = _onlineRecognizer;
    final stream = _onlineStream;
    if (recognizer == null || stream == null) return;
    stream.acceptWaveform(samples: samples, sampleRate: _sampleRate);
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
  }

  void _feedWhisper(Float32List samples) {
    final vad = _vad;
    final buffer = _vadBuffer;
    final recognizer = _offlineRecognizer;
    if (vad == null || buffer == null || recognizer == null) return;

    buffer.push(samples);
    while (buffer.size >= _vadWindowSize) {
      final window = buffer.get(startIndex: buffer.head, n: _vadWindowSize);
      buffer.pop(_vadWindowSize);
      vad.acceptWaveform(window);
    }

    var speaking = vad.isDetected();
    while (!vad.isEmpty()) {
      final segment = vad.front();
      vad.pop();
      final segSec = segment.samples.length / _sampleRate;
      final sw = Stopwatch()..start();
      final stream = recognizer.createStream();
      stream.acceptWaveform(samples: segment.samples, sampleRate: _sampleRate);
      recognizer.decode(stream);
      final text = recognizer.getResult(stream).text.trim();
      stream.free();
      sw.stop();
      final decodeSec = sw.elapsedMilliseconds / 1000.0;
      if (text.isNotEmpty) {
        _segments.insert(0, text);
      }
      _metrics = 'last segment: ${segSec.toStringAsFixed(1)} s speech, '
          'decoded in ${decodeSec.toStringAsFixed(2)} s '
          '(RTF ${(decodeSec / segSec).toStringAsFixed(2)})';
      speaking = false;
    }
    setState(() => _partial = speaking ? '(listening...)' : '');
  }

  Future<void> _stop() async {
    try {
      await _audioSub?.cancel();
      _audioSub = null;
      await _recorder.stop();
      if (_asr == _Asr.whisper) {
        // Flush a trailing segment the VAD has not closed yet.
        _vad?.flush();
        _feedWhisper(Float32List(0));
      }
    } catch (e) {
      debugPrint('stt spike stop failed: $e');
    }
    setState(() {
      _listening = false;
      _status = 'Stopped. Tap the mic to listen again.';
      _partial = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    const label = TextStyle(color: Colors.white70, fontSize: 13);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<_Asr>(
              initialValue: _asr,
              dropdownColor: const Color(0xFF1B2A4A),
              style: const TextStyle(color: Colors.white, fontSize: 15),
              iconEnabledColor: Colors.white70,
              decoration: const InputDecoration(
                labelText: 'Recognizer',
                labelStyle: label,
                enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white54)),
              ),
              items: [
                for (final a in _Asr.values)
                  DropdownMenuItem(value: a, child: Text(a.label)),
              ],
              onChanged: _busy
                  ? null
                  : (a) {
                      if (a != null && a != _asr) _load(a);
                    },
            ),
            const SizedBox(height: 12),
            Text(_status, style: const TextStyle(color: Colors.white)),
            if (_metrics.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(_metrics,
                  style: const TextStyle(color: Colors.amberAccent)),
            ],
            const SizedBox(height: 12),
            Text(
              _partial.isEmpty ? '...' : _partial,
              style: const TextStyle(
                  color: Colors.amberAccent,
                  fontSize: 18,
                  fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 12),
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
              onPressed: (!_engineReady || _busy) ? null : _toggle,
              icon: Icon(_listening ? Icons.stop : Icons.mic),
              label: Text(_listening ? 'Stop' : 'Listen'),
            ),
          ],
        ),
      ),
    );
  }
}
