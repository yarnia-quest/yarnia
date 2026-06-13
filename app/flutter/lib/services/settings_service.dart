import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'tts_session.dart';

enum TtsEngine {
  system(
    label: 'System TTS',
    modelDir: null,
    sizeMb: 0,
    quality: 'Built-in, varies by device',
  ),
  pocketEn(
    label: 'Pocket EN',
    modelDir: 'pocket-tts-en',
    sizeMb: 160,
    quality: 'Expressive, voice cloning',
  ),
  pocketDe(
    label: 'Pocket DE',
    modelDir: 'pocket-tts-de',
    sizeMb: 160,
    quality: 'Expressive, voice cloning',
  ),
  pocketFr(
    label: 'Pocket FR',
    modelDir: 'pocket-tts-fr-24l',
    sizeMb: 400,
    quality: 'Expressive, voice cloning',
  ),
  pocketEs(
    label: 'Pocket ES',
    modelDir: 'pocket-tts-es',
    sizeMb: 160,
    quality: 'Expressive, voice cloning',
  );

  const TtsEngine({
    required this.label,
    required this.modelDir,
    required this.sizeMb,
    required this.quality,
  });

  final String label;
  final String? modelDir;
  final int sizeMb;
  final String quality;

  bool get isSystem => this == TtsEngine.system;

  TtsEngineKind? get kind => switch (this) {
        TtsEngine.system => null,
        TtsEngine.pocketEn => TtsEngineKind.pocket,
        TtsEngine.pocketDe => TtsEngineKind.pocketDe,
        TtsEngine.pocketFr => TtsEngineKind.pocketFr24l,
        TtsEngine.pocketEs => TtsEngineKind.pocketEs,
      };

  // seed=2 stabilizes FR 24L; all other engines use seed=1.
  int get seed => this == TtsEngine.pocketFr ? 2 : 1;
}

class SettingsService extends ChangeNotifier {
  static const _langKey = 'language';
  static const _ttsKey = 'ttsEngine';
  static const _supportedLanguages = {'en', 'de', 'fr', 'es'};

  late SharedPreferences _prefs;
  String _language = 'en';
  TtsEngine _ttsEngine = TtsEngine.system;
  String _appSupportDir = '';

  String get language => _language;
  TtsEngine get ttsEngine => _ttsEngine;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final dir = await getApplicationSupportDirectory();
    _appSupportDir = dir.path;

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
    }
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

  bool isEngineInstalled(TtsEngine engine) {
    if (engine.modelDir == null) return true;
    return Directory('$_appSupportDir/${engine.modelDir}').existsSync();
  }

  // Returns the best available engine: preferred if installed, else system.
  TtsEngine get effectiveEngine {
    if (_ttsEngine == TtsEngine.system) return TtsEngine.system;
    if (isEngineInstalled(_ttsEngine)) return _ttsEngine;
    return TtsEngine.system;
  }

  // BCP-47 locale string for STT and system TTS (e.g. 'de-DE').
  String get locale => switch (_language) {
        'de' => 'de-DE',
        'fr' => 'fr-FR',
        'es' => 'es-ES',
        _ => 'en-US',
      };
}
