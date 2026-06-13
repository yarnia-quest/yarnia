import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/settings_service.dart';
import '../theme.dart';

class SettingsScreen extends StatefulWidget {
  final SettingsService settings;

  const SettingsScreen({super.key, required this.settings});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _languages = [
    ('en', '🇬🇧', 'EN'),
    ('de', '🇩🇪', 'DE'),
    ('fr', '🇫🇷', 'FR'),
    ('es', '🇪🇸', 'ES'),
  ];

  // null = still checking
  bool? _sysTtsAvailable;
  bool? _sysSttAvailable;

  @override
  void initState() {
    super.initState();
    _checkAvailability();
  }

  Future<void> _checkAvailability() async {
    bool ttsOk = true;
    bool sttOk = false;

    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final tts = FlutterTts();
        if (Platform.isAndroid) {
          final engines = await tts.getEngines;
          ttsOk = (engines as List).isNotEmpty;
        }
        // On iOS, system TTS is always available.
      } catch (e) {
        debugPrint('TTS availability check failed: $e');
        ttsOk = true; // assume ok if check fails
      }

      try {
        final stt = SpeechToText();
        sttOk = await stt.initialize();
      } catch (e) {
        debugPrint('STT availability check failed: $e');
        sttOk = false;
      }
    } else {
      ttsOk = true;
      sttOk = true;
    }

    if (mounted) {
      setState(() {
        _sysTtsAvailable = ttsOk;
        _sysSttAvailable = sttOk;
      });
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Could not open URL $url: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open: $url',
                style: const TextStyle(fontFamily: 'Lora')),
            backgroundColor: navyLight,
          ),
        );
      }
    }
  }

  void _openPlayStoreTts() =>
      _openUrl('market://details?id=com.google.android.tts');
  void _openPlayStoreStt() =>
      _openUrl('market://details?id=com.google.android.googlequicksearchbox');

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Scaffold(
        backgroundColor: navy,
        appBar: AppBar(
          backgroundColor: navy,
          foregroundColor: cream,
          title: const Text('Settings',
              style: TextStyle(fontFamily: 'Lora', color: cream)),
          elevation: 0,
        ),
        body: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            // ── Language ──────────────────────────────────────────────────
            _sectionLabel('Language'),
            const SizedBox(height: 4),
            Text(
              'Detected from your phone',
              style: TextStyle(
                  fontFamily: 'Lora', color: cream.withAlpha(100), fontSize: 12),
            ),
            const SizedBox(height: 12),
            Row(
              children: _languages
                  .map(((String, String, String) lang) {
                    final selected = s.language == lang.$1;
                    return Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: GestureDetector(
                        onTap: () => s.setLanguage(lang.$1),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          padding: const EdgeInsets.symmetric(
                              vertical: 8, horizontal: 14),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: selected ? gold : cream.withAlpha(60),
                              width: selected ? 1.5 : 1,
                            ),
                            borderRadius: BorderRadius.circular(24),
                            color: selected
                                ? gold.withAlpha(30)
                                : Colors.transparent,
                          ),
                          child: Text(
                            '${lang.$2} ${lang.$3}',
                            style: TextStyle(
                              fontFamily: 'Lora',
                              color: selected ? gold : cream.withAlpha(160),
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                    );
                  })
                  .toList(),
            ),

            const SizedBox(height: 32),

            // ── Narrator (TTS) ────────────────────────────────────────────
            _sectionLabel('Narrator'),
            const SizedBox(height: 8),
            if (_sysTtsAvailable == false &&
                s.ttsEngine == TtsEngine.system) ...[
              _WarningBanner(
                message: Platform.isAndroid
                    ? 'Google Text-to-Speech is not installed.'
                    : 'System TTS unavailable.',
                actionLabel: Platform.isAndroid ? 'Open Play Store →' : null,
                onAction: Platform.isAndroid ? _openPlayStoreTts : null,
              ),
              const SizedBox(height: 8),
            ],
            ...TtsEngine.values.map((engine) => _TtsTile(
                  engine: engine,
                  selected: s.ttsEngine == engine,
                  installed: s.isEngineInstalled(engine),
                  onTap: () {
                    if (engine.isSystem || s.isEngineInstalled(engine)) {
                      s.setTtsEngine(engine);
                    } else if (engine.downloadUrl != null) {
                      _openUrl(engine.downloadUrl!);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('${engine.label} is not yet available.',
                            style: const TextStyle(fontFamily: 'Lora')),
                        backgroundColor: navyLight,
                      ));
                    }
                  },
                  onDownload: engine.downloadUrl != null
                      ? () => _openUrl(engine.downloadUrl!)
                      : null,
                )),

            const SizedBox(height: 32),

            // ── Listener (STT) ────────────────────────────────────────────
            _sectionLabel('Listener'),
            const SizedBox(height: 8),
            if (_sysSttAvailable == false &&
                s.sttEngine == SttEngine.system) ...[
              _WarningBanner(
                message: Platform.isAndroid
                    ? 'Speech recognition is not available.'
                    : 'System STT unavailable.',
                actionLabel: Platform.isAndroid ? 'Open Play Store →' : null,
                onAction: Platform.isAndroid ? _openPlayStoreStt : null,
              ),
              const SizedBox(height: 8),
            ],
            ...SttEngine.values.map((engine) => _SttTile(
                  engine: engine,
                  selected: s.sttEngine == engine,
                  installed: s.isSttEngineInstalled(engine),
                  onTap: () {
                    if (engine.isSystem || s.isSttEngineInstalled(engine)) {
                      s.setSttEngine(engine);
                    } else if (engine.downloadUrl != null) {
                      _openUrl(engine.downloadUrl!);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('${engine.label} is not yet available.',
                            style: const TextStyle(fontFamily: 'Lora')),
                        backgroundColor: navyLight,
                      ));
                    }
                  },
                  onDownload: engine.downloadUrl != null
                      ? () => _openUrl(engine.downloadUrl!)
                      : null,
                )),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
        text.toUpperCase(),
        style: TextStyle(
          fontFamily: 'Lora',
          color: cream.withAlpha(120),
          fontSize: 11,
          letterSpacing: 1.4,
        ),
      );
}

// ── Warning banner ─────────────────────────────────────────────────────────────

class _WarningBanner extends StatelessWidget {
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _WarningBanner(
      {required this.message, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF3D2B00),
        border: Border.all(color: const Color(0xFFB8860B).withAlpha(120)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Text('⚠', style: TextStyle(fontSize: 16)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                  fontFamily: 'Lora', color: cream.withAlpha(200), fontSize: 13),
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onAction,
              child: Text(
                actionLabel!,
                style: const TextStyle(
                    fontFamily: 'Lora', color: gold, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Engine tiles ───────────────────────────────────────────────────────────────

class _TtsTile extends StatelessWidget {
  final TtsEngine engine;
  final bool selected;
  final bool installed;
  final VoidCallback onTap;
  final VoidCallback? onDownload;

  const _TtsTile({
    required this.engine,
    required this.selected,
    required this.installed,
    required this.onTap,
    this.onDownload,
  });

  @override
  Widget build(BuildContext context) => _EngineTile(
        label: engine.label,
        quality: engine.quality,
        sizeMb: engine.sizeMb,
        selected: selected,
        installed: installed,
        isSystem: engine.isSystem,
        downloadUrl: engine.downloadUrl,
        onTap: onTap,
        onDownload: onDownload,
      );
}

class _SttTile extends StatelessWidget {
  final SttEngine engine;
  final bool selected;
  final bool installed;
  final VoidCallback onTap;
  final VoidCallback? onDownload;

  const _SttTile({
    required this.engine,
    required this.selected,
    required this.installed,
    required this.onTap,
    this.onDownload,
  });

  @override
  Widget build(BuildContext context) => _EngineTile(
        label: engine.label,
        quality: engine.quality,
        sizeMb: engine.sizeMb,
        selected: selected,
        installed: installed,
        isSystem: engine.isSystem,
        downloadUrl: engine.downloadUrl,
        onTap: onTap,
        onDownload: onDownload,
      );
}

class _EngineTile extends StatelessWidget {
  final String label;
  final String quality;
  final int sizeMb;
  final bool selected;
  final bool installed;
  final bool isSystem;
  final String? downloadUrl;
  final VoidCallback onTap;
  final VoidCallback? onDownload;

  const _EngineTile({
    required this.label,
    required this.quality,
    required this.sizeMb,
    required this.selected,
    required this.installed,
    required this.isSystem,
    required this.downloadUrl,
    required this.onTap,
    this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? gold : cream.withAlpha(40),
            width: selected ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
          color: selected ? gold.withAlpha(20) : Colors.transparent,
        ),
        child: Row(
          children: [
            _RadioDot(selected: selected),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'Lora',
                      color: selected ? gold : cream,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    quality,
                    style: TextStyle(
                      fontFamily: 'Lora',
                      color: cream.withAlpha(120),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (sizeMb > 0)
                  Text(
                    '$sizeMb MB',
                    style: TextStyle(
                      fontFamily: 'Lora',
                      color: cream.withAlpha(100),
                      fontSize: 11,
                    ),
                  ),
                const SizedBox(height: 4),
                _StatusChip(
                  isSystem: isSystem,
                  installed: installed,
                  downloadUrl: downloadUrl,
                  onDownload: onDownload,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RadioDot extends StatelessWidget {
  final bool selected;
  const _RadioDot({required this.selected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border:
            Border.all(color: selected ? gold : cream.withAlpha(80), width: 1.5),
      ),
      child: selected
          ? Center(
              child: Container(
                width: 8,
                height: 8,
                decoration:
                    const BoxDecoration(shape: BoxShape.circle, color: gold),
              ),
            )
          : null,
    );
  }
}

class _StatusChip extends StatelessWidget {
  final bool isSystem;
  final bool installed;
  final String? downloadUrl;
  final VoidCallback? onDownload;

  const _StatusChip({
    required this.isSystem,
    required this.installed,
    required this.downloadUrl,
    this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    if (isSystem) {
      return _chip('Default', cream.withAlpha(120));
    }
    if (installed) {
      return _chip('On device', const Color(0xFF6FCF97));
    }
    if (downloadUrl != null) {
      return GestureDetector(
        onTap: onDownload,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(color: gold.withAlpha(160)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Text(
            'Download →',
            style: TextStyle(fontFamily: 'Lora', color: gold, fontSize: 11),
          ),
        ),
      );
    }
    return _chip('Coming soon', cream.withAlpha(60));
  }

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: color.withAlpha(100)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style:
              TextStyle(fontFamily: 'Lora', color: color, fontSize: 11),
        ),
      );
}
