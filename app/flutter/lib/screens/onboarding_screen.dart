import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../api_config.dart';
import '../widgets/starfield.dart';
import '../theme.dart';

/// First-run onboarding: asks the child's name + age, then mints a child profile
/// (POST /child) so the rest of the app has a stable childId to personalize and
/// remember the child across nights. On success it hands (childId, name) back to
/// the root, which routes into the greeting -> voice conversation flow.
///
/// Age is collected as tappable chips rather than a keyboard field: a sleepy
/// parent at 8pm should be able to onboard with two taps, screen mostly off.
class OnboardingScreen extends StatefulWidget {
  final String apiBase;
  final void Function(String childId, String name) onComplete;

  const OnboardingScreen({
    super.key,
    required this.apiBase,
    required this.onComplete,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _nameController = TextEditingController();
  int? _age;
  bool _submitting = false;
  String? _error;

  static const _ages = [2, 3, 4, 5, 6, 7, 8, 9, 10];

  @override
  void initState() {
    super.initState();
    // Re-evaluate the Begin button's enabled state as the name is typed.
    _nameController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _nameController.text.trim().isNotEmpty && _age != null && !_submitting;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final res = await http.post(
        Uri.parse('${widget.apiBase}/child'),
        headers: apiHeaders(json: true),
        body: jsonEncode({'name': _nameController.text.trim(), 'age': _age}),
      );
      if (res.statusCode != 200) {
        throw Exception('Sign-up failed (${res.statusCode})');
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final childId = data['childId'] as String?;
      final name = data['name'] as String?;
      if (childId == null || name == null) {
        throw Exception('Unexpected response: ${res.body}');
      }
      widget.onComplete(childId, name);
    } catch (e) {
      debugPrint('Onboarding failed: $e');
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = 'Something went wrong. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: navy,
      // Lets the layout scroll up when the keyboard covers the field.
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          const Positioned.fill(child: Starfield()),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 24),
                  const Text('🌙', style: TextStyle(fontSize: 72)),
                  const SizedBox(height: 28),
                  const Text(
                    'Welcome to Yarnia',
                    style: TextStyle(
                      fontFamily: 'Fraunces',
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: cream,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Who are we telling a story to tonight?',
                    style: TextStyle(
                      fontFamily: 'Lora',
                      fontSize: 16,
                      color: gold.withAlpha(220),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 40),

                  // Name
                  const _Label('Their name'),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _nameController,
                    textCapitalization: TextCapitalization.words,
                    textAlign: TextAlign.center,
                    enabled: !_submitting,
                    onSubmitted: (_) => _submit(),
                    style: const TextStyle(
                      fontFamily: 'Lora',
                      color: cream,
                      fontSize: 20,
                    ),
                    cursorColor: gold,
                    decoration: InputDecoration(
                      hintText: 'e.g. Mira',
                      hintStyle: TextStyle(
                        fontFamily: 'Lora',
                        color: cream.withAlpha(80),
                        fontSize: 18,
                      ),
                      filled: true,
                      fillColor: navyLight,
                      contentPadding: const EdgeInsets.symmetric(vertical: 16),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(color: gold.withAlpha(90)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(color: gold, width: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Age
                  const _Label('Their age'),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.center,
                    children: _ages.map((age) {
                      final selected = _age == age;
                      return GestureDetector(
                        onTap: _submitting ? null : () => setState(() => _age = age),
                        child: Container(
                          width: 48,
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: selected ? gold : Colors.transparent,
                            border: Border.all(
                              color: selected ? gold : gold.withAlpha(90),
                              width: 1.5,
                            ),
                          ),
                          child: Text(
                            '$age',
                            style: TextStyle(
                              fontFamily: 'Lora',
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: selected ? navy : cream,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 44),

                  // Begin
                  Opacity(
                    opacity: _canSubmit ? 1.0 : 0.4,
                    child: GestureDetector(
                      onTap: _submit,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 14, horizontal: 52),
                        decoration: BoxDecoration(
                          border: Border.all(color: gold, width: 1.5),
                          borderRadius: BorderRadius.circular(40),
                        ),
                        child: _submitting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: gold,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text(
                                'Continue',
                                style: TextStyle(
                                  fontFamily: 'Lora',
                                  color: gold,
                                  fontSize: 16,
                                  letterSpacing: 1.5,
                                ),
                              ),
                      ),
                    ),
                  ),

                  if (_error != null) ...[
                    const SizedBox(height: 24),
                    Text(
                      _error!,
                      style: TextStyle(
                        fontFamily: 'Lora',
                        color: cream.withAlpha(200),
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontFamily: 'Lora',
        color: cream.withAlpha(140),
        fontSize: 12,
        letterSpacing: 2,
      ),
    );
  }
}
