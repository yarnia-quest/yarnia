// Worker-isolate TTS for the voice spike (and the future product shape):
// the model loads and synthesizes OFF the UI thread (an 11s synth on an old
// phone was triggering ANRs when run on the main isolate), and long text is
// split into sentences that stream back one wav at a time, so playback can
// start after the first sentence while the rest still generates.

import 'dart:async';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

class TtsChunk {
  TtsChunk({
    required this.index,
    required this.wavPath,
    required this.text,
    required this.synthMs,
    required this.audioSec,
    required this.last,
  });

  final int index;
  final String wavPath;
  final String text;
  final int synthMs;
  final double audioSec;
  final bool last;
}

class TtsSession {
  TtsSession._(this._isolate, this._cmd, this._events, this.numSpeakers,
      this.initMs);

  final Isolate _isolate;
  final SendPort _cmd;
  final Stream<Map<dynamic, dynamic>> _events;
  final int numSpeakers;
  final int initMs;

  int _reqId = 0;

  /// kind: piperEn | piperDe | kokoro | kitten (mirrors the spike engines).
  static Future<TtsSession> spawn({
    required String kind,
    required String modelDir,
    required String outDir,
  }) async {
    final fromWorker = ReceivePort();
    final isolate = await Isolate.spawn(_ttsWorkerMain, {
      'sendPort': fromWorker.sendPort,
      'kind': kind,
      'modelDir': modelDir,
      'outDir': outDir,
    });
    final events =
        fromWorker.asBroadcastStream().cast<Map<dynamic, dynamic>>();
    final ready = await events.first;
    if (ready['type'] == 'error') {
      isolate.kill(priority: Isolate.immediate);
      throw Exception('TTS worker init failed: ${ready['message']}');
    }
    return TtsSession._(isolate, ready['cmd'] as SendPort, events,
        ready['numSpeakers'] as int, ready['initMs'] as int);
  }

  /// Splits [text] into sentences and streams a TtsChunk per sentence.
  Stream<TtsChunk> speak(String text, {int sid = 0, double speed = 1.0}) {
    final req = ++_reqId;
    _cmd.send({'type': 'speak', 'req': req, 'text': text, 'sid': sid,
        'speed': speed});
    return _events
        .where((m) => m['req'] == req)
        .takeWhile((m) => m['type'] != 'done')
        .where((m) => m['type'] == 'chunk')
        .map((m) => TtsChunk(
              index: m['index'] as int,
              wavPath: m['wav'] as String,
              text: m['text'] as String,
              synthMs: m['synthMs'] as int,
              audioSec: m['audioSec'] as double,
              last: m['last'] as bool,
            ));
  }

  /// Stops sentence generation of any in-flight speak() after the current
  /// sentence completes.
  void cancel() => _cmd.send({'type': 'cancel', 'req': _reqId});

  void dispose() {
    _cmd.send({'type': 'dispose'});
    // Give the worker a moment to free native memory, then make sure.
    Future.delayed(const Duration(seconds: 2),
        () => _isolate.kill(priority: Isolate.immediate));
  }
}

List<String> _splitSentences(String text) {
  final parts = text
      .split(RegExp(r'(?<=[.!?])\s+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  return parts.isEmpty ? [text.trim()] : parts;
}

Future<void> _ttsWorkerMain(Map<dynamic, dynamic> args) async {
  final out = args['sendPort'] as SendPort;
  final kind = args['kind'] as String;
  final modelDir = args['modelDir'] as String;
  final outDir = args['outDir'] as String;

  sherpa_onnx.OfflineTts tts;
  final initSw = Stopwatch()..start();
  try {
    sherpa_onnx.initBindings();
    tts = sherpa_onnx.OfflineTts(sherpa_onnx.OfflineTtsConfig(
      model: _modelConfig(kind, modelDir),
      maxNumSenetences: 1,
    ));
  } catch (e) {
    out.send({'type': 'error', 'message': '$e'});
    return;
  }
  initSw.stop();

  final cmds = ReceivePort();
  out.send({
    'type': 'ready',
    'cmd': cmds.sendPort,
    'numSpeakers': tts.numSpeakers,
    'initMs': initSw.elapsedMilliseconds,
  });

  var cancelledReq = -1;
  await for (final dynamic msg in cmds) {
    final m = msg as Map<dynamic, dynamic>;
    switch (m['type']) {
      case 'cancel':
        cancelledReq = m['req'] as int;
      case 'dispose':
        tts.free();
        cmds.close();
        return;
      case 'speak':
        final req = m['req'] as int;
        final sentences = _splitSentences(m['text'] as String);
        for (var i = 0; i < sentences.length; i++) {
          // Yield so queued cancel/dispose messages get processed between
          // sentences (the isolate is single-threaded).
          await Future<void>.delayed(Duration.zero);
          if (cancelledReq >= req) break;
          final sw = Stopwatch()..start();
          final audio =
              tts.generate(text: sentences[i], sid: m['sid'] as int,
                  speed: m['speed'] as double);
          final wav = p.join(outDir, 'tts-$req-$i.wav');
          sherpa_onnx.writeWave(
              filename: wav,
              samples: audio.samples,
              sampleRate: audio.sampleRate);
          sw.stop();
          out.send({
            'type': 'chunk',
            'req': req,
            'index': i,
            'wav': wav,
            'text': sentences[i],
            'synthMs': sw.elapsedMilliseconds,
            'audioSec': audio.samples.length / audio.sampleRate,
            'last': i == sentences.length - 1,
          });
        }
        out.send({'type': 'done', 'req': req});
    }
  }
}

sherpa_onnx.OfflineTtsModelConfig _modelConfig(String kind, String dir) {
  switch (kind) {
    case 'piperEn':
      return sherpa_onnx.OfflineTtsModelConfig(
        vits: sherpa_onnx.OfflineTtsVitsModelConfig(
          model: p.join(dir, 'en_US-libritts_r-medium.onnx'),
          tokens: p.join(dir, 'tokens.txt'),
          dataDir: p.join(dir, 'espeak-ng-data'),
        ),
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );
    case 'piperDe':
      return sherpa_onnx.OfflineTtsModelConfig(
        vits: sherpa_onnx.OfflineTtsVitsModelConfig(
          model: p.join(dir, 'de_DE-thorsten-medium.onnx'),
          tokens: p.join(dir, 'tokens.txt'),
          dataDir: p.join(dir, 'espeak-ng-data'),
        ),
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );
    case 'piperTr':
      return sherpa_onnx.OfflineTtsModelConfig(
        vits: sherpa_onnx.OfflineTtsVitsModelConfig(
          model: p.join(dir, 'tr_TR-fahrettin-medium.onnx'),
          tokens: p.join(dir, 'tokens.txt'),
          dataDir: p.join(dir, 'espeak-ng-data'),
        ),
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );
    case 'kokoro':
      return sherpa_onnx.OfflineTtsModelConfig(
        kokoro: sherpa_onnx.OfflineTtsKokoroModelConfig(
          model: p.join(dir, 'model.onnx'),
          voices: p.join(dir, 'voices.bin'),
          tokens: p.join(dir, 'tokens.txt'),
          dataDir: p.join(dir, 'espeak-ng-data'),
        ),
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );
    case 'kitten':
      return sherpa_onnx.OfflineTtsModelConfig(
        kitten: sherpa_onnx.OfflineTtsKittenModelConfig(
          model: p.join(dir, 'model.fp32.onnx'),
          voices: p.join(dir, 'voices.bin'),
          tokens: p.join(dir, 'tokens.txt'),
          dataDir: p.join(dir, 'espeak-ng-data'),
        ),
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );
    default:
      throw ArgumentError('unknown tts kind: $kind');
  }
}
