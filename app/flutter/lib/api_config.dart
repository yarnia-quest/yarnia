// Shared config for calls to the Yarnia backend.
//
// API_TOKEN is an optional compile-time value (--dart-define=API_TOKEN=...). When the backend
// has YARNIA_API_TOKEN set, it requires a matching X-Yarnia-Token header on product routes; we
// attach it here. Left empty (the default), no header is sent and the open API works as before.
const String apiToken = String.fromEnvironment('API_TOKEN');

/// Headers for requests to the Yarnia backend. Pass [json] for requests with a JSON body.
/// Adds X-Yarnia-Token only when an API token was provided at build time.
Map<String, String> apiHeaders({bool json = false}) => {
      if (json) 'Content-Type': 'application/json',
      if (apiToken.isNotEmpty) 'X-Yarnia-Token': apiToken,
    };
