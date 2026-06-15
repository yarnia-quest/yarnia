// Device capability classification — drives TTS/LLM engine recommendations.
//
// Strong: modern flagship with known good GPU inference (Pixel, Samsung S-class, etc.)
// Weak: older SoC, non-flagship brand, or brands known for MediaPipe issues.
//
// The classification is advisory — the user can always override in Settings.

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

enum DeviceClass {
  /// Modern flagship — Pocket TTS + on-device LLM perform well.
  strong,

  /// Older, low-end, or brand with limited GPU inference support — prefer Piper or System TTS.
  weak,
}

// Brands where GPU-based MediaPipe inference is unreliable or unsupported.
// Huawei (Kirin post-2018), Oppo, Vivo, Xiaomi budget lines have varying support.
// These devices can still use CPU-based Piper TTS fine.
const _weakBrands = {'huawei', 'honor', 'oppo', 'vivo', 'realme', 'tecno', 'itel'};

/// Async classification using device_info_plus for brand-aware results.
/// Prefer this on Android for accurate recommendations. Falls back to core count.
Future<DeviceClass> classifyDeviceAsync() async {
  if (!Platform.isAndroid) return classifyDevice();
  try {
    final info = await DeviceInfoPlugin().androidInfo;
    final brand = info.brand.toLowerCase();
    if (_weakBrands.contains(brand)) {
      debugPrint('DeviceClass: brand=$brand → weak');
      return DeviceClass.weak;
    }
    // Brand looks fine — fall back to core count for further discrimination.
    return classifyDevice();
  } catch (e) {
    debugPrint('DeviceClass: device_info_plus failed ($e), using core count');
    return classifyDevice();
  }
}

/// Synchronous fallback (used at startup before the async result is available).
/// Uses Platform.numberOfProcessors — >= 8 → strong; < 8 → weak.
DeviceClass classifyDevice() {
  final cores = Platform.numberOfProcessors;
  final cls = cores >= 8 ? DeviceClass.strong : DeviceClass.weak;
  debugPrint('DeviceClass: $cores cores → $cls');
  return cls;
}
