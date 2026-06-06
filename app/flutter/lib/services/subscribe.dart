import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import '../api_config.dart';
import '../theme.dart';

/// Starts the EUR 8/month subscription: asks the backend for a Mollie hosted-checkout URL
/// (POST /checkout) and surfaces it in a sheet so the parent can complete payment. Kept
/// dependency-light (the secure link is shown and can be opened/shared via the system sheet)
/// so it works on web, iOS, and Android without extra plugins.
Future<void> showSubscribeSheet(BuildContext context, String apiBase) async {
  String? checkoutUrl;
  String? error;
  try {
    final res = await http.post(
      Uri.parse('$apiBase/checkout'),
      headers: apiHeaders(json: true),
      body: '{}',
    );
    if (res.statusCode == 200) {
      checkoutUrl = (jsonDecode(res.body) as Map<String, dynamic>)['checkoutUrl'] as String?;
    } else if (res.statusCode == 503) {
      error = 'Subscriptions are opening soon.';
    } else {
      error = 'Could not start checkout. Please try again in a moment.';
    }
  } catch (_) {
    error = 'Could not reach checkout. Please check your connection.';
  }
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: navyLight,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🌙', style: TextStyle(fontSize: 36)),
          const SizedBox(height: 12),
          const Text(
            'Yarnia, every night',
            style: TextStyle(fontFamily: 'Fraunces', fontSize: 20, color: cream, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'Unlimited personalized stories · €8/month',
            style: TextStyle(fontFamily: 'Lora', color: gold.withAlpha(220), fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          if (checkoutUrl != null) ...[
            SelectableText(
              checkoutUrl!,
              style: TextStyle(fontFamily: 'Lora', color: cream.withAlpha(160), fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () => Share.share('Subscribe to Yarnia: ${checkoutUrl!}', subject: 'Yarnia subscription'),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 36),
                decoration: BoxDecoration(
                  border: Border.all(color: gold, width: 1.5),
                  borderRadius: BorderRadius.circular(40),
                ),
                child: const Text(
                  'Continue to secure checkout',
                  style: TextStyle(fontFamily: 'Lora', color: gold, fontSize: 15, letterSpacing: 1),
                ),
              ),
            ),
          ] else
            Text(
              error ?? 'Something went wrong.',
              style: TextStyle(fontFamily: 'Lora', color: cream.withAlpha(200), fontSize: 14),
              textAlign: TextAlign.center,
            ),
        ],
      ),
    ),
  );
}
