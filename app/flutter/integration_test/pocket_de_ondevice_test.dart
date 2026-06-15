// On-device integration test: runs the real TtsSession (sherpa_onnx native
// plugin) on an actual Android runtime against the fixed German Pocket model,
// and copies the synthesized wav to external storage so it can be pulled and
// quality-checked off-device.
//
// Setup (push the model where the app can read it WITHOUT extra permissions):
//   PKG=quest.yarnia.yarnia
//   adb shell mkdir -p /sdcard/Android/data/$PKG/files
//   adb push <tools>/models/german /sdcard/Android/data/$PKG/files/pocket-tts-de
//   flutter test integration_test/pocket_de_ondevice_test.dart -d <device>
//   adb pull /sdcard/Android/data/$PKG/files/de_ondevice.wav /tmp/
//
// The wav lands next to the model dir in the app's external files dir.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:yarnia/services/tts_session.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('German Pocket TTS runs on-device and is clean', (tester) async {
    // Models are placed in the app SUPPORT dir (same place the real app reads
    // them via getApplicationSupportDirectory). The output wav goes to external
    // storage so it can be pulled off-device.
    final support = await getApplicationSupportDirectory();
    final ext = await getExternalStorageDirectory() ?? support;
    debugPrint('ONDEVICE_PATH supportDir=${support.path} externalDir=${ext.path}');
    final modelDir = p.join(support.path, 'pocket-tts-de');
    debugPrint('ONDEVICE_PATH modelDir=$modelDir exists=${Directory(modelDir).existsSync()}');
    if (Directory(modelDir).existsSync()) {
      debugPrint('ONDEVICE_PATH modelDir contents=${Directory(modelDir).listSync().map((e) => p.basename(e.path)).toList()}');
      final tw = Directory(p.join(modelDir, 'test_wavs'));
      debugPrint('ONDEVICE_PATH test_wavs exists=${tw.existsSync()} '
          'contents=${tw.existsSync() ? tw.listSync().map((e) => p.basename(e.path)).toList() : "N/A"}');
    }
    expect(Directory(modelDir).existsSync(), isTrue,
        reason: 'push the model to $modelDir first');
    final refWav = p.join(modelDir, 'test_wavs', 'bria.wav');
    expect(File(refWav).existsSync(), isTrue, reason: 'reference wav missing at $refWav');

    final session = await TtsSession.spawn(
        kind: TtsEngineKind.pocketDe, modelDir: modelDir, outDir: ext.path);
    try {
      final chunks = await session
          .speak('Gute Nacht, kleiner Baer. Schlaf jetzt ein.',
              refWavPath: refWav)
          .toList();
      expect(chunks, isNotEmpty);
      expect(chunks.first.audioSec, greaterThan(0.2));
      // Persist the first chunk for off-device flatness inspection.
      File(chunks.first.wavPath).copySync(p.join(ext.path, 'de_ondevice.wav'));
      debugPrint('ONDEVICE_OK chunks=${chunks.length} '
          'audioSec=${chunks.map((c) => c.audioSec).toList()}');
    } finally {
      session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
