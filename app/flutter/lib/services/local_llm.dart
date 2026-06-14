import 'package:flutter_gemma/flutter_gemma.dart';

/// On-device LLM (flutter_gemma / MediaPipe). Runs the story model fully on the
/// phone so generation never depends on the network (the Cloudflare Worker can't
/// reach Nebula anyway). Models are small ungated Qwen .task files.
class LocalLlm {
  LocalLlm._();
  static final LocalLlm instance = LocalLlm._();

  bool _initialized = false;
  String? _activeUrl; // which model URL is currently the active one

  Future<void> _ensureInit() async {
    if (_initialized) return;
    await FlutterGemma.initialize();
    _initialized = true;
  }

  /// Download + activate a model. [onProgress] reports 0..100. Idempotent — if the
  /// file is already present it skips the download and just sets it active.
  Future<void> install({
    required ModelType modelType,
    required ModelFileType fileType,
    required String url,
    required void Function(int) onProgress,
  }) async {
    await _ensureInit();
    await FlutterGemma.installModel(modelType: modelType, fileType: fileType)
        .fromNetwork(url)
        .withProgress(onProgress)
        .install();
    _activeUrl = url;
  }

  /// Ensure [url]'s model is the active one (idempotent install, no re-download).
  Future<void> activate({
    required ModelType modelType,
    required ModelFileType fileType,
    required String url,
  }) async {
    if (_activeUrl == url && FlutterGemma.hasActiveModel()) return;
    await _ensureInit();
    await FlutterGemma.installModel(modelType: modelType, fileType: fileType)
        .fromNetwork(url)
        .install();
    _activeUrl = url;
  }

  bool get hasActiveModel => _initialized && FlutterGemma.hasActiveModel();

  /// Stream a generation. [system] becomes the session's systemInstruction; [user]
  /// is the query. Yields text deltas as the model produces them.
  Stream<String> generate({
    required String system,
    required String user,
    int maxTokens = 1024,
    double temperature = 0.8,
  }) async* {
    await _ensureInit();
    final model = await FlutterGemma.getActiveModel(
      maxTokens: maxTokens,
      preferredBackend: PreferredBackend.gpu,
    );
    final session = await model.createSession(
      temperature: temperature,
      systemInstruction: system,
    );
    try {
      await session.addQueryChunk(Message.text(text: user, isUser: true));
      yield* session.getResponseAsync();
    } finally {
      await session.close();
    }
  }
}
