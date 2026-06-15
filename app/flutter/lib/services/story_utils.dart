// Pure story-logic helpers — no Flutter/platform dependencies so they are unit-testable.
import 'dart:convert';

// ── LLM output cleaner ───────────────────────────────────────────────────────

/// Strip Qwen chat template tokens and markdown from on-device model output.
/// Returns trimmed plain prose suitable for TTS.
String cleanLlmOutput(String raw) {
  var text = raw;
  final imStart = text.lastIndexOf('<|im_start|>');
  if (imStart >= 0) text = text.substring(imStart + '<|im_start|>'.length);
  text = text.replaceAll(RegExp(r'<\|[^|]+\|>'), '');
  text = text.replaceAll(RegExp(r'^\s*assistant\s*', caseSensitive: false), '');
  text = text.replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '');
  text = text.replaceAll(RegExp(r'^\d+\.\s+', multiLine: true), '');
  text = text.replaceAll(r'\n', '\n');
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  text = text.replaceAll('**', '');
  return text.trim();
}

// ── Agent response parser ────────────────────────────────────────────────────

typedef AgentParsed = ({String say, String phase, String? brief});

/// Parse the on-device agent's reply.
/// Accepts:
///   • "READY: <premise>" prefix
///   • JSON {"phase":"ready","say":"…","brief":"…"}
///   • Plain text → chatting phase
AgentParsed parseAgentResponse(String text, String lang) {
  final cleaned = text.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '').trim();

  final readyMatch = RegExp(r'READY:\s*(.+)', caseSensitive: false).firstMatch(cleaned);
  if (readyMatch != null) {
    final brief = readyMatch.group(1)!.trim().replaceAll(RegExp(r'["\n]'), '');
    final say = cleaned.substring(0, readyMatch.start).trim();
    return (say: say.isNotEmpty ? say : defaultReadyLine(lang), phase: 'ready', brief: brief);
  }

  try {
    final jsonStr = RegExp(r'\{[^{}]+\}').firstMatch(cleaned)?.group(0);
    if (jsonStr != null) {
      final m = jsonDecode(jsonStr) as Map<String, dynamic>;
      final phase = (m['phase'] as String?) ?? 'chatting';
      final say = (m['say'] as String?) ?? cleaned;
      final brief = (m['brief'] as String?) ?? (m['storyBrief'] as String?);
      if (phase == 'ready' && brief != null && brief.isNotEmpty) {
        return (say: say, phase: 'ready', brief: brief);
      }
      return (say: say.isNotEmpty ? say : cleaned, phase: 'chatting', brief: null);
    }
  } catch (_) {}

  return (say: cleaned.isEmpty ? '...' : cleaned, phase: 'chatting', brief: null);
}

String defaultReadyLine(String lang) => switch (lang) {
  'de' => 'Okay, lass uns anfangen!',
  'fr' => "D'accord, commençons!",
  'es' => '¡Muy bien, empecemos!',
  _ => 'Okay, let\'s begin!',
};

// ── Agent context (from /greeting API response) ──────────────────────────────

class AgentContext {
  final String name;
  final int age;
  final List<String> themes;
  final List<String> fears;
  final String? lastStory;

  const AgentContext({
    required this.name,
    required this.age,
    this.themes = const [],
    this.fears = const [],
    this.lastStory,
  });

  factory AgentContext.fromJson(Map<String, dynamic> m) => AgentContext(
        name: (m['name'] as String?) ?? '',
        age: (m['age'] as int?) ?? 0,
        themes: (m['themes'] as List<dynamic>?)?.cast<String>() ?? [],
        fears: (m['fears'] as List<dynamic>?)?.cast<String>() ?? [],
        lastStory: m['lastStory'] as String?,
      );
}

// ── Agent system prompt builder ──────────────────────────────────────────────

/// Builds the on-device agent system prompt. All instructions are in English
/// (reliable for multilingual small LLMs); the model is told to reply in [lang].
String buildAgentSystem({
  required String childName,
  required String lang,
  AgentContext? ctx,
}) {
  final langName = switch (lang) {
    'de' => 'Deutsch',
    'fr' => 'Français',
    'es' => 'Español',
    _ => 'English',
  };

  final n = ctx?.name.isNotEmpty == true ? ctx!.name : childName;
  final sb = StringBuffer();

  sb.write('You are Yarnia, a warm bedtime storyteller. ');
  sb.write('You are chatting with $n');
  if (ctx != null && ctx.age > 0) sb.write(', age ${ctx.age}');
  sb.write('. Reply ONLY in $langName. ');

  if (ctx?.lastStory != null) {
    sb.write("Last time you told $n a story about: ${ctx!.lastStory}. "
        "You may warmly nod to it if it feels natural — never retell it. ");
  }
  if (ctx != null && ctx.themes.isNotEmpty) {
    sb.write('$n loves stories about ${ctx.themes.join(', ')}. ');
  }
  if (ctx != null && ctx.fears.isNotEmpty) {
    sb.write('Always avoid: ${ctx.fears.join(', ')}. ');
  }

  sb.write('Your goal: chat briefly (1–2 short exchanges) to agree on tonight\'s story. ');
  sb.write('Keep every reply to 1–2 short sentences. Be warm, gentle, and cozy. ');
  sb.write('When you know what the story should be about, start your reply with '
      'READY: followed by a one-line story premise. '
      'Example: READY: a little fox who finds a glowing feather in the forest. '
      'Until you have a clear premise, ask one gentle follow-up question.');

  return sb.toString();
}
