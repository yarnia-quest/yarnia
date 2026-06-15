import 'dart:io';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// On-device LLM (flutter_gemma / MediaPipe). Runs the story model fully on the
/// phone so generation never depends on the network (the Cloudflare Worker can't
/// reach Nebula anyway). Models are small ungated Qwen models.
///
/// Dev shortcut: if a model file (same basename as the URL) has been pushed to the
/// app's external files dir under `pushed-llm/`, it is installed from that file
/// instead of downloaded — so a tester can `adb push` models instead of waiting on
/// an in-app download. Production still uses the network download.
class LocalLlm {
  LocalLlm._();
  static final LocalLlm instance = LocalLlm._();

  bool _initialized = false;
  String? _activeUrl; // which model URL is currently the active one
  InferenceChat? _chat; // active multi-turn chat session

  Future<void> _ensureInit() async {
    if (_initialized) return;
    await FlutterGemma.initialize();
    _initialized = true;
  }

  // Returns the path to a pushed model file matching [url], if one exists.
  Future<String?> _pushedPath(String url) async {
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return null;
      final f = File(p.join(dir.path, 'pushed-llm', url.split('/').last));
      return f.existsSync() ? f.path : null;
    } catch (e) {
      return null;
    }
  }

  /// Download (or use a pushed file) + activate a model. [onProgress] reports 0..100.
  Future<void> install({
    required ModelType modelType,
    required ModelFileType fileType,
    required String url,
    required void Function(int) onProgress,
  }) async {
    await _ensureInit();
    final pushed = await _pushedPath(url);
    final builder = FlutterGemma.installModel(modelType: modelType, fileType: fileType);
    final src = pushed != null ? builder.fromFile(pushed) : builder.fromNetwork(url);
    await src.withProgress(onProgress).install();
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
    final pushed = await _pushedPath(url);
    final builder = FlutterGemma.installModel(modelType: modelType, fileType: fileType);
    final src = pushed != null ? builder.fromFile(pushed) : builder.fromNetwork(url);
    await src.install();
    _activeUrl = url;
  }

  bool get hasActiveModel => _initialized && FlutterGemma.hasActiveModel();

  /// True if a pushed or downloaded model file exists for [url] — does NOT
  /// require flutter_gemma to be initialized yet. Use this at startup to decide
  /// whether to enable the conversational agent before the first generation.
  Future<bool> modelFileReady(String url) async {
    final pushed = await _pushedPath(url);
    if (pushed != null) return true;
    return false;
  }

  /// Start a new multi-turn chat session. Call before the first [chatTurn].
  /// Closes any prior session so the token buffer starts fresh.
  Future<void> startChat(String system, {int maxTokens = 512}) async {
    await _ensureInit();
    await closeChat();
    final model = await FlutterGemma.getActiveModel(
      maxTokens: maxTokens,
      preferredBackend: PreferredBackend.gpu,
    );
    _chat = await model.createChat(
      systemInstruction: system,
      temperature: 0.7,
      tokenBuffer: 128,
    );
  }

  /// Send one user turn and stream back the model's reply.
  /// [startChat] must have been called first.
  Stream<String> chatTurn(String userMessage) async* {
    final chat = _chat;
    if (chat == null) {
      throw StateError('startChat() must be called before chatTurn()');
    }
    await chat.addQueryChunk(Message.text(text: userMessage, isUser: true));
    // generateChatResponseAsync streams token deltas; we collect TextResponse tokens.
    await for (final resp in chat.generateChatResponseAsync()) {
      if (resp is TextResponse) yield resp.token;
    }
  }

  /// Close the active chat session and free its resources.
  Future<void> closeChat() async {
    try {
      await _chat?.session.close();
    } catch (e) {
      // Closing a session that already closed is harmless.
    }
    _chat = null;
  }

  /// Stream a one-shot generation (no history). [system] becomes the session's
  /// systemInstruction; [user] is the query. Yields text deltas as the model produces them.
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
