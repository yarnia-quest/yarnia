// Worker-isolate TTS — synthesis runs off the UI thread.
//
// Architecture: the worker processes one sentence at a time.  Sentences arrive
// as individual 'sentence' messages; an 'end' message closes the stream.
// Because each message is processed as soon as the previous synthesis
// finishes, the worker is always one synthesis step ahead of playback — no
// waiting for the caller to tell it what to do next.
//
// This lets two callers coexist cleanly:
//
//   • Batch (full text known upfront): speak(text) — splits and queues all
//     sentences at once, then sends 'end'.  Synthesis of sentence N+1 starts
//     the moment sentence N's synthesis finishes, regardless of whether
//     playback has caught up.
//
//   • Streaming (LLM output): speakStream(Stream<String> sentences) — each
//     sentence is queued as the LLM emits it.  The worker synthesizes sentence
//     N while the LLM is still generating sentence N+1; if N+1 arrives before
//     N finishes the worker starts it with zero dead time.
//
// TO ADD A NEW ENGINE: add a value to TtsEngineKind and implement its case
// in the modelConfig() method. The exhaustive switch refuses to compile until
// every value has a case.

import 'dart:async';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

/// One entry per supported TTS backend. Adding a value here forces a compiler
/// error in [modelConfig] until the new case is handled.
enum TtsEngineKind {
  piperEn,
  piperDe,
  piperTr,
  kokoro,
  kitten,
  pocket,      // Kyutai Pocket TTS — sherpa-onnx int8 export (EN)
  pocketDe,    // Pocket TTS German 6-layer (our export)
  pocketDe24l, // Pocket TTS German 24-layer (our export)
  pocketFr24l, // Pocket TTS French 24-layer (our export)
  pocketEs;    // Pocket TTS Spanish 6-layer (our export)

  bool get isPocket => switch (this) {
    pocket || pocketDe || pocketDe24l || pocketFr24l || pocketEs => true,
    _ => false,
  };

  sherpa_onnx.OfflineTtsModelConfig modelConfig(String dir) =>
      switch (this) {
        TtsEngineKind.piperEn => sherpa_onnx.OfflineTtsModelConfig(
            vits: sherpa_onnx.OfflineTtsVitsModelConfig(
              model: p.join(dir, 'en_US-libritts_r-medium.onnx'),
              tokens: p.join(dir, 'tokens.txt'),
              dataDir: p.join(dir, 'espeak-ng-data'),
            ),
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
        TtsEngineKind.piperDe => sherpa_onnx.OfflineTtsModelConfig(
            vits: sherpa_onnx.OfflineTtsVitsModelConfig(
              model: p.join(dir, 'de_DE-thorsten-medium.onnx'),
              tokens: p.join(dir, 'tokens.txt'),
              dataDir: p.join(dir, 'espeak-ng-data'),
            ),
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
        TtsEngineKind.piperTr => sherpa_onnx.OfflineTtsModelConfig(
            vits: sherpa_onnx.OfflineTtsVitsModelConfig(
              model: p.join(dir, 'tr_TR-fahrettin-medium.onnx'),
              tokens: p.join(dir, 'tokens.txt'),
              dataDir: p.join(dir, 'espeak-ng-data'),
            ),
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
        TtsEngineKind.kokoro => sherpa_onnx.OfflineTtsModelConfig(
            kokoro: sherpa_onnx.OfflineTtsKokoroModelConfig(
              model: p.join(dir, 'model.onnx'),
              voices: p.join(dir, 'voices.bin'),
              tokens: p.join(dir, 'tokens.txt'),
              dataDir: p.join(dir, 'espeak-ng-data'),
            ),
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
        TtsEngineKind.kitten => sherpa_onnx.OfflineTtsModelConfig(
            kitten: sherpa_onnx.OfflineTtsKittenModelConfig(
              model: p.join(dir, 'model.fp32.onnx'),
              voices: p.join(dir, 'voices.bin'),
              tokens: p.join(dir, 'tokens.txt'),
              dataDir: p.join(dir, 'espeak-ng-data'),
            ),
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
        TtsEngineKind.pocket ||
        TtsEngineKind.pocketDe ||
        TtsEngineKind.pocketDe24l ||
        TtsEngineKind.pocketFr24l ||
        TtsEngineKind.pocketEs =>
          sherpa_onnx.OfflineTtsModelConfig(
            pocket: sherpa_onnx.OfflineTtsPocketModelConfig(
              lmFlow: p.join(dir, 'lm_flow.int8.onnx'),
              lmMain: p.join(dir, 'lm_main.int8.onnx'),
              encoder: p.join(dir, 'encoder.onnx'),
              decoder: p.join(dir, 'decoder.int8.onnx'),
              textConditioner: p.join(dir, 'text_conditioner.onnx'),
              vocabJson: p.join(dir, 'vocab.json'),
              tokenScoresJson: p.join(dir, 'token_scores.json'),
            ),
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
      };
}

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

/// Splits text into sentences on sentence-ending punctuation.
List<String> splitSentences(String text) {
  final parts = text
      .split(RegExp(r'(?<=[.!?])\s+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  return parts.isEmpty ? [text.trim()] : parts;
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

  static Future<TtsSession> spawn({
    required TtsEngineKind kind,
    required String modelDir,
    required String outDir,
  }) async {
    final fromWorker = ReceivePort();
    final isolate = await Isolate.spawn(_ttsWorkerMain, {
      'sendPort': fromWorker.sendPort,
      'kind': kind.index,
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

  /// Streams [sentences] through the worker one at a time.
  ///
  /// The worker starts synthesizing each sentence the moment the previous one
  /// finishes — without waiting for playback to catch up. Sentences are queued
  /// in the worker as they arrive from [sentences], so this works equally well
  /// for a pre-split list or a live Stream<String> from an LLM.
  ///
  /// [refWavPath] is the zero-shot voice-cloning reference for pocket engines.
  Stream<TtsChunk> speakStream(
    Stream<String> sentences, {
    int sid = 0,
    double speed = 1.0,
    String? refWavPath,
  }) {
    final req = ++_reqId;
    final ctrl = StreamController<TtsChunk>();

    // Feed sentences to worker as they arrive.
    sentences.listen(
      (sentence) => _cmd.send({
        'type': 'sentence',
        'req': req,
        'text': sentence,
        'sid': sid,
        'speed': speed,
        'refWav': refWavPath,
      }),
      onDone: () => _cmd.send({'type': 'end', 'req': req}),
      onError: (_) => _cmd.send({'type': 'end', 'req': req}),
    );

    // Forward worker events to the output stream.
    _events
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
            ))
        .pipe(ctrl);

    return ctrl.stream;
  }

  /// Convenience: splits [text] into sentences and calls [speakStream].
  Stream<TtsChunk> speak(
    String text, {
    int sid = 0,
    double speed = 1.0,
    String? refWavPath,
  }) {
    final sc = StreamController<String>();
    for (final s in splitSentences(text)) { sc.add(s); }
    sc.close();
    return speakStream(sc.stream, sid: sid, speed: speed, refWavPath: refWavPath);
  }

  void cancel() => _cmd.send({'type': 'cancel', 'req': _reqId});

  void dispose() {
    _cmd.send({'type': 'dispose'});
    Future.delayed(const Duration(seconds: 2),
        () => _isolate.kill(priority: Isolate.immediate));
  }
}

Future<void> _ttsWorkerMain(Map<dynamic, dynamic> args) async {
  final out = args['sendPort'] as SendPort;
  final kind = TtsEngineKind.values[args['kind'] as int];
  final modelDir = args['modelDir'] as String;
  final outDir = args['outDir'] as String;

  sherpa_onnx.OfflineTts tts;
  final initSw = Stopwatch()..start();
  try {
    sherpa_onnx.initBindings();
    tts = sherpa_onnx.OfflineTts(sherpa_onnx.OfflineTtsConfig(
      model: kind.modelConfig(modelDir),
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
  var chunkIndex = 0;
  // Pocket voice cache: decode the reference wav once per path change.
  String? refPath;
  sherpa_onnx.WaveData? refWave;

  await for (final dynamic msg in cmds) {
    final m = msg as Map<dynamic, dynamic>;
    switch (m['type']) {
      case 'cancel':
        cancelledReq = m['req'] as int;
        chunkIndex = 0;
      case 'end':
        // All sentences for this request have been processed.
        out.send({'type': 'done', 'req': m['req']});
        chunkIndex = 0;
      case 'dispose':
        tts.free();
        cmds.close();
        return;
      case 'sentence':
        final req = m['req'] as int;
        if (cancelledReq >= req) continue;

        final reqRefPath = m['refWav'] as String?;
        if (reqRefPath != null && reqRefPath != refPath) {
          try {
            refWave = sherpa_onnx.readWave(reqRefPath);
            refPath = reqRefPath;
          } catch (e) {
            // ignore: avoid_print
            print('tts worker: cannot read ref wav $reqRefPath: $e');
            continue;
          }
        }
        final ref = reqRefPath != null ? refWave : null;

        final sw = Stopwatch()..start();
        final audio = ref != null
            ? tts.generateWithConfig(
                text: m['text'] as String,
                config: sherpa_onnx.OfflineTtsGenerationConfig(
                  sid: m['sid'] as int,
                  speed: m['speed'] as double,
                  referenceAudio: ref.samples,
                  referenceSampleRate: ref.sampleRate,
                  extra: const {'max_reference_audio_len': 20},
                ))
            : tts.generate(
                text: m['text'] as String,
                sid: m['sid'] as int,
                speed: m['speed'] as double);

        final wav = p.join(outDir, 'tts-$req-$chunkIndex.wav');
        sherpa_onnx.writeWave(
            filename: wav, samples: audio.samples, sampleRate: audio.sampleRate);
        sw.stop();

        out.send({
          'type': 'chunk',
          'req': req,
          'index': chunkIndex++,
          'wav': wav,
          'text': m['text'],
          'synthMs': sw.elapsedMilliseconds,
          'audioSec': audio.samples.length / audio.sampleRate,
          'last': false, // 'end' message closes the stream, not a flag
        });
    }
  }
}
