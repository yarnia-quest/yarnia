import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'device_class.dart';
import 'tts_session.dart';

// Files to download from HuggingFace for each Pocket TTS model.
// Path inside the repo → relative path inside the local model dir.
const _pocketFiles = [
  'lm_flow.int8.onnx',
  'lm_main.int8.onnx',
  'encoder.onnx',
  'decoder.int8.onnx',
  'text_conditioner.onnx',
  'vocab.json',
  'token_scores.json',
  'test_wavs/bria.wav',
];

// sherpa-onnx Whisper base (int8) files, downloaded into the model dir.
const _whisperBaseFiles = [
  'base-encoder.int8.onnx',
  'base-decoder.int8.onnx',
  'base-tokens.txt',
];

// Silero VAD — shared by the offline STT path; lives at the app support root
// (not inside the model dir), matching where _initWhisper looks for it.
const sileroVadUrl =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx';
const sileroVadFile = 'silero_vad.onnx';

enum TtsEngine {
  system(
    label: 'System TTS',
    modelDir: null,
    sizeMb: 0,
    quality: 'Built-in, varies by device',
    hfRepo: null,
    modelFiles: null,
  ),
  pocketEn(
    label: 'Pocket EN',
    modelDir: 'pocket-tts-en',
    sizeMb: 160,
    quality: 'Expressive, voice cloning',
    hfRepo: 'csukuangfj2/sherpa-onnx-pocket-tts-int8-2026-01-26',
    modelFiles: _pocketFiles,
  ),
  pocketDe(
    label: 'Pocket DE',
    modelDir: 'pocket-tts-de',
    sizeMb: 160,
    quality: 'Expressive, voice cloning',
    hfRepo: null, // TODO(hf-upload): publish this Pocket export to HuggingFace, then set hfRepo to enable in-app download
    modelFiles: _pocketFiles,
  ),
  pocketFr(
    label: 'Pocket FR',
    modelDir: 'pocket-tts-fr-24l',
    sizeMb: 400,
    quality: 'Expressive, voice cloning',
    hfRepo: null, // TODO(hf-upload): publish this Pocket export to HuggingFace, then set hfRepo to enable in-app download
    modelFiles: _pocketFiles,
  ),
  pocketEs(
    label: 'Pocket ES',
    modelDir: 'pocket-tts-es',
    sizeMb: 160,
    quality: 'Expressive, voice cloning',
    hfRepo: null, // TODO(hf-upload): publish this Pocket export to HuggingFace, then set hfRepo to enable in-app download
    modelFiles: _pocketFiles,
  ),

  // ── Piper VITS (light, ~80 MB, good for weaker devices) ─────────────────
  // sherpa-onnx Piper packages: model .onnx + tokens.txt + espeak-ng-data/ tree.
  // modelFiles is null — the file list (incl. the espeak-ng-data tree) is fetched
  // recursively from the HuggingFace tree API at download time (see settings_screen).
  // Recommended for low-core / low-RAM devices (see device_class.dart).
  piperEn(
    label: 'Piper EN',
    modelDir: 'piper-en',
    sizeMb: 80,
    quality: 'Natural, fast, offline',
    hfRepo: 'csukuangfj/vits-piper-en_US-libritts_r-medium',
    modelFiles: null,
  ),
  piperDe(
    label: 'Piper DE',
    modelDir: 'piper-de',
    sizeMb: 80,
    quality: 'Natural, fast, offline',
    hfRepo: 'csukuangfj/vits-piper-de_DE-thorsten-medium',
    modelFiles: null,
  ),
  piperFr(
    label: 'Piper FR',
    modelDir: 'piper-fr',
    sizeMb: 80,
    quality: 'Natural, fast, offline',
    // No French Piper voice is wired in the TTS worker yet (only EN/DE/TR kinds
    // exist in tts_session.dart). Keep non-downloadable until that is added.
    hfRepo: null, // TODO(piper-fr): add TtsEngineKind.piperFr + voice, then set hfRepo
    modelFiles: null,
  );

  const TtsEngine({
    required this.label,
    required this.modelDir,
    required this.sizeMb,
    required this.quality,
    required this.hfRepo,
    required this.modelFiles,
  });

  final String label;
  final String? modelDir;
  final int sizeMb;
  final String quality;
  // HuggingFace repo ID — null until we publish the model.
  final String? hfRepo;
  // Files to fetch from the repo (null == same as hfRepo being null).
  final List<String>? modelFiles;

  bool get isSystem => this == TtsEngine.system;
  bool get canDownload => hfRepo != null;

  TtsEngineKind? get kind => switch (this) {
        TtsEngine.system => null,
        TtsEngine.pocketEn => TtsEngineKind.pocket,
        TtsEngine.pocketDe => TtsEngineKind.pocketDe,
        TtsEngine.pocketFr => TtsEngineKind.pocketFr24l,
        TtsEngine.pocketEs => TtsEngineKind.pocketEs,
        TtsEngine.piperEn => TtsEngineKind.piperEn,
        TtsEngine.piperDe => TtsEngineKind.piperDe,
        // Piper FR reuses piperEn kind — same VITS model architecture.
        // TODO(plan): add piperFr to TtsEngineKind when the FR model is verified.
        TtsEngine.piperFr => TtsEngineKind.piperEn,
      };

  bool get isPiper => switch (this) {
        TtsEngine.piperEn || TtsEngine.piperDe || TtsEngine.piperFr => true,
        _ => false,
      };

  // Piper packages are many files (incl. the espeak-ng-data tree), so enumerate
  // them from the HuggingFace tree API rather than a static list.
  bool get needsRecursiveDownload => isPiper;

  // File whose presence on disk marks the model as fully installed. Must match the
  // model filename the TTS worker loads (see tts_session.dart) for Piper.
  String get installSentinel => switch (this) {
        TtsEngine.piperEn => 'en_US-libritts_r-medium.onnx',
        TtsEngine.piperDe => 'de_DE-thorsten-medium.onnx',
        TtsEngine.piperFr => 'fr_FR-medium.onnx',
        _ => 'vocab.json', // Pocket models
      };

  int get seed => this == TtsEngine.pocketFr ? 2 : 1;
}

enum SttEngine {
  system(
    label: 'System STT',
    modelDir: null,
    sizeMb: 0,
    quality: 'Google / Apple built-in',
    hfRepo: null,
    modelFiles: null,
  ),
  whisperBase(
    label: 'Whisper Base',
    modelDir: 'sherpa-onnx-whisper-base',
    sizeMb: 160,
    quality: 'Offline, on-device, multilingual',
    hfRepo: 'csukuangfj/sherpa-onnx-whisper-base',
    modelFiles: _whisperBaseFiles,
  );

  const SttEngine({
    required this.label,
    required this.modelDir,
    required this.sizeMb,
    required this.quality,
    required this.hfRepo,
    required this.modelFiles,
  });

  final String label;
  final String? modelDir;
  final int sizeMb;
  final String quality;
  final String? hfRepo;
  final List<String>? modelFiles;

  bool get isSystem => this == SttEngine.system;
  bool get canDownload => hfRepo != null;

  // File whose presence in the model dir marks the model as installed.
  String get installSentinel => 'base-encoder.int8.onnx';
}

class SettingsService extends ChangeNotifier {
  static const _langKey = 'language';
  static const _ttsKey = 'ttsEngine';
  static const _sttKey = 'sttEngine';
  // Phase 2b: hands-free VAD interrupt toggle. Default OFF until tuned.
  static const _handsFreeKey = 'handsFreeInterrupt';
  static const _supportedLanguages = {'en', 'de', 'fr', 'es'};

  late SharedPreferences _prefs;
  String _language = 'en';
  TtsEngine _ttsEngine = TtsEngine.system;
  SttEngine _sttEngine = SttEngine.system;
  String _appSupportDir = '';
  // Hands-free VAD interrupt: keep mic open during narration so the child can
  // interrupt by speaking. Default off — enable once AEC tuning is complete.
  bool _handsFreeInterrupt = false;

  // Phase 3: device class drives the "Recommended" badge and smart default.
  late DeviceClass _deviceClass;

  String get language => _language;
  TtsEngine get ttsEngine => _ttsEngine;
  SttEngine get sttEngine => _sttEngine;
  String get appSupportDir => _appSupportDir;
  bool get handsFreeInterrupt => _handsFreeInterrupt;
  DeviceClass get deviceClass => _deviceClass;

  /// The engine recommended for this device.
  /// Strong → Pocket EN (expressive, handles 160 MB fine).
  /// Weak → Piper EN (small, fast enough for low-end SoCs).
  TtsEngine get recommendedEngine =>
      _deviceClass == DeviceClass.strong ? TtsEngine.pocketEn : TtsEngine.piperEn;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final dir = await getApplicationSupportDirectory();
    _appSupportDir = dir.path;

    // Phase 3: classify device once on load. Used for "Recommended" badge and
    // smart default (first run only — never overrides a saved preference).
    _deviceClass = classifyDevice();

    final savedLang = _prefs.getString(_langKey);
    if (savedLang != null && _supportedLanguages.contains(savedLang)) {
      _language = savedLang;
    } else {
      final locale =
          WidgetsBinding.instance.platformDispatcher.locale.languageCode;
      _language = _supportedLanguages.contains(locale) ? locale : 'en';
    }

    final savedTts = _prefs.getInt(_ttsKey);
    if (savedTts != null && savedTts < TtsEngine.values.length) {
      _ttsEngine = TtsEngine.values[savedTts];
    } else {
      // Phase 3: no saved TTS preference → seed with recommended engine for
      // this device (Pocket for strong; Piper for weak). Falls back to system
      // if the recommended engine is not yet installed (user will see Download).
      _ttsEngine = recommendedEngine;
    }

    final savedStt = _prefs.getInt(_sttKey);
    if (savedStt != null && savedStt < SttEngine.values.length) {
      _sttEngine = SttEngine.values[savedStt];
    }

    _handsFreeInterrupt = _prefs.getBool(_handsFreeKey) ?? false;

    notifyListeners();
  }

  Future<void> setLanguage(String lang) async {
    if (!_supportedLanguages.contains(lang)) return;
    _language = lang;
    await _prefs.setString(_langKey, lang);
    notifyListeners();
  }

  Future<void> setTtsEngine(TtsEngine engine) async {
    _ttsEngine = engine;
    await _prefs.setInt(_ttsKey, engine.index);
    notifyListeners();
  }

  Future<void> setSttEngine(SttEngine engine) async {
    _sttEngine = engine;
    await _prefs.setInt(_sttKey, engine.index);
    notifyListeners();
  }

  Future<void> setHandsFreeInterrupt(bool enabled) async {
    _handsFreeInterrupt = enabled;
    await _prefs.setBool(_handsFreeKey, enabled);
    notifyListeners();
  }

  bool isEngineInstalled(TtsEngine engine) {
    if (engine.modelDir == null) return true;
    return File('$_appSupportDir/${engine.modelDir}/${engine.installSentinel}')
        .existsSync();
  }

  bool isSttEngineInstalled(SttEngine engine) {
    if (engine.modelDir == null) return true;
    // Need both the model (sentinel file) and the shared Silero VAD at the root.
    final model =
        File('$_appSupportDir/${engine.modelDir}/${engine.installSentinel}')
            .existsSync();
    final vad = File('$_appSupportDir/$sileroVadFile').existsSync();
    return model && vad;
  }

  TtsEngine get effectiveEngine {
    if (_ttsEngine == TtsEngine.system) return TtsEngine.system;
    if (isEngineInstalled(_ttsEngine)) return _ttsEngine;
    return TtsEngine.system;
  }

  SttEngine get effectiveSttEngine {
    if (_sttEngine == SttEngine.system) return SttEngine.system;
    if (isSttEngineInstalled(_sttEngine)) return _sttEngine;
    return SttEngine.system;
  }

  void refreshInstalled() => notifyListeners();

  String get locale => switch (_language) {
        'de' => 'de-DE',
        'fr' => 'fr-FR',
        'es' => 'es-ES',
        _ => 'en-US',
      };
}
