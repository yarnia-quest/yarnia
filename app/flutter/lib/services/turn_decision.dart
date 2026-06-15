// Dart port of api/src/turn.ts — parses the on-device LLM's JSON response for
// a mid-story conversational turn. No I/O; pure parser so it is fully testable.
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

enum TurnIntent { continueStory, answer, revise }

class TurnRevision {
  final int fromSentence;
  final List<String> sentences;
  const TurnRevision({required this.fromSentence, required this.sentences});
}

class TurnDecision {
  final TurnIntent intent;
  final String? say;
  final TurnRevision? revision;
  final int resumeAt;

  const TurnDecision({
    required this.intent,
    this.say,
    this.revision,
    required this.resumeAt,
  });

  factory TurnDecision.safe(int cursor) =>
      TurnDecision(intent: TurnIntent.continueStory, resumeAt: cursor);
}

// Tolerant parse of the on-device LLM's raw output.
// Strips ``` fences, leading prose, and clamps all indices.
// On any failure returns a safe "continue" fallback.
TurnDecision interpretTurn(String raw, int cursor, int storyLength) {
  final safe = TurnDecision.safe(cursor);
  var cleaned = raw.trim();

  // Strip <think>...</think> blocks emitted by Qwen models.
  cleaned = cleaned.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '').trim();

  // Strip ``` fences.
  cleaned = cleaned
      .replaceFirst(RegExp(r'^```[a-z]*\s*', caseSensitive: false), '')
      .replaceFirst(RegExp(r'\s*```\s*$'), '')
      .trim();

  // Strip leading prose before the first '{'.
  final braceIdx = cleaned.indexOf('{');
  if (braceIdx > 0) cleaned = cleaned.substring(braceIdx);
  if (braceIdx < 0) {
    debugPrint('interpretTurn: no JSON object found in: ${raw.substring(0, raw.length.clamp(0, 200))}');
    return safe;
  }

  Map<String, dynamic> obj;
  try {
    obj = jsonDecode(cleaned) as Map<String, dynamic>;
  } catch (e) {
    debugPrint('interpretTurn: JSON parse failed: $e. Raw: ${raw.substring(0, raw.length.clamp(0, 200))}');
    return safe;
  }

  final intentStr = obj['intent'] as String?;
  final TurnIntent intent;
  switch (intentStr) {
    case 'continue':
      intent = TurnIntent.continueStory;
    case 'answer':
      intent = TurnIntent.answer;
    case 'revise':
      intent = TurnIntent.revise;
    default:
      debugPrint('interpretTurn: unknown intent "$intentStr", falling back to continue');
      return safe;
  }

  final say = obj['say'] is String && (obj['say'] as String).isNotEmpty
      ? obj['say'] as String
      : null;

  var resumeAt = cursor;
  if (obj['resumeAt'] is num) {
    final r = (obj['resumeAt'] as num).toInt();
    if (r >= 0 && r <= storyLength) resumeAt = r;
  }

  if (intent == TurnIntent.revise) {
    final rev = obj['revision'];
    if (rev is! Map) {
      debugPrint('interpretTurn: revise intent missing revision object, falling back to continue');
      return safe;
    }
    final revMap = rev as Map<String, dynamic>;
    final rawSentences = revMap['sentences'];
    if (rawSentences is! List || rawSentences.isEmpty) {
      debugPrint('interpretTurn: revise.sentences missing or empty, falling back to continue');
      return safe;
    }
    final sentences = rawSentences
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (sentences.isEmpty) {
      debugPrint('interpretTurn: revise.sentences all empty after filtering, falling back to continue');
      return safe;
    }
    var fromSentence = cursor;
    if (revMap['fromSentence'] is num) {
      fromSentence = (revMap['fromSentence'] as num).toInt().clamp(0, storyLength);
    }
    final revResumeAt = (obj['resumeAt'] is num) ? resumeAt : fromSentence;
    return TurnDecision(
      intent: TurnIntent.revise,
      say: say,
      revision: TurnRevision(fromSentence: fromSentence, sentences: sentences),
      resumeAt: revResumeAt,
    );
  }

  return TurnDecision(intent: intent, say: say, resumeAt: resumeAt);
}

// Build the system+user prompt for an on-device turn decision.
// Mirrors api/src/prompt.ts buildTurnPrompt but works offline with what the
// app knows (name, story, cursor, utterance, language — no age/fears).
({String system, String user}) buildLocalTurnPrompt({
  required String childName,
  required List<String> sentences,
  required int cursor,
  required String utterance,
  required String language,
}) {
  final numberedSentences = sentences.asMap().entries.map((e) => '${e.key}: ${e.value}').join('\n');
  final positionLine = cursor > 0
      ? 'You are paused right after sentence ${cursor - 1} (about to read sentence $cursor).'
      : 'You are paused at the very beginning (about to read sentence 0).';

  final langNames = {'de': 'German', 'fr': 'French', 'es': 'Spanish'};
  final langName = langNames[language];
  final langLine = langName != null
      ? '\nAll spoken responses (say, revision.sentences) must be entirely in $langName.'
      : '';

  final system = 'You are Yarnia, a warm bedtime storyteller for a child named $childName. '
      'The story must stay gentle, soothing, and nonviolent.\n\n'
      'Here is the bedtime story so far, as numbered sentences:\n$numberedSentences\n\n'
      '$positionLine\n\n'
      'Respond with ONLY a JSON object (no prose, no markdown):\n'
      '{ "intent": "continue" | "answer" | "revise", "say"?: string, '
      '"revision"?: { "fromSentence": number, "sentences": string[] }, "resumeAt": number }\n\n'
      'Field rules:\n'
      '- intent: "continue" = resume the story. "answer" = answer a question then resume. '
      '"revise" = rewrite sentences from a given index.\n'
      '- say: optional short line Yarnia speaks before resuming.\n'
      '- revision: required for "revise" — fromSentence is the splice index, sentences are replacements.\n'
      '- resumeAt: sentence index to resume narration from.\n\n'
      'Examples:\n'
      '  Continue: { "intent": "continue", "resumeAt": $cursor }\n'
      '  Answer:   { "intent": "answer", "say": "His name is Leo!", "resumeAt": $cursor }\n'
      '  Revise:   { "intent": "revise", "say": "Sure!", "revision": { "fromSentence": 2, '
      '"sentences": ["The bunny was blue.", "She smiled."] }, "resumeAt": 2 }'
      '$langLine';

  final user = 'The child just said: "$utterance". Respond with the JSON object only.';
  return (system: system, user: user);
}
