// Device capability classification for recommending the right TTS engine.
//
// Strong devices (Pocket recommended): >= 6 cores or modern flagship chip.
// Weak devices (Piper/System recommended): fewer cores or older SoCs.
//
// Heuristic: Pixel 9 → strong; Huawei P20 Pro class → weak.
// The classification is advisory only — the user can override in Settings.

import 'dart:io';

import 'package:flutter/foundation.dart';

enum DeviceClass {
  /// Modern flagship — Pocket TTS performs well (e.g. Pixel 9, iPhone 15).
  strong,

  /// Older or low-end device — prefer Piper or System TTS.
  weak,
}

/// Classify the current device based on processor count.
/// Uses Platform.numberOfProcessors as a coarse heuristic (available without
/// platform plugins). For a more accurate classification use device_info_plus
/// to read the SoC model or RAM, but that adds a dependency.
///
/// TODO(phase3): add device_info_plus for RAM-based classification on Android.
DeviceClass classifyDevice() {
  // numberOfProcessors includes efficiency cores on modern chips.
  // Heuristic: >= 8 cores → strong; < 8 → weak.
  final cores = Platform.numberOfProcessors;
  final cls = cores >= 8 ? DeviceClass.strong : DeviceClass.weak;
  debugPrint('DeviceClass: $cores cores → $cls');
  return cls;
}
