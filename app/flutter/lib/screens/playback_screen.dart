import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../widgets/starfield.dart';
import '../theme.dart';

class PlaybackScreen extends StatefulWidget {
  final String childName;
  final String? storyText;
  final String? audioUrl;
  final VoidCallback onRestart;

  const PlaybackScreen({
    super.key,
    required this.childName,
    this.storyText,
    this.audioUrl,
    required this.onRestart,
  });

  @override
  State<PlaybackScreen> createState() => _PlaybackScreenState();
}

class _PlaybackScreenState extends State<PlaybackScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _dimAnim;
  late Animation<double> _textFade;
  final AudioPlayer _player = AudioPlayer();
  bool _shared = false;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 2300));
    _dimAnim = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0, 0.65, curve: Curves.easeIn)),
    );
    _textFade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0.65, 1.0, curve: Curves.easeIn)),
    );
    _controller.forward();
    _playAudio();
  }

  Future<void> _playAudio() async {
    final url = widget.audioUrl;
    if (url == null) return;
    try {
      if (url.startsWith('data:audio')) {
        final base64Data = url.substring(url.indexOf(',') + 1);
        final bytes = base64Decode(base64Data);
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/yarnia_story.mp3');
        await file.writeAsBytes(bytes);
        await _player.setFilePath(file.path);
      } else {
        await _player.setUrl(url);
      }
      await _player.play();
    } catch (e) {
      debugPrint('Audio playback failed: $e');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _share() async {
    try {
      await Share.share(
        'Yarnia told ${widget.childName} a bedtime story tonight. 🌙\nhttps://yarnia.quest',
        subject: 'Yarnia',
      );
      setState(() => _shared = true);
    } catch (e) {
      debugPrint('Share failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: navy,
      body: Stack(
        children: [
          const Positioned.fill(child: Starfield()),
          AnimatedBuilder(
            animation: _controller,
            builder: (_, __) => Opacity(
              opacity: _dimAnim.value,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    children: [
                      const SizedBox(height: 20),
                      Opacity(
                        opacity: 0.7,
                        child: const Text('🌙', style: TextStyle(fontSize: 36)),
                      ),
                      const SizedBox(height: 20),
                      Expanded(
                        child: Opacity(
                          opacity: _textFade.value,
                          child: SingleChildScrollView(
                            child: Text(
                              widget.storyText ?? 'Once upon a time, in a land between the last yawn and the first dream…',
                              style: TextStyle(
                                fontFamily: 'Lora',
                                fontSize: 17,
                                color: cream.withOpacity(0.9),
                                height: 1.65,
                                fontStyle: FontStyle.italic,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                      Opacity(
                        opacity: _textFade.value,
                        child: Column(
                          children: [
                            const SizedBox(height: 24),
                            GestureDetector(
                              onTap: _share,
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 36),
                                decoration: BoxDecoration(
                                  border: Border.all(color: gold, width: 1.5),
                                  borderRadius: BorderRadius.circular(40),
                                ),
                                child: Text(
                                  _shared ? 'Sent ✓' : 'Send to grandma',
                                  style: const TextStyle(fontFamily: 'Lora', color: gold, fontSize: 15, letterSpacing: 1),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            GestureDetector(
                              onTap: widget.onRestart,
                              child: Text(
                                'Another night →',
                                style: TextStyle(fontFamily: 'Lora', color: cream.withOpacity(0.4), fontSize: 13),
                              ),
                            ),
                            const SizedBox(height: 32),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
