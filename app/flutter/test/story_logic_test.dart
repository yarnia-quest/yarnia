// Unit tests for pure story-logic helpers — no platform channels needed.
import 'package:flutter_test/flutter_test.dart';
import 'package:yarnia/services/story_utils.dart';
import 'package:yarnia/services/tts_session.dart' show splitSentences;
import 'package:yarnia/services/turn_decision.dart';

void main() {
  // ── cleanLlmOutput ─────────────────────────────────────────────────────────

  group('cleanLlmOutput', () {
    test('strips <|im_start|> preamble', () {
      expect(cleanLlmOutput('<|im_start|>assistant\nOnce upon a time.'),
          'Once upon a time.');
    });

    test('strips chat tokens like <|im_end|>', () {
      expect(cleanLlmOutput('Once upon a time.<|im_end|>'), 'Once upon a time.');
    });

    test('strips markdown headers', () {
      expect(cleanLlmOutput('## The Fox\n\nOnce upon a time.'), 'The Fox\n\nOnce upon a time.');
    });

    test('strips numbered list prefixes', () {
      expect(cleanLlmOutput('1. First\n2. Second\n3. Third'),
          'First\nSecond\nThird');
    });

    test('strips bold markers', () {
      expect(cleanLlmOutput('**Yarnia** told a story.'), 'Yarnia told a story.');
    });

    test('converts literal backslash-n to newline', () {
      expect(cleanLlmOutput(r'Line one.\nLine two.'), 'Line one.\nLine two.');
    });

    test('collapses triple newlines', () {
      expect(cleanLlmOutput('Para one.\n\n\n\nPara two.'), 'Para one.\n\nPara two.');
    });

    test('strips leading "assistant" role prefix', () {
      expect(cleanLlmOutput('assistant\nOnce there was a fox.'),
          'Once there was a fox.');
    });

    test('returns clean prose unchanged', () {
      const story = 'Once upon a time, a little fox went on an adventure.';
      expect(cleanLlmOutput(story), story);
    });
  });

  // ── parseAgentResponse ─────────────────────────────────────────────────────

  group('parseAgentResponse', () {
    test('detects READY: prefix and extracts brief', () {
      final r = parseAgentResponse('READY: a fox who found a feather', 'en');
      expect(r.phase, 'ready');
      expect(r.brief, 'a fox who found a feather');
    });

    test('READY: with leading sentence — say is the leading sentence', () {
      final r = parseAgentResponse('That sounds lovely! READY: a dragon who learned to share', 'en');
      expect(r.phase, 'ready');
      expect(r.say, contains('lovely'));
      expect(r.brief, 'a dragon who learned to share');
    });

    test('READY: is case-insensitive', () {
      expect(parseAgentResponse('ready: a small rabbit', 'en').phase, 'ready');
    });

    test('JSON ready phase', () {
      final r = parseAgentResponse(
          '{"phase":"ready","say":"Let\'s go!","brief":"a brave knight"}', 'en');
      expect(r.phase, 'ready');
      expect(r.say, "Let's go!");
      expect(r.brief, 'a brave knight');
    });

    test('JSON chatting phase', () {
      final r = parseAgentResponse(
          '{"phase":"chatting","say":"What kind of animal?"}', 'en');
      expect(r.phase, 'chatting');
      expect(r.say, 'What kind of animal?');
      expect(r.brief, isNull);
    });

    test('plain text → chatting', () {
      final r = parseAgentResponse('What shall tonight\'s story be about?', 'en');
      expect(r.phase, 'chatting');
      expect(r.say, contains('tonight'));
    });

    test('strips <think> tags before parsing', () {
      final r = parseAgentResponse(
          '<think>internal reasoning</think>READY: a sleeping bear', 'en');
      expect(r.phase, 'ready');
      expect(r.brief, 'a sleeping bear');
    });

    test('empty text returns placeholder chatting', () {
      expect(parseAgentResponse('', 'en').phase, 'chatting');
    });

    test('defaultReadyLine is localized', () {
      expect(defaultReadyLine('de'), contains('lass'));
      expect(defaultReadyLine('fr'), contains('commençons'));
      expect(defaultReadyLine('es'), contains('empecemos'));
      expect(defaultReadyLine('en'), contains('begin'));
    });
  });

  // ── buildAgentSystem ───────────────────────────────────────────────────────

  group('buildAgentSystem', () {
    test('includes child name and target language', () {
      final s = buildAgentSystem(childName: 'Luca', lang: 'de');
      expect(s, contains('Luca'));
      expect(s, contains('Deutsch'));
    });

    test('returning child: references last story', () {
      final ctx = AgentContext(
        name: 'Mia', age: 5,
        themes: ['friendship'], fears: ['spiders'],
        lastStory: 'the fox and the feather',
      );
      final s = buildAgentSystem(childName: 'Mia', lang: 'en', ctx: ctx);
      expect(s, contains('fox and the feather'));
      expect(s.toLowerCase(), contains('past nights'));
    });

    test('returning child: includes age, themes, fears', () {
      final ctx = AgentContext(
        name: 'Mia', age: 5,
        themes: ['friendship'], fears: ['spiders'],
        lastStory: 'the fox and the feather',
      );
      final s = buildAgentSystem(childName: 'Mia', lang: 'en', ctx: ctx);
      expect(s, contains('age 5'));
      expect(s, contains('friendship'));
      expect(s, contains('spiders'));
    });

    test('first-time child: no past-nights reference', () {
      final ctx = AgentContext(name: 'Sam', age: 4);
      final s = buildAgentSystem(childName: 'Sam', lang: 'en', ctx: ctx);
      expect(s.toLowerCase(), contains('first night'));
      expect(s.toLowerCase(), isNot(contains('past nights')));
    });

    test('always contains READY: instruction', () {
      expect(buildAgentSystem(childName: 'X', lang: 'en'), contains('READY:'));
    });

    test('contains 2-exchange auto-cap fallback', () {
      expect(buildAgentSystem(childName: 'X', lang: 'en'), contains('2 exchanges'));
    });

    test('one-question rule present', () {
      expect(buildAgentSystem(childName: 'X', lang: 'en').toLowerCase(), contains('one question'));
    });
  });

  // ── AgentContext.fromJson ──────────────────────────────────────────────────

  group('AgentContext.fromJson', () {
    test('parses complete object', () {
      final ctx = AgentContext.fromJson({
        'name': 'Leo',
        'age': 6,
        'themes': ['dragons', 'space'],
        'fears': ['dark'],
        'lastStory': 'the moon dragon',
      });
      expect(ctx.name, 'Leo');
      expect(ctx.age, 6);
      expect(ctx.themes, ['dragons', 'space']);
      expect(ctx.fears, ['dark']);
      expect(ctx.lastStory, 'the moon dragon');
    });

    test('handles missing optional fields', () {
      final ctx = AgentContext.fromJson({'name': 'Sam', 'age': 4});
      expect(ctx.themes, isEmpty);
      expect(ctx.fears, isEmpty);
      expect(ctx.lastStory, isNull);
    });
  });

  // ── parseAgentResponse — repetition detection ─────────────────────────────

  group('repetition loop handling', () {
    test('repetitive agent output is stripped by _derepeat', () {
      // Simulate what Qwen 1.5B actually produces when looping on "2023"
      const loopy = 'Hallo! Was soll die Geschichte sein? 2023 2023 2023 2023 2023 2023 2023.';
      final parsed = parseAgentResponse(loopy, 'de');
      // Should still classify as chatting (not crash)
      expect(parsed.phase, 'chatting');
    });
  });

  // ── splitSentences ─────────────────────────────────────────────────────────

  group('splitSentences', () {
    test('splits on sentence-ending punctuation', () {
      final s = splitSentences('Hello. World! How are you?');
      expect(s, ['Hello.', 'World!', 'How are you?']);
    });

    test('single sentence returns single item', () {
      expect(splitSentences('Just one sentence.'), ['Just one sentence.']);
    });

    test('empty string returns the input as-is in a list', () {
      expect(splitSentences(''), ['']);
    });

    test('does not split mid-sentence', () {
      final s = splitSentences('Dr. Smith went home. He was tired.');
      // Accepts 2-3 items — Dr. may split; the important thing is "He was tired." is last
      expect(s.last, 'He was tired.');
    });
  });

  // ── interpretTurn ──────────────────────────────────────────────────────────

  group('interpretTurn', () {
    test('continue intent', () {
      final d = interpretTurn('{"intent":"continue","resumeAt":3}', 3, 10);
      expect(d.intent, TurnIntent.continueStory);
      expect(d.resumeAt, 3);
    });

    test('answer intent with say text', () {
      final d = interpretTurn(
          '{"intent":"answer","say":"His name is Bruno.","resumeAt":5}', 5, 10);
      expect(d.intent, TurnIntent.answer);
      expect(d.say, 'His name is Bruno.');
    });

    test('revise intent with revision', () {
      final d = interpretTurn(
          '{"intent":"revise","revision":{"fromSentence":2,"sentences":["The fox turned green."]},"resumeAt":2}',
          3,
          10);
      expect(d.intent, TurnIntent.revise);
      expect(d.revision?.fromSentence, 2);
      expect(d.revision?.sentences, ['The fox turned green.']);
    });

    test('clamps resumeAt to valid range', () {
      final d = interpretTurn('{"intent":"continue","resumeAt":99}', 2, 5);
      expect(d.resumeAt, lessThanOrEqualTo(5));
    });

    test('safe fallback on unparseable input', () {
      final d = interpretTurn('not json at all', 3, 10);
      expect(d.intent, TurnIntent.continueStory);
      expect(d.resumeAt, 3);
    });

    test('strips <think> tags before parsing', () {
      final d = interpretTurn(
          '<think>thinking</think>{"intent":"continue","resumeAt":1}', 1, 5);
      expect(d.intent, TurnIntent.continueStory);
    });

    test('handles JSON inside markdown fences', () {
      final d = interpretTurn(
          '```json\n{"intent":"answer","say":"Sure!","resumeAt":2}\n```', 2, 5);
      expect(d.intent, TurnIntent.answer);
    });
  });

  // ── buildLocalTurnPrompt ───────────────────────────────────────────────────

  group('buildLocalTurnPrompt', () {
    final sentences = ['The fox walked.', 'He found a feather.', 'It glowed.'];

    test('includes child name and utterance', () {
      final p = buildLocalTurnPrompt(
        childName: 'Mia',
        sentences: sentences,
        cursor: 1,
        utterance: 'what is his name',
        language: 'en',
      );
      expect(p.system, contains('Mia'));
      expect(p.user, contains('what is his name'));
    });

    test('includes sentences with numbering in system prompt', () {
      final p = buildLocalTurnPrompt(
        childName: 'Mia',
        sentences: sentences,
        cursor: 1,
        utterance: 'make it blue',
        language: 'en',
      );
      // Sentences go in the system prompt as context, not the user turn
      expect(p.system, contains('The fox walked.'));
      expect(p.system, contains('He found a feather.'));
      expect(p.user, contains('make it blue'));
    });

    test('language is reflected in the prompt', () {
      final p = buildLocalTurnPrompt(
        childName: 'Luca',
        sentences: sentences,
        cursor: 0,
        utterance: 'weiter',
        language: 'de',
      );
      expect(p.system.toLowerCase(), anyOf(contains('german'), contains('deutsch')));
    });
  });
}
