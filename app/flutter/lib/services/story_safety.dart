// On-device output moderation — a Dart port of api/src/safety.ts so generated
// stories are vetted locally (no network needed to keep output kid-safe).
// Intentionally conservative; a second layer on top of the prompt-level guardrail.

final List<RegExp> _unsafePatterns = [
  RegExp(r'\bblood(y|shed)?\b', caseSensitive: false),
  RegExp(r'\bgore\b|\bgory\b', caseSensitive: false),
  RegExp(r'\bkill(s|ed|ing)?\b|\bmurder', caseSensitive: false),
  RegExp(r'\bstab(s|bed|bing)?\b', caseSensitive: false),
  RegExp(r'\bgun(s)?\b|\bshoot(s|ing)?\b|\bshot\b', caseSensitive: false),
  RegExp(r'\bknife\b|\bblade\b|\bweapon', caseSensitive: false),
  RegExp(r'\bcorpse\b|\bdead body\b', caseSensitive: false),
  RegExp(r'\bsuicide\b|\bself[- ]?harm\b', caseSensitive: false),
  RegExp(r'\bsex(ual|y)?\b|\bnaked\b|\bporn', caseSensitive: false),
  RegExp(r'\bf+u+c+k|\bshit\b|\bbitch\b|\bbastard\b|\basshole\b|\bdamn\b',
      caseSensitive: false),
  RegExp(r'\bcocaine\b|\bheroin\b|\bmeth(amphetamine)?\b', caseSensitive: false),
];

/// True when the text contains no clearly age-inappropriate content.
bool isStorySafe(String text) => !_unsafePatterns.any((re) => re.hasMatch(text));

/// A guaranteed-safe, soothing fallback used when generation produces unsafe text.
String safeFallbackStory(String name) {
  final who = name.trim().isEmpty ? 'a sleepy little one' : name.trim();
  return 'Once upon a time, $who curled up under a soft blanket of stars. '
      'A gentle owl hooted goodnight, the moon hummed a quiet tune, and warm dreams '
      'drifted in like little boats on a calm, calm sea. Goodnight, $who. Sleep tight.';
}
