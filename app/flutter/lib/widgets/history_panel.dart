import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../theme.dart';

class HistoryPanel extends StatefulWidget {
  final String childId;
  final String apiBase;

  const HistoryPanel({super.key, required this.childId, required this.apiBase});

  @override
  State<HistoryPanel> createState() => _HistoryPanelState();
}

class _HistoryPanelState extends State<HistoryPanel> {
  List<Map<String, dynamic>>? _sessions;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await http.get(
        Uri.parse('${widget.apiBase}/child/${widget.childId}/sessions'),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _sessions = (data['sessions'] as List).cast<Map<String, dynamic>>();
        });
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
      itemBuilder: (_, i) => _SessionCard(session: _sessions![i]),
    );
  }
}

class _SessionCard extends StatefulWidget {
  final Map<String, dynamic> session;
  const _SessionCard({required this.session});

  @override
  State<_SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends State<_SessionCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final title = widget.session['title'] as String? ?? 'A bedtime story';
    final summary = widget.session['summary'] as String? ?? '';
    final characters = (widget.session['charactersUsed'] as List?)?.cast<String>() ?? [];
    final notes = (widget.session['continuityNotes'] as List?)?.cast<String>() ?? [];
    final ts = widget.session['createdAt'] as int?;
    final date = ts != null
        ? _formatDate(DateTime.fromMillisecondsSinceEpoch(ts))
        : null;

    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontFamily: 'serif',
                      color: cream,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (date != null)
                  Text(
                    date,
                    style: TextStyle(fontFamily: 'serif', color: cream.withAlpha(100), fontSize: 12),
                  ),
                const SizedBox(width: 8),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  color: cream.withAlpha(100),
                  size: 18,
                ),
              ],
            ),
            if (characters.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                characters.join(', '),
                style: TextStyle(fontFamily: 'serif', color: gold.withAlpha(200), fontSize: 12),
              ),
            ],
            if (_expanded) ...[
              const SizedBox(height: 10),
              Text(
                summary,
                style: TextStyle(fontFamily: 'serif', color: cream.withAlpha(160), fontSize: 13, height: 1.5),
              ),
              if (notes.isNotEmpty) ...[
                const SizedBox(height: 8),
                ...notes.map(
                  (n) => Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('· ', style: TextStyle(color: gold.withAlpha(160), fontSize: 12)),
                        Expanded(
                          child: Text(
                            n,
                            style: TextStyle(color: cream.withAlpha(120), fontFamily: 'serif', fontSize: 12, height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[dt.month - 1]} ${dt.day}';
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
      builder: (_, scrollController) => HistoryPanel(childId: childId, apiBase: apiBase),
    ),
  );
}
