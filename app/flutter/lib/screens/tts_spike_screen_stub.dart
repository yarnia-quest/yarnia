// Web stand-in for the TTS spike (sherpa_onnx is FFI, native-only). Keeps the
// conditional import in main.dart compiling for `flutter build web`.

import 'package:flutter/material.dart';

class TtsSpikeScreen extends StatelessWidget {
  const TtsSpikeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text('The TTS spike runs on-device only (Android/iOS).'),
      ),
    );
  }
}
