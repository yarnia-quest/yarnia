import 'package:flutter/material.dart';
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
          title: const Text('Settings', style: TextStyle(fontFamily: 'Lora', color: cream)),
          elevation: 0,
        ),
        body: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            _sectionLabel('Language'),
            const SizedBox(height: 4),
            Text(
              'Detected from your phone',
              style: TextStyle(fontFamily: 'Lora', color: cream.withAlpha(100), fontSize: 12),
            ),
            const SizedBox(height: 12),
            Row(
              children: _languages.map(((String code, String flag, String label) lang) {
                final selected = s.language == lang.$1;
                return Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: GestureDetector(
                    onTap: () => s.setLanguage(lang.$1),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: selected ? gold : cream.withAlpha(60),
                          width: selected ? 1.5 : 1,
                        ),
                        borderRadius: BorderRadius.circular(24),
                        color: selected ? gold.withAlpha(30) : Colors.transparent,
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
              }).toList(),
            ),
            const SizedBox(height: 32),
            _sectionLabel('Narrator voice'),
            const SizedBox(height: 8),
            ...TtsEngine.values.map((engine) => _EngineTile(
                  engine: engine,
                  selected: s.ttsEngine == engine,
                  installed: s.isEngineInstalled(engine),
                  onTap: () {
                    if (engine.isSystem || s.isEngineInstalled(engine)) {
                      s.setTtsEngine(engine);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '${engine.label} is not installed on this device.',
                            style: const TextStyle(fontFamily: 'Lora'),
                          ),
                          backgroundColor: navyLight,
                        ),
                      );
                    }
                  },
                )),
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

class _EngineTile extends StatelessWidget {
  final TtsEngine engine;
  final bool selected;
  final bool installed;
  final VoidCallback onTap;

  const _EngineTile({
    required this.engine,
    required this.selected,
    required this.installed,
    required this.onTap,
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
                    engine.label,
                    style: TextStyle(
                      fontFamily: 'Lora',
                      color: selected ? gold : cream,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    engine.quality,
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
                if (engine.sizeMb > 0)
                  Text(
                    '${engine.sizeMb} MB',
                    style: TextStyle(
                      fontFamily: 'Lora',
                      color: cream.withAlpha(100),
                      fontSize: 11,
                    ),
                  ),
                const SizedBox(height: 4),
                _StatusChip(engine: engine, installed: installed),
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
        border: Border.all(color: selected ? gold : cream.withAlpha(80), width: 1.5),
      ),
      child: selected
          ? Center(
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: gold),
              ),
            )
          : null,
    );
  }
}

class _StatusChip extends StatelessWidget {
  final TtsEngine engine;
  final bool installed;
  const _StatusChip({required this.engine, required this.installed});

  @override
  Widget build(BuildContext context) {
    final (String label, Color color) = engine.isSystem
        ? ('Default', cream.withAlpha(120))
        : installed
            ? ('On device', const Color(0xFF6FCF97))
            : ('Not installed', cream.withAlpha(60));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: color.withAlpha(100)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(fontFamily: 'Lora', color: color, fontSize: 11),
      ),
    );
  }
}
