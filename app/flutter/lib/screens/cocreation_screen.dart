import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../widgets/starfield.dart';
import '../theme.dart';

const _chips = ['a dragon', 'an owl', 'a fox', 'a little bear'];

class CoCreationScreen extends StatefulWidget {
  final String childName;
  final void Function(String choice) onChoice;

  const CoCreationScreen({super.key, required this.childName, required this.onChoice});

  @override
  State<CoCreationScreen> createState() => _CoCreationScreenState();
}

class _CoCreationScreenState extends State<CoCreationScreen> with SingleTickerProviderStateMixin {
  final SpeechToText _speech = SpeechToText();
  bool _listening = false;
  bool _loading = false;
  String _transcript = '';
  late AnimationController _pulseController;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _pulse = Tween(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    await _speech.initialize();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _speech.stop();
    super.dispose();
  }

  Future<void> _toggleMic() async {
    if (_listening) {
      await _speech.stop();
      setState(() => _listening = false);
      _pulseController.stop();
      _pulseController.reset();
      if (_transcript.isNotEmpty) _handleChoice(_transcript);
    } else {
      setState(() { _transcript = ''; _listening = true; });
      _pulseController.repeat(reverse: true);
      await _speech.listen(
        onResult: (r) => setState(() => _transcript = r.recognizedWords),
        listenFor: const Duration(seconds: 10),
        localeId: 'en_US',
      );
    }
  }

  void _handleChoice(String choice) {
    if (_loading) return;
    setState(() => _loading = true);
    widget.onChoice(choice);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: navy,
      body: Stack(
        children: [
          const Positioned.fill(child: Starfield()),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    "Who's in tonight's story,\n${widget.childName}?",
                    style: const TextStyle(fontFamily: 'Fraunces', fontSize: 26, fontWeight: FontWeight.w700, color: cream, height: 1.4),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 40),
                  GestureDetector(
                    onTap: _loading ? null : _toggleMic,
                    child: SizedBox(
                      width: 88,
                      height: 88,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          AnimatedBuilder(
                            animation: _pulse,
                            builder: (_, __) => Transform.scale(
                              scale: _listening ? _pulse.value : 1.0,
                              child: Container(
                                width: 88,
                                height: 88,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: gold.withOpacity(0.4), width: 2),
                                ),
                              ),
                            ),
                          ),
                          Container(
                            width: 68,
                            height: 68,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: navyLight,
                              border: Border.all(color: gold, width: 1.5),
                            ),
                            child: Center(
                              child: Text(_listening ? '⏹' : '🎙', style: const TextStyle(fontSize: 28)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_transcript.isNotEmpty)
                    Text(
                      '"$_transcript"',
                      style: const TextStyle(fontFamily: 'Lora', color: gold, fontSize: 15, fontStyle: FontStyle.italic),
                      textAlign: TextAlign.center,
                    )
                  else
                    Text(
                      '— or pick one —',
                      style: TextStyle(fontFamily: 'Lora', color: cream.withOpacity(0.4), fontSize: 13, letterSpacing: 1),
                    ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.center,
                    children: _chips.map((chip) => GestureDetector(
                      onTap: _loading ? null : () => _handleChoice(chip),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 18),
                        decoration: BoxDecoration(
                          border: Border.all(color: gold),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Text(chip, style: const TextStyle(fontFamily: 'Lora', color: gold, fontSize: 14)),
                      ),
                    )).toList(),
                  ),
                  if (_loading) ...[
                    const SizedBox(height: 32),
                    const CircularProgressIndicator(color: gold),
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
