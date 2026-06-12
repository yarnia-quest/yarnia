// Smoke test for the Pocket TTS engine path in TtsSession (voice cloning via
// reference wav). Needs the real model + native libs, so it self-skips unless
// both are provided; run it on a dev machine with:
//
//   LD_LIBRARY_PATH=~/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-<ver>/linux/x64 \
//   POCKET_TTS_MODEL_DIR=/tmp/sherpa-onnx-pocket-tts-int8-2026-01-26 \
//   flutter test test/pocket_tts_smoke_test.dart
//
// Model: https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models
// (sherpa-onnx-pocket-tts-int8-2026-01-26.tar.bz2)

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yarnia/services/tts_session.dart';

void main() {
  final modelDir = Platform.environment['POCKET_TTS_MODEL_DIR'];

  test('pocket TTS synthesizes with a cloned reference voice', () async {
    if (modelDir == null || !Directory(modelDir).existsSync()) {
      markTestSkipped('POCKET_TTS_MODEL_DIR not set or missing; skipping.');
      return;
    }
    final refWav = p.join(modelDir, 'test_wavs', 'bria.wav');
    expect(File(refWav).existsSync(), isTrue,
        reason: 'reference wav missing from model dir');

    final outDir = Directory.systemTemp.createTempSync('pocket-tts-test');
    final session = await TtsSession.spawn(
        kind: TtsEngineKind.pocket, modelDir: modelDir, outDir: outDir.path);
    try {
      final chunks = await session
          .speak('The little fox closed her eyes. The sea sang softly.',
              refWavPath: refWav)
          .toList();

      expect(chunks, hasLength(2), reason: 'one chunk per sentence');
      for (final c in chunks) {
        expect(c.audioSec, greaterThan(0.2));
        expect(File(c.wavPath).lengthSync(), greaterThan(1000));
      }
    } finally {
      session.dispose();
      outDir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
