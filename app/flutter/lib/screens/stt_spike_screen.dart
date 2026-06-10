// Spike 2 (plans/post-hackathon-soul-and-direction.md): on-device STT.
// Trimmed to the engines that can do German (EN-only Zipformer/hybrid and the
// too-slow-on-old-phones Whisper small are dropped from the UI; the code for
// them remains in services/asr_session.dart):
//
// - Whisper base (VAD): multilingual auto-detect incl. DE and TR.
// - Canary 180M (VAD): EN/DE toggle; outputs in the SELECTED language (it is
//   a translating ASR). No Turkish.
// - Parakeet 0.6B v3 (VAD): 25 European languages, auto-detect. No Turkish.
// - System STT: the platform recognizer (Google speech services / Apple
//   SFSpeechRecognizer) via speech_to_text - the comparison fallback the plan
//   doc describes. Needs the OS speech service to be present (the Duolingo
//   failure mode); EN/DE/TR selectable.
//
// Local decoding runs in a worker isolate so slow segments can never freeze
// the UI. The child's voice never leaves the device in the local modes.
//
// Models (push once): push each dir to /data/local/tmp, then
// `adb shell run-as quest.yarnia.yarnia cp -r /data/local/tmp/<dir> files/`.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../services/asr_session.dart';

const _whisperDir = 'sherpa-onnx-whisper-base';
const _canaryDir = 'sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8';
const _parakeetDir = 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8';
const _vadFile = 'silero_vad.onnx';
const _sampleRate = 16000;

enum _Asr {
  whisperBase('Whisper base (local, EN/DE/TR auto)'),
  canary('Canary 180M (local, EN/DE toggle)'),
  parakeet('Parakeet 0.6B v3 (local, 25 langs auto)'),
  device('System STT (Google / Apple speech)');

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
  final _deviceStt = SpeechToText();

  AsrSession? _session;
  StreamSubscription<AsrEvent>? _eventSub;
  StreamSubscription<Uint8List>? _audioSub;
  bool _deviceReady = false;

  _Asr _asr = _Asr.whisperBase;
  String _canaryLang = 'en';
  String _deviceLang = 'en_US';
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
    _deviceStt.stop();
    _session?.dispose();
    super.dispose();
  }

  Future<Map<String, String>?> _dirsFor(_Asr asr) async {
    final support = (await getApplicationSupportDirectory()).path;
    String dir(String d) => p.join(support, d);
    bool has(String path) =>
        Directory(path).existsSync() || File(path).existsSync();

    final result = <String, String>{'vad': dir(_vadFile)};
    switch (asr) {
      case _Asr.whisperBase:
        result['model'] = dir(_whisperDir);
      case _Asr.canary:
        result['model'] = dir(_canaryDir);
      case _Asr.parakeet:
        result['model'] = dir(_parakeetDir);
      case _Asr.device:
        return null; // not a local engine
    }
    return result.values.every(has) ? result : null;
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
      _eventSub?.cancel();
      _session?.dispose();
      _session = null;

      if (asr == _Asr.device) {
        _deviceReady = await _deviceStt.initialize(
          onError: (e) {
            debugPrint('device stt error: $e');
            if (mounted) {
              setState(() => _status = 'System STT error: ${e.errorMsg}. '
                  'Is the OS speech service installed?');
            }
          },
          onStatus: (s) {
            // The platform recognizer stops itself after a pause; restart to
            // keep a continuous session while the user has it switched on.
            if (s == 'done' && _listening && _asr == _Asr.device) {
              _deviceListen();
            }
          },
        );
        setState(() => _status = _deviceReady
            ? 'System STT ready (OS speech service found). Tap the mic. '
                'Audio is handled by Google/Apple, not locally.'
            : 'System STT unavailable: the OS speech service is missing on '
                'this device (the Duolingo failure mode).');
        return;
      }

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

  void _deviceListen() {
    _deviceStt.listen(
      onResult: (r) {
        if (!mounted) return;
        setState(() {
          if (r.finalResult) {
            if (r.recognizedWords.trim().isNotEmpty) {
              _segments.insert(0, r.recognizedWords.trim());
            }
            _partial = '';
          } else {
            _partial = r.recognizedWords;
          }
        });
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        listenMode: ListenMode.dictation,
        localeId: _deviceLang,
      ),
    );
  }

  Future<void> _start() async {
    if (_asr == _Asr.device) {
      if (!_deviceReady) return;
      _deviceListen();
      setState(() {
        _listening = true;
        _status = 'Listening via the OS recognizer ($_deviceLang)...';
      });
      return;
    }

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
        _status =
            'Listening (VAD-segmented, on-device). Pause to transcribe.';
      });
    } catch (e) {
      debugPrint('stt spike start failed: $e');
      setState(() => _status = 'Start failed: $e');
    }
  }

  Future<void> _stop() async {
    try {
      if (_asr == _Asr.device) {
        await _deviceStt.stop();
      } else {
        await _audioSub?.cancel();
        _audioSub = null;
        await _recorder.stop();
        _session?.flush();
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
    final langChips = switch (_asr) {
      _Asr.canary => ['en', 'de'],
      _Asr.device => ['en_US', 'de_DE', 'tr_TR'],
      _ => const <String>[],
    };
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
              // Keep the selected label readable while disabled during load.
              disabledHint: Text(_asr.label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 15)),
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
            if (_busy) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(minHeight: 2),
            ],
            if (langChips.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Language', style: label),
                  const SizedBox(width: 12),
                  for (final lang in langChips)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(lang.substring(0, 2).toUpperCase()),
                        selected: _asr == _Asr.canary
                            ? _canaryLang == lang
                            : _deviceLang == lang,
                        onSelected: _busy
                            ? null
                            : (sel) {
                                if (!sel) return;
                                if (_asr == _Asr.canary &&
                                    _canaryLang != lang) {
                                  _canaryLang = lang;
                                  // Canary bakes the language into the
                                  // recognizer config; rebuild it.
                                  _load(_Asr.canary);
                                } else if (_asr == _Asr.device) {
                                  setState(() => _deviceLang = lang);
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
              onPressed: (_busy ||
                      (_asr == _Asr.device
                          ? !_deviceReady
                          : _session == null))
                  ? null
                  : _toggle,
              icon: Icon(_listening ? Icons.stop : Icons.mic),
              label: Text(_listening ? 'Stop' : 'Listen'),
            ),
          ],
        ),
      ),
    );
  }
}
