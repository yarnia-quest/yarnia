// Web stand-in for the voice spikes (sherpa_onnx is FFI, native-only). Keeps
// the conditional import in main.dart compiling for `flutter build web`.

import 'package:flutter/material.dart';

class SpikeHomeScreen extends StatelessWidget {
  const SpikeHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text('The voice spikes run on-device only (Android/iOS).'),
      ),
    );
  }
}
