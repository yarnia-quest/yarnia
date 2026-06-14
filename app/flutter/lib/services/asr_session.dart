// Worker-isolate ASR for the voice spike: model load, VAD and decoding all
// run OFF the UI thread (a Whisper-small segment took 11s to decode on a
// Kirin 970 and triggered an ANR when decoded on the main isolate). The main
// isolate streams mic samples in; the worker streams back partials, final
// segments, and per-segment timing.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

const _sampleRate = 16000;

sealed class AsrEvent {}

class AsrPartial extends AsrEvent {
  AsrPartial(this.text);
  final String text;
}

class AsrSegment extends AsrEvent {
  AsrSegment(this.text, this.segSec, this.decodeMs);
  final String text;
  final double segSec;
  final int decodeMs;
}

class AsrSession {
  AsrSession._(this._isolate, this._cmd, this.events, this.initMs);

  final Isolate _isolate;
  final SendPort _cmd;
  final Stream<AsrEvent> events;
  final int initMs;

  /// kind: zipformer | whisperBase | whisperSmall | canary | parakeet | hybrid
  /// dirs: kind-dependent model directories (see _buildEngines).
  static Future<AsrSession> spawn({
    required String kind,
    required Map<String, String> dirs,
    String canaryLang = 'en',
    String? whisperLang,
  }) async {
    final fromWorker = ReceivePort();
    final isolate = await Isolate.spawn(_asrWorkerMain, {
      'sendPort': fromWorker.sendPort,
      'kind': kind,
      'dirs': dirs,
      'canaryLang': canaryLang,
      'whisperLang': whisperLang ?? '',
    });
    final raw = fromWorker.asBroadcastStream().cast<Map<dynamic, dynamic>>();
    final ready = await raw.first;
    if (ready['type'] == 'error') {
      isolate.kill(priority: Isolate.immediate);
      throw Exception('ASR worker init failed: ${ready['message']}');
    }
    final events = raw.map<AsrEvent?>((m) {
      switch (m['type']) {
        case 'partial':
          return AsrPartial(m['text'] as String);
        case 'segment':
          return AsrSegment(m['text'] as String, m['segSec'] as double,
              m['decodeMs'] as int);
        default:
          return null;
      }
    }).where((e) => e != null).cast<AsrEvent>();
    return AsrSession._(
        isolate, ready['cmd'] as SendPort, events, ready['initMs'] as int);
  }

  void feed(Float32List samples) =>
      _cmd.send({'type': 'audio', 'samples': samples});

  /// Flush a trailing VAD segment (call on mic stop).
  void flush() => _cmd.send({'type': 'flush'});

  void dispose() {
    _cmd.send({'type': 'dispose'});
    Future.delayed(const Duration(seconds: 2),
        () => _isolate.kill(priority: Isolate.immediate));
  }
}

class _Engines {
  sherpa_onnx.OnlineRecognizer? online;
  sherpa_onnx.OnlineStream? onlineStream;
  sherpa_onnx.OfflineRecognizer? offline;
  sherpa_onnx.VoiceActivityDetector? vad;
  sherpa_onnx.CircularBuffer? vadBuffer;
  int vadWindowSize = 512;
  bool emitOnlineFinals = false;

  void free() {
    onlineStream?.free();
    online?.free();
    offline?.free();
    vad?.free();
    vadBuffer?.free();
  }
}

Future<void> _asrWorkerMain(Map<dynamic, dynamic> args) async {
  final out = args['sendPort'] as SendPort;
  final kind = args['kind'] as String;
  final dirs = (args['dirs'] as Map).cast<String, String>();
  final canaryLang = args['canaryLang'] as String;
  final whisperLang = (args['whisperLang'] as String?) ?? '';

  final engines = _Engines();
  final initSw = Stopwatch()..start();
  try {
    sherpa_onnx.initBindings();
    _buildEngines(engines, kind, dirs, canaryLang, whisperLang);
  } catch (e) {
    out.send({'type': 'error', 'message': '$e'});
    return;
  }
  initSw.stop();

  final cmds = ReceivePort();
  out.send({
    'type': 'ready',
    'cmd': cmds.sendPort,
    'initMs': initSw.elapsedMilliseconds,
  });

  var lastPartial = '';
  void emitPartial(String text) {
    if (text != lastPartial) {
      lastPartial = text;
      out.send({'type': 'partial', 'text': text});
    }
  }

  void feedOnline(Float32List samples) {
    final rec = engines.online;
    final stream = engines.onlineStream;
    if (rec == null || stream == null) return;
    stream.acceptWaveform(samples: samples, sampleRate: _sampleRate);
    while (rec.isReady(stream)) {
      rec.decode(stream);
    }
    final text = rec.getResult(stream).text;
    if (rec.isEndpoint(stream)) {
      rec.reset(stream);
      if (text.trim().isNotEmpty && engines.emitOnlineFinals) {
        out.send({
          'type': 'segment',
          'text': text.trim(),
          'segSec': 0.0,
          'decodeMs': 0,
        });
      }
      emitPartial('');
    } else {
      emitPartial(text);
    }
  }

  void drainVad() {
    final vad = engines.vad;
    final rec = engines.offline;
    if (vad == null || rec == null) return;
    while (!vad.isEmpty()) {
      final segment = vad.front();
      vad.pop();
      final segSec = segment.samples.length / _sampleRate;
      final sw = Stopwatch()..start();
      final stream = rec.createStream();
      stream.acceptWaveform(samples: segment.samples, sampleRate: _sampleRate);
      rec.decode(stream);
      final text = rec.getResult(stream).text.trim();
      stream.free();
      sw.stop();
      if (text.isNotEmpty) {
        out.send({
          'type': 'segment',
          'text': text,
          'segSec': segSec,
          'decodeMs': sw.elapsedMilliseconds,
        });
      }
    }
  }

  void feedOffline(Float32List samples) {
    final vad = engines.vad;
    final buffer = engines.vadBuffer;
    if (vad == null || buffer == null) return;
    buffer.push(samples);
    while (buffer.size >= engines.vadWindowSize) {
      final window =
          buffer.get(startIndex: buffer.head, n: engines.vadWindowSize);
      buffer.pop(engines.vadWindowSize);
      vad.acceptWaveform(window);
    }
    drainVad();
    if (engines.online == null) {
      emitPartial(vad.isDetected() ? '(listening...)' : '');
    }
  }

  await for (final dynamic msg in cmds) {
    final m = msg as Map<dynamic, dynamic>;
    switch (m['type']) {
      case 'audio':
        final samples = m['samples'] as Float32List;
        if (engines.online != null) feedOnline(samples);
        if (engines.offline != null) feedOffline(samples);
      case 'flush':
        engines.vad?.flush();
        drainVad();
        emitPartial('');
      case 'dispose':
        engines.free();
        cmds.close();
        return;
    }
  }
}

void _buildEngines(_Engines e, String kind, Map<String, String> dirs,
    String canaryLang, String whisperLang) {
  sherpa_onnx.OfflineRecognizerConfig whisper(String dir, String prefix) =>
      sherpa_onnx.OfflineRecognizerConfig(
        model: sherpa_onnx.OfflineModelConfig(
          whisper: sherpa_onnx.OfflineWhisperModelConfig(
            encoder: p.join(dir, '$prefix-encoder.int8.onnx'),
            decoder: p.join(dir, '$prefix-decoder.int8.onnx'),
            // Pin the language when known to avoid unstable per-segment detection.
            language: whisperLang,
            task: 'transcribe',
          ),
          tokens: p.join(dir, '$prefix-tokens.txt'),
          modelType: 'whisper',
          numThreads: 2,
        ),
      );

  void buildOnline() {
    final dir = dirs['zipformer']!;
    e.online = sherpa_onnx.OnlineRecognizer(
      sherpa_onnx.OnlineRecognizerConfig(
        model: sherpa_onnx.OnlineModelConfig(
          transducer: sherpa_onnx.OnlineTransducerModelConfig(
            encoder:
                p.join(dir, 'encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx'),
            decoder:
                p.join(dir, 'decoder-epoch-99-avg-1-chunk-16-left-128.onnx'),
            joiner:
                p.join(dir, 'joiner-epoch-99-avg-1-chunk-16-left-128.onnx'),
          ),
          tokens: p.join(dir, 'tokens.txt'),
          modelType: 'zipformer2',
        ),
        ruleFsts: '',
      ),
    );
    e.onlineStream = e.online!.createStream();
  }

  void buildVad() {
    final vadConfig = sherpa_onnx.VadModelConfig(
      sileroVad: sherpa_onnx.SileroVadModelConfig(
        model: dirs['vad']!,
        minSilenceDuration: 0.4,
        minSpeechDuration: 0.25,
        maxSpeechDuration: 12.0,
      ),
      numThreads: 1,
      debug: false,
    );
    e.vadWindowSize = vadConfig.sileroVad.windowSize;
    e.vad = sherpa_onnx.VoiceActivityDetector(
        config: vadConfig, bufferSizeInSeconds: 30);
    e.vadBuffer = sherpa_onnx.CircularBuffer(capacity: 30 * _sampleRate);
  }

  switch (kind) {
    case 'zipformer':
      buildOnline();
      e.emitOnlineFinals = true;
    case 'whisperBase':
      e.offline = sherpa_onnx.OfflineRecognizer(whisper(dirs['model']!, 'base'));
      buildVad();
    case 'whisperSmall':
      e.offline =
          sherpa_onnx.OfflineRecognizer(whisper(dirs['model']!, 'small'));
      buildVad();
    case 'canary':
      final dir = dirs['model']!;
      e.offline = sherpa_onnx.OfflineRecognizer(
        sherpa_onnx.OfflineRecognizerConfig(
          model: sherpa_onnx.OfflineModelConfig(
            canary: sherpa_onnx.OfflineCanaryModelConfig(
              encoder: p.join(dir, 'encoder.int8.onnx'),
              decoder: p.join(dir, 'decoder.int8.onnx'),
              srcLang: canaryLang,
              tgtLang: canaryLang,
              usePnc: true,
            ),
            tokens: p.join(dir, 'tokens.txt'),
            numThreads: 2,
          ),
        ),
      );
      buildVad();
    case 'parakeet':
      final dir = dirs['model']!;
      e.offline = sherpa_onnx.OfflineRecognizer(
        sherpa_onnx.OfflineRecognizerConfig(
          model: sherpa_onnx.OfflineModelConfig(
            transducer: sherpa_onnx.OfflineTransducerModelConfig(
              encoder: p.join(dir, 'encoder.int8.onnx'),
              decoder: p.join(dir, 'decoder.int8.onnx'),
              joiner: p.join(dir, 'joiner.int8.onnx'),
            ),
            tokens: p.join(dir, 'tokens.txt'),
            modelType: 'nemo_transducer',
            numThreads: 2,
          ),
        ),
      );
      buildVad();
    case 'hybrid':
      buildOnline();
      e.emitOnlineFinals = false;
      e.offline = sherpa_onnx.OfflineRecognizer(whisper(dirs['model']!, 'base'));
      buildVad();
    default:
      throw ArgumentError('unknown asr kind: $kind');
  }
}
