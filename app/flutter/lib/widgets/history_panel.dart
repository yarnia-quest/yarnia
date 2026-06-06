import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import '../theme.dart';

class HistoryPanel extends StatefulWidget {
  final String childId;
  final String apiBase;

  const HistoryPanel({super.key, required this.childId, required this.apiBase});

  @override
  State<HistoryPanel> createState() => _HistoryPanelState();
}

// In-memory cache so reopening the panel is instant.
List<Map<String, dynamic>>? _cachedSessions;
void invalidateHistoryCache() => _cachedSessions = null;
void warmHistoryCache(List<Map<String, dynamic>> sessions) => _cachedSessions = sessions;

class _HistoryPanelState extends State<HistoryPanel> {
  List<Map<String, dynamic>>? _sessions;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_cachedSessions != null) {
      _sessions = _cachedSessions;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final res = await http.get(
        Uri.parse('${widget.apiBase}/child/${widget.childId}/sessions'),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final sessions = (data['sessions'] as List).cast<Map<String, dynamic>>();
        _cachedSessions = sessions;
        setState(() => _sessions = sessions);
      } else {
        setState(() => _error = 'Could not load stories (${res.statusCode})');
      }
    } catch (e) {
      setState(() => _error = 'Could not reach Yarnia: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: navyLight,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: cream.withAlpha(60),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Story History',
            style: TextStyle(
              fontFamily: 'serif',
              color: gold,
              fontSize: 18,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 16),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, style: TextStyle(color: cream.withAlpha(140), fontFamily: 'serif')),
        ),
      );
    }
    if (_sessions == null) {
      return const Center(child: CircularProgressIndicator(color: gold));
    }
    if (_sessions!.isEmpty) {
      return Center(
        child: Text(
          'No stories yet.\nTell the first one tonight.',
          textAlign: TextAlign.center,
          style: TextStyle(color: cream.withAlpha(140), fontFamily: 'serif', height: 1.8),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      itemCount: _sessions!.length,
      separatorBuilder: (_, __) => Divider(color: cream.withAlpha(20), height: 1),
      itemBuilder: (_, i) => _SessionCard(session: _sessions![i], apiBase: widget.apiBase),
    );
  }
}

class _SessionCard extends StatelessWidget {
  final Map<String, dynamic> session;
  final String apiBase;

  const _SessionCard({required this.session, required this.apiBase});

  @override
  Widget build(BuildContext context) {
    final title = session['title'] as String? ?? 'A bedtime story';
    final characters = (session['charactersUsed'] as List?)?.cast<String>() ?? [];
    final ts = session['createdAt'] as int?;
    final date = ts != null ? _formatDate(DateTime.fromMillisecondsSinceEpoch(ts)) : null;

    return InkWell(
      onTap: () => _openDetail(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: 'serif',
                      color: cream,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (characters.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      characters.join(', '),
                      style: TextStyle(fontFamily: 'serif', color: gold.withAlpha(200), fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
            if (date != null)
              Text(date, style: TextStyle(fontFamily: 'serif', color: cream.withAlpha(100), fontSize: 12)),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, color: cream.withAlpha(80), size: 18),
          ],
        ),
      ),
    );
  }

  void _openDetail(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, __) => _StoryDetailSheet(session: session, apiBase: apiBase),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[dt.month - 1]} ${dt.day}';
  }
}

class _StoryDetailSheet extends StatefulWidget {
  final Map<String, dynamic> session;
  final String apiBase;

  const _StoryDetailSheet({required this.session, required this.apiBase});

  @override
  State<_StoryDetailSheet> createState() => _StoryDetailSheetState();
}

class _StoryDetailSheetState extends State<_StoryDetailSheet> {
  final AudioPlayer _player = AudioPlayer();
  bool _loading = false;
  bool _playing = false;
  String? _audioError;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await _player.stop();
      setState(() => _playing = false);
      return;
    }

    final audioKey = widget.session['audioKey'] as String?;
    if (audioKey == null || audioKey.isEmpty) {
      setState(() => _audioError = 'No audio stored for this story yet.');
      return;
    }

    setState(() { _loading = true; _audioError = null; });
    try {
      // Download via http (cleartext allowed) then play from file (ExoPlayer blocks http streams).
      final res = await http.get(Uri.parse('${widget.apiBase}/audio/$audioKey'));
      if (res.statusCode != 200) throw Exception('Audio fetch failed: ${res.statusCode}');
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/yarnia_replay.mp3');
      await file.writeAsBytes(res.bodyBytes);
      await _player.setFilePath(file.path);
      await _player.play();
      setState(() => _playing = true);

      _player.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed) {
          if (mounted) setState(() => _playing = false);
        }
      });
    } catch (e) {
      debugPrint('Audio replay failed: $e');
      setState(() => _audioError = 'Could not load audio. Try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.session['title'] as String? ?? 'A bedtime story';
    final storyText = widget.session['storyText'] as String?;
    final summary = widget.session['summary'] as String? ?? '';
    final notes = (widget.session['continuityNotes'] as List?)?.cast<String>() ?? [];
    final hasStory = storyText != null && storyText.isNotEmpty;

    return Container(
      decoration: const BoxDecoration(
        color: navyLight,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(color: cream.withAlpha(60), borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                title,
                style: const TextStyle(fontFamily: 'serif', color: cream, fontSize: 20, fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 20),
            // Listen button
            GestureDetector(
              onTap: _loading ? null : _togglePlay,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 28),
                decoration: BoxDecoration(
                  border: Border.all(color: gold, width: 1.5),
                  borderRadius: BorderRadius.circular(40),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_loading)
                      const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(color: gold, strokeWidth: 2),
                      )
                    else
                      Icon(_playing ? Icons.stop : Icons.play_arrow, color: gold, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      _loading ? 'Loading…' : _playing ? 'Stop' : 'Listen again',
                      style: const TextStyle(fontFamily: 'serif', color: gold, fontSize: 14, letterSpacing: 1),
                    ),
                  ],
                ),
              ),
            ),
            if (_audioError != null) ...[
              const SizedBox(height: 8),
              Text(_audioError!, style: TextStyle(color: cream.withAlpha(120), fontFamily: 'serif', fontSize: 12)),
            ],
            if (!hasStory && _audioError == null) ...[
              const SizedBox(height: 8),
              Text(
                'Audio replay available for new stories.',
                style: TextStyle(color: cream.withAlpha(80), fontFamily: 'serif', fontSize: 12),
              ),
            ],
            const SizedBox(height: 20),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (hasStory)
                      Text(
                        storyText!,
                        style: TextStyle(
                          fontFamily: 'serif',
                          fontSize: 15,
                          color: cream.withAlpha(220),
                          height: 1.7,
                          fontStyle: FontStyle.italic,
                        ),
                      )
                    else
                      Text(
                        summary,
                        style: TextStyle(fontFamily: 'serif', fontSize: 15, color: cream.withAlpha(180), height: 1.6),
                      ),
                    if (notes.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Text('Remember', style: TextStyle(fontFamily: 'serif', color: gold.withAlpha(180), fontSize: 12, letterSpacing: 1)),
                      const SizedBox(height: 8),
                      ...notes.map((n) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('· ', style: TextStyle(color: gold.withAlpha(160), fontSize: 13)),
                            Expanded(child: Text(n, style: TextStyle(fontFamily: 'serif', color: cream.withAlpha(140), fontSize: 13, height: 1.4))),
                          ],
                        ),
                      )),
                    ],
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void showHistoryPanel(BuildContext context, {required String childId, required String apiBase}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (_, __) => HistoryPanel(childId: childId, apiBase: apiBase),
    ),
  );
}
