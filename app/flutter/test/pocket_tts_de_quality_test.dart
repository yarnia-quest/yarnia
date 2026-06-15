// Quality probe: drive the REAL app TtsSession (sherpa_onnx plugin) with our
// fixed German model and persist the wavs to /tmp so an external check can
// confirm they're clean speech (no conv-quant background noise).
//
//   LD_LIBRARY_PATH=~/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.2/linux/x64 \
//   POCKET_TTS_MODEL_DIR=<tools>/models/german \
//   flutter test test/pocket_tts_de_quality_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yarnia/services/tts_session.dart';

void main() {
  final modelDir = Platform.environment['POCKET_TTS_MODEL_DIR'];

  test('German Pocket TTS produces clean cloned-voice audio (Dart path)',
      () async {
    if (modelDir == null || !Directory(modelDir).existsSync()) {
      markTestSkipped('POCKET_TTS_MODEL_DIR not set; skipping.');
      return;
    }
    final refWav = p.join(modelDir, 'test_wavs', 'bria.wav');
    expect(File(refWav).existsSync(), isTrue, reason: 'reference wav missing');

    final outDir = Directory.systemTemp.createTempSync('pocket-de');
    final session = await TtsSession.spawn(
        kind: TtsEngineKind.pocketDe, modelDir: modelDir, outDir: outDir.path);
    try {
      final chunks = await session
          .speak('Gute Nacht, kleiner Baer. Schlaf jetzt ein, der Mond passt auf dich auf.',
              refWavPath: refWav)
          .toList();
      expect(chunks, isNotEmpty);
      var i = 0;
      for (final c in chunks) {
        expect(c.audioSec, greaterThan(0.2));
        final dst = '/tmp/de_dart_chunk_${i++}.wav';
        File(c.wavPath).copySync(dst);
        // ignore: avoid_print
        print('DART_WAV $dst audioSec=${c.audioSec}');
      }
    } finally {
      session.dispose();
      outDir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
