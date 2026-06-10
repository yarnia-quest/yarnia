// Shell for the on-device voice spikes (TTS = Speak, STT = Listen).
// Reached only when built with --dart-define=TTS_SPIKE=true.

import 'package:flutter/material.dart';

import '../theme.dart';
import 'stt_spike_screen.dart';
import 'tts_spike_screen.dart';

class SpikeHomeScreen extends StatelessWidget {
  const SpikeHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: navy,
        appBar: AppBar(
          backgroundColor: navy,
          foregroundColor: Colors.white,
          title: const Text('On-device voice spike'),
          bottom: const TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white54,
            indicatorColor: Colors.amberAccent,
            tabs: [
              Tab(icon: Icon(Icons.record_voice_over), text: 'Speak (TTS)'),
              Tab(icon: Icon(Icons.mic), text: 'Listen (STT)'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            TtsSpikeScreen(),
            SttSpikeScreen(),
          ],
        ),
      ),
    );
  }
}
