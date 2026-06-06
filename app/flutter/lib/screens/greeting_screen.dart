import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../widgets/starfield.dart';
import '../widgets/history_panel.dart';
import '../theme.dart';

class GreetingScreen extends StatefulWidget {
  final String childName;
  final String childId;
  final String apiBase;
  final VoidCallback onBegin;

  const GreetingScreen({
    super.key,
    required this.childName,
    required this.childId,
    required this.apiBase,
    required this.onBegin,
  });

  @override
  State<GreetingScreen> createState() => _GreetingScreenState();
}

class _GreetingScreenState extends State<GreetingScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _moonScale;
  late Animation<double> _fade;
  late Animation<double> _textFade;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000));
    _moonScale = Tween(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0, 0.6, curve: Curves.elasticOut)),
    );
    _fade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0, 0.6, curve: Curves.easeIn)),
    );
    _textFade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0.6, 1.0, curve: Curves.easeIn)),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: navy,
      body: Stack(
        children: [
          const Positioned.fill(child: Starfield()),
          Positioned(
            top: 48,
            right: 20,
            child: IconButton(
              icon: Icon(Icons.history, color: cream.withAlpha(120), size: 22),
              onPressed: () => showHistoryPanel(
                context,
                childId: widget.childId,
                apiBase: widget.apiBase,
              ),
            ),
          ),
          AnimatedBuilder(
            animation: _controller,
            builder: (_, __) => Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Opacity(
                      opacity: _fade.value,
                      child: Transform.scale(
                        scale: _moonScale.value,
                        child: const Text('🌙', style: TextStyle(fontSize: 96)),
                      ),
                    ),
                    const SizedBox(height: 32),
                    Opacity(
                      opacity: _textFade.value,
                      child: Column(
                        children: [
                          Text(
                            'Good night, ${widget.childName}.',
                            style: const TextStyle(fontFamily: 'serif', fontSize: 28, fontWeight: FontWeight.w700, color: cream),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Your story is waiting in Yarnia.',
                            style: const TextStyle(fontFamily: 'serif', fontSize: 16, color: gold),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 48),
                          GestureDetector(
                            onTap: widget.onBegin,
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 52),
                              decoration: BoxDecoration(
                                border: Border.all(color: gold, width: 1.5),
                                borderRadius: BorderRadius.circular(40),
                              ),
                              child: const Text(
                                'Begin',
                                style: TextStyle(fontFamily: 'serif', color: gold, fontSize: 16, letterSpacing: 1.5),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
