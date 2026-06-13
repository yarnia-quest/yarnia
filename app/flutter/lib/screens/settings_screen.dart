import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;
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

  bool? _sysTtsAvailable;
  bool? _sysSttAvailable;

  // engine → (filesDownloaded, totalFiles)  — present while downloading
  final Map<TtsEngine, (int, int)> _downloading = {};
  String? _downloadError;

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
        if (Platform.isAndroid) {
          final engines = await FlutterTts().getEngines;
          ttsOk = (engines as List).isNotEmpty;
        }
      } catch (e) {
        debugPrint('TTS check failed: $e');
      }
      try {
        sttOk = await SpeechToText().initialize();
      } catch (e) {
        debugPrint('STT check failed: $e');
      }
    } else {
      ttsOk = true;
      sttOk = true;
    }
    if (mounted) setState(() { _sysTtsAvailable = ttsOk; _sysSttAvailable = sttOk; });
  }

  // ── In-app model download ───────────────────────────────────────────────

  Future<void> _downloadEngine(TtsEngine engine) async {
    if (_downloading.containsKey(engine)) return;
    final repo = engine.hfRepo;
    final files = engine.modelFiles;
    if (repo == null || files == null) return;

    final baseDir = p.join(widget.settings.appSupportDir, engine.modelDir!);
    setState(() {
      _downloading[engine] = (0, files.length);
      _downloadError = null;
    });

    final client = HttpClient()..autoUncompress = true;
    try {
      for (int i = 0; i < files.length; i++) {
        final filename = files[i];
        final url = 'https://huggingface.co/$repo/resolve/main/$filename';
        final dest = p.join(baseDir, filename.replaceAll('/', Platform.pathSeparator));
        await File(dest).parent.create(recursive: true);
        await _downloadFile(client, url, dest);
        if (!mounted) return;
        setState(() => _downloading[engine] = (i + 1, files.length));
      }
      widget.settings.refreshInstalled();
    } catch (e) {
      debugPrint('Download failed for ${engine.label}: $e');
      if (mounted) setState(() => _downloadError = 'Download failed: $e');
    } finally {
      client.close();
      if (mounted) setState(() => _downloading.remove(engine));
    }
  }

  Future<void> _downloadFile(HttpClient client, String url, String dest) async {
    final req = await client.getUrl(Uri.parse(url));
    req.followRedirects = true;
    req.maxRedirects = 5;
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw HttpException('HTTP ${resp.statusCode}', uri: Uri.parse(url));
    }
    final sink = File(dest).openWrite();
    try {
      await resp.pipe(sink);
    } finally {
      await sink.close();
    }
  }

  Future<void> _openUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Could not open $url: $e');
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
            Text('Detected from your phone',
                style: TextStyle(
                    fontFamily: 'Lora',
                    color: cream.withAlpha(100),
                    fontSize: 12)),
            const SizedBox(height: 12),
            Row(
              children: _languages.map(((String, String, String) lang) {
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
                      child: Text('${lang.$2} ${lang.$3}',
                          style: TextStyle(
                            fontFamily: 'Lora',
                            color: selected ? gold : cream.withAlpha(160),
                            fontSize: 14,
                          )),
                    ),
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 32),

            // ── Narrator (TTS) ────────────────────────────────────────────
            _sectionLabel('Narrator'),
            const SizedBox(height: 8),
            if (_sysTtsAvailable == false && s.ttsEngine == TtsEngine.system)
              ...[
              _WarningBanner(
                message: Platform.isAndroid
                    ? 'Google Text-to-Speech is not installed.'
                    : 'System TTS unavailable.',
                actionLabel:
                    Platform.isAndroid ? 'Open Play Store →' : null,
                onAction:
                    Platform.isAndroid ? _openPlayStoreTts : null,
              ),
              const SizedBox(height: 8),
            ],
            if (_downloadError != null) ...[
              _WarningBanner(message: _downloadError!),
              const SizedBox(height: 8),
            ],
            ...TtsEngine.values.map((engine) {
              final dl = _downloading[engine];
              return _EngineTile(
                label: engine.label,
                quality: engine.quality,
                sizeMb: engine.sizeMb,
                selected: s.ttsEngine == engine,
                installed: s.isEngineInstalled(engine),
                isSystem: engine.isSystem,
                canDownload: engine.canDownload,
                downloadProgress: dl != null ? dl.$1 / dl.$2 : null,
                downloadLabel: dl != null ? '${dl.$1}/${dl.$2}' : null,
                onTap: () {
                  if (engine.isSystem || s.isEngineInstalled(engine)) {
                    s.setTtsEngine(engine);
                  } else if (engine.canDownload) {
                    _downloadEngine(engine);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('${engine.label} is not yet available.',
                          style: const TextStyle(fontFamily: 'Lora')),
                      backgroundColor: navyLight,
                    ));
                  }
                },
                onDownload: engine.canDownload && !_downloading.containsKey(engine)
                    ? () => _downloadEngine(engine)
                    : null,
              );
            }),

            const SizedBox(height: 32),

            // ── Listener (STT) ────────────────────────────────────────────
            _sectionLabel('Listener'),
            const SizedBox(height: 8),
            if (_sysSttAvailable == false && s.sttEngine == SttEngine.system)
              ...[
              _WarningBanner(
                message: Platform.isAndroid
                    ? 'Speech recognition is not available.'
                    : 'System STT unavailable.',
                actionLabel:
                    Platform.isAndroid ? 'Open Play Store →' : null,
                onAction:
                    Platform.isAndroid ? _openPlayStoreStt : null,
              ),
              const SizedBox(height: 8),
            ],
            ...SttEngine.values.map((engine) => _EngineTile(
                  label: engine.label,
                  quality: engine.quality,
                  sizeMb: engine.sizeMb,
                  selected: s.sttEngine == engine,
                  installed: s.isSttEngineInstalled(engine),
                  isSystem: engine.isSystem,
                  canDownload: engine.downloadUrl != null,
                  downloadProgress: null,
                  downloadLabel: null,
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

// ── Warning banner ──────────────────────────────────────────────────────────

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
        border:
            Border.all(color: const Color(0xFFB8860B).withAlpha(120)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Text('⚠', style: TextStyle(fontSize: 16)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: TextStyle(
                    fontFamily: 'Lora',
                    color: cream.withAlpha(200),
                    fontSize: 13)),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onAction,
              child: Text(actionLabel!,
                  style: const TextStyle(
                      fontFamily: 'Lora', color: gold, fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Engine tile ─────────────────────────────────────────────────────────────

class _EngineTile extends StatelessWidget {
  final String label;
  final String quality;
  final int sizeMb;
  final bool selected;
  final bool installed;
  final bool isSystem;
  final bool canDownload;
  final double? downloadProgress; // 0.0-1.0 while downloading
  final String? downloadLabel;    // e.g. "3/8"
  final VoidCallback onTap;
  final VoidCallback? onDownload;

  const _EngineTile({
    required this.label,
    required this.quality,
    required this.sizeMb,
    required this.selected,
    required this.installed,
    required this.isSystem,
    required this.canDownload,
    required this.downloadProgress,
    required this.downloadLabel,
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _RadioDot(selected: selected),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: TextStyle(
                            fontFamily: 'Lora',
                            color: selected ? gold : cream,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          )),
                      const SizedBox(height: 2),
                      Text(quality,
                          style: TextStyle(
                            fontFamily: 'Lora',
                            color: cream.withAlpha(120),
                            fontSize: 12,
                          )),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (sizeMb > 0)
                      Text('$sizeMb MB',
                          style: TextStyle(
                            fontFamily: 'Lora',
                            color: cream.withAlpha(100),
                            fontSize: 11,
                          )),
                    const SizedBox(height: 4),
                    if (downloadProgress == null)
                      _StatusChip(
                        isSystem: isSystem,
                        installed: installed,
                        canDownload: canDownload,
                        onDownload: onDownload,
                      )
                    else
                      Text(
                        downloadLabel ?? '',
                        style: TextStyle(
                            fontFamily: 'Lora',
                            color: gold.withAlpha(200),
                            fontSize: 11),
                      ),
                  ],
                ),
              ],
            ),
            if (downloadProgress != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: downloadProgress,
                  minHeight: 3,
                  backgroundColor: cream.withAlpha(30),
                  valueColor: const AlwaysStoppedAnimation<Color>(gold),
                ),
              ),
            ],
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
        border: Border.all(
            color: selected ? gold : cream.withAlpha(80), width: 1.5),
      ),
      child: selected
          ? Center(
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                    shape: BoxShape.circle, color: gold),
              ),
            )
          : null,
    );
  }
}

class _StatusChip extends StatelessWidget {
  final bool isSystem;
  final bool installed;
  final bool canDownload;
  final VoidCallback? onDownload;

  const _StatusChip({
    required this.isSystem,
    required this.installed,
    required this.canDownload,
    this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    if (isSystem) return _chip('Default', cream.withAlpha(120));
    if (installed) return _chip('On device', const Color(0xFF6FCF97));
    if (canDownload) {
      return GestureDetector(
        onTap: onDownload,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(color: gold.withAlpha(180)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Text('Download →',
              style: TextStyle(
                  fontFamily: 'Lora', color: gold, fontSize: 11)),
        ),
      );
    }
    return _chip('Uploading to HuggingFace soon', cream.withAlpha(60));
  }

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: color.withAlpha(100)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label,
            style: TextStyle(
                fontFamily: 'Lora', color: color, fontSize: 11)),
      );
}
