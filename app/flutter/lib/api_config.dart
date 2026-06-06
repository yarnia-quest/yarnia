// Shared config for calls to the Yarnia backend.
//
// API_TOKEN is an optional compile-time value (--dart-define=API_TOKEN=...). When the backend
// has YARNIA_API_TOKEN set, it requires a matching X-Yarnia-Token header on product routes; we
// attach it here. Left empty (the default), no header is sent and the open API works as before.
const String apiToken = String.fromEnvironment('API_TOKEN');

/// The active child's per-child auth token (set when a profile becomes active). Sent as
/// X-Child-Token so child-scoped routes (/story, /child/:id/sessions, /agent/session) only
/// serve the device that owns the profile. Null/empty for legacy profiles created before tokens.
String? activeChildToken;

/// Headers for requests to the Yarnia backend. Pass [json] for requests with a JSON body.
/// Adds X-Yarnia-Token when an API token was provided at build time, and X-Child-Token for the
/// active child profile when present.
Map<String, String> apiHeaders({bool json = false}) => {
      if (json) 'Content-Type': 'application/json',
      if (apiToken.isNotEmpty) 'X-Yarnia-Token': apiToken,
      if (activeChildToken != null && activeChildToken!.isNotEmpty) 'X-Child-Token': activeChildToken!,
    };
