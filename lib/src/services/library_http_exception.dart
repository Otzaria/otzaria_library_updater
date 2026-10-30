import 'dart:convert';

import 'package:http/http.dart' as http;

/// An HTTP failure with a display message and bounded diagnostics for logs.
class LibraryHttpException implements Exception {
  LibraryHttpException.fromResponse(
    http.Response response, {
    required this.uri,
    required this.message,
  })  : statusCode = response.statusCode,
        responseHeaders = Map.unmodifiable({
          for (final name in _diagnosticHeaders)
            if (response.headers[name] case final value?)
              name: value.substring(0, value.length.clamp(0, 256)),
        }),
        responseSnippet = _snippet(response.bodyBytes);

  final Uri uri;
  final int statusCode;
  final String message;
  final Map<String, String> responseHeaders;
  final String responseSnippet;

  // An asset's 403 can be an expired signed URL; only 418 proves a filter block.
  bool get isBlockedByFilter => statusCode == 418;

  static const _diagnosticHeaders = [
    'content-type',
    'server',
    'via',
    'x-github-request-id',
    'retry-after',
    'x-ratelimit-remaining',
    'x-ratelimit-reset',
  ];

  static String _snippet(List<int> bytes) {
    final text = utf8
        .decode(bytes.take(1024).toList(), allowMalformed: true)
        .replaceAll(RegExp(r'[\x00-\x20\x7f]+'), ' ')
        .trim();
    return text.substring(0, text.length.clamp(0, 512));
  }

  Map<String, Object> get diagnostics => {
        'uri': Uri(
          scheme: uri.scheme,
          host: uri.host,
          port: uri.hasPort ? uri.port : null,
          path: uri.path,
        ).toString(),
        'statusCode': statusCode,
        'headers': responseHeaders,
        'body': responseSnippet,
      };

  @override
  String toString() => message;
}
