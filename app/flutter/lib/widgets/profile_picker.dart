import 'package:flutter/material.dart';
import '../services/child_store.dart';
import '../theme.dart';
import 'starfield.dart';

/// Profile switcher for households with more than one child. Lists the stored children, lets a
/// parent pick whose story night it is, or add another child. The backend already supports many
/// children per device; this is the on-device picker over the stored profiles.
class ProfilePicker extends StatelessWidget {
  final List<StoredChild> children;
  final String activeChildId;
  final void Function(StoredChild) onSelect;
  final VoidCallback onAddChild;
  final VoidCallback onBack;

  const ProfilePicker({
    super.key,
    required this.children,
    required this.activeChildId,
    required this.onSelect,
    required this.onAddChild,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: navy,
      body: Stack(
        children: [
          const Positioned.fill(child: Starfield()),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 12),
                  const Text('🌙', style: TextStyle(fontSize: 48)),
                  const SizedBox(height: 20),
                  const Text(
                    "Whose story night is it?",
                    style: TextStyle(
                      fontFamily: 'Fraunces',
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: cream,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  ...children.map((c) {
                    final active = c.childId == activeChildId;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: GestureDetector(
                        onTap: () => onSelect(c),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
                          decoration: BoxDecoration(
                            color: active ? gold.withAlpha(30) : navyLight,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: active ? gold : gold.withAlpha(70), width: 1.5),
                          ),
                          child: Row(
                            children: [
                              Text(active ? '🌟' : '🌙', style: const TextStyle(fontSize: 22)),
                              const SizedBox(width: 14),
                              Text(
                                c.name,
                                style: const TextStyle(fontFamily: 'Lora', fontSize: 18, color: cream),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: onAddChild,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: gold.withAlpha(70), width: 1.5),
                      ),
                      child: Row(
                        children: [
                          const Text('＋', style: TextStyle(fontSize: 22, color: gold)),
                          const SizedBox(width: 14),
                          Text(
                            'Add a child',
                            style: TextStyle(fontFamily: 'Lora', fontSize: 16, color: gold.withAlpha(220)),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  TextButton(
                    onPressed: onBack,
                    child: Text(
                      'Back',
                      style: TextStyle(color: cream.withAlpha(150), fontFamily: 'Lora', fontSize: 15),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
