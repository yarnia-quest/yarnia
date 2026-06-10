// Spike 2 (plans/post-hackathon-soul-and-direction.md): realtime on-device
// STT, "the key" piece. All decoding runs in a worker isolate
// (lib/services/asr_session.dart) so slow segments can never freeze the UI
// (Whisper small took 11s/segment on a Kirin 970 and ANRed when decoded on
// the main thread). Engines:
//
// - Zipformer EN: streaming transducer, instant partials, English only.
// - Whisper base/small (VAD): multilingual, language auto-detected.
// - Canary 180M (VAD): EN/DE toggle; outputs in the SELECTED language (it is
//   a translating ASR, speech in the other language gets translated).
// - Parakeet 0.6B v3 (VAD): 25 languages, auto-detect (can be moody on
//   short segments).
// - Hybrid: Zipformer partials live, Whisper base rewrites each segment.
//
// The child's voice never leaves the device in any mode.
//
// Models (push once, like the TTS ones): push each dir to /data/local/tmp,
// then `adb shell run-as quest.yarnia.yarnia cp -r /data/local/tmp/<dir> files/`.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../services/asr_session.dart';

const _zipformerDir = 'sherpa-onnx-streaming-zipformer-en-2023-06-26';
const _whisperDir = 'sherpa-onnx-whisper-base';
const _whisperSmallDir = 'sherpa-onnx-whisper-small';
const _canaryDir = 'sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8';
const _parakeetDir = 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8';
const _vadFile = 'silero_vad.onnx';
const _sampleRate = 16000;

enum _Asr {
  zipformer('Zipformer EN (streaming, fast)'),
  whisperBase('Whisper base (VAD, multilingual)'),
  whisperSmall('Whisper small (VAD, better, slower)'),
  canary('Canary 180M (VAD, EN/DE, punctuation)'),
  parakeet('Parakeet 0.6B v3 (VAD, 25 langs, auto)'),
  hybrid('Hybrid: live partials + Whisper final');

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

  AsrSession? _session;
  StreamSubscription<AsrEvent>? _eventSub;
  StreamSubscription<Uint8List>? _audioSub;

  _Asr _asr = _Asr.hybrid;
  String _canaryLang = 'en';
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
    _eventSub?.cancel();
    _recorder.dispose();
    _session?.dispose();
    super.dispose();
  }

  // Model dirs per engine; null means a required dir is missing on device.
  Future<Map<String, String>?> _dirsFor(_Asr asr) async {
    final support = (await getApplicationSupportDirectory()).path;
    String dir(String d) => p.join(support, d);
    bool has(String path) =>
        Directory(path).existsSync() || File(path).existsSync();

    final vad = dir(_vadFile);
    final result = <String, String>{};
    switch (asr) {
      case _Asr.zipformer:
        result['zipformer'] = dir(_zipformerDir);
      case _Asr.whisperBase:
        result['model'] = dir(_whisperDir);
        result['vad'] = vad;
      case _Asr.whisperSmall:
        result['model'] = dir(_whisperSmallDir);
        result['vad'] = vad;
      case _Asr.canary:
        result['model'] = dir(_canaryDir);
        result['vad'] = vad;
      case _Asr.parakeet:
        result['model'] = dir(_parakeetDir);
        result['vad'] = vad;
      case _Asr.hybrid:
        result['zipformer'] = dir(_zipformerDir);
        result['model'] = dir(_whisperDir);
        result['vad'] = vad;
    }
    return result.values.every(has) ? result : null;
  }

  Future<void> _load(_Asr asr) async {
    if (_listening) await _stop();
    setState(() {
      _busy = true;
      _asr = asr;
      _status = 'Loading ${asr.label} (in background)...';
      _partial = '';
      _metrics = '';
    });
    try {
      _eventSub?.cancel();
      _session?.dispose();
      _session = null;

      final dirs = await _dirsFor(asr);
      if (dirs == null) {
        setState(() => _status =
            '${asr.label}: model files missing on device. Push them via '
            'adb (see comment at the top of stt_spike_screen.dart).');
        return;
      }
      final session = await AsrSession.spawn(
          kind: asr.name, dirs: dirs, canaryLang: _canaryLang);
      if (!mounted) {
        session.dispose();
        return;
      }
      _eventSub = session.events.listen(_onEvent);
      setState(() {
        _session = session;
        _status = '${asr.label} ready in ${session.initMs} ms. '
            'Tap the mic and talk; everything stays on this phone.';
      });
    } catch (e) {
      debugPrint('stt spike init failed: $e');
      setState(() => _status = 'Init failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  void _onEvent(AsrEvent event) {
    if (!mounted) return;
    setState(() {
      switch (event) {
        case AsrPartial(:final text):
          _partial = text;
        case AsrSegment(:final text, :final segSec, :final decodeMs):
          _segments.insert(0, text);
          if (segSec > 0) {
            _metrics = 'last segment: ${segSec.toStringAsFixed(1)} s speech, '
                'decoded in ${(decodeMs / 1000).toStringAsFixed(2)} s '
                '(RTF ${(decodeMs / 1000 / segSec).toStringAsFixed(2)})';
          }
      }
    });
  }

  Future<void> _toggle() async {
    if (_listening) {
      await _stop();
    } else {
      await _start();
    }
  }

  Future<void> _start() async {
    final session = _session;
    if (session == null) return;
    try {
      if (!await _recorder.hasPermission()) {
        setState(() => _status = 'Microphone permission denied.');
        return;
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
        session.feed(_bytesToFloat32(Uint8List.sublistView(bytes, 0, usable)));
      });
      setState(() {
        _listening = true;
        _status = switch (_asr) {
          _Asr.zipformer => 'Listening (streaming, on-device)...',
          _Asr.hybrid =>
            'Listening (live partials, Whisper rewrites at each pause)...',
          _ => 'Listening (VAD-segmented, on-device). Pause to transcribe.',
        };
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
      _session?.flush();
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
              isExpanded: true,
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
                  DropdownMenuItem(
                    value: a,
                    child: Text(a.label, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (a) {
                      if (a != null && a != _asr) _load(a);
                    },
            ),
            if (_asr == _Asr.canary) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Language', style: label),
                  const SizedBox(width: 12),
                  for (final lang in ['en', 'de'])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(lang.toUpperCase()),
                        selected: _canaryLang == lang,
                        onSelected: _busy
                            ? null
                            : (sel) {
                                if (sel && _canaryLang != lang) {
                                  _canaryLang = lang;
                                  // Canary bakes the language into the
                                  // recognizer config; rebuild it.
                                  _load(_Asr.canary);
                                }
                              },
                      ),
                    ),
                ],
              ),
            ],
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
              onPressed: (_session == null || _busy) ? null : _toggle,
              icon: Icon(_listening ? Icons.stop : Icons.mic),
              label: Text(_listening ? 'Stop' : 'Listen'),
            ),
          ],
        ),
      ),
    );
  }
}
