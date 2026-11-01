import 'dart:convert';

import 'package:http/http.dart' as http;

import '../messages/library_updater_messages.dart';
import '../models/delta_manifest.dart';
import '../models/library_release.dart';
import '../models/split_asset.dart';
import 'library_http_exception.dart';
import 'library_release_source.dart';

/// לקוח לקריאת ה-releases וה-assets של ספריית הספרים מ-GitHub.
///
/// משתמש ב-`GET /releases` (ולא ב-`/releases/latest`), כי ה-latest אינו
/// מספיק כאשר הספרייה מפורסמת כ-prerelease.
class GithubLibraryReleaseClient implements LibraryReleaseSource {
  final String owner;
  final String repository;
  final http.Client _httpClient;
  final bool _ownsClient;

  /// ניתן לשינוי בזמן ריצה — נכנס לתוקף בבקשה הבאה.
  Duration timeout;

  /// GitHub API דוחה (403) בקשה בלי User-Agent.
  final String userAgent;

  static const String defaultUserAgent = 'otzaria-library-updater';

  GithubLibraryReleaseClient({
    this.owner = 'Otzaria',
    this.repository = 'SeforimLibrary',
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 15),
    this.userAgent = defaultUserAgent,
  })  : _httpClient = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  Map<String, String> get _apiHeaders => {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': userAgent,
      };

  static const int _perPage = 100;
  static const int _maxPages = 20; // backstop: עד 2000 releases

  /// שולף את כל ה-releases של המאגר עם pagination. זורק בכשל רשת/HTTP.
  @override
  Future<List<LibraryRelease>> fetchReleases() async {
    final messages = LibraryUpdaterMessages.current;
    final all = <LibraryRelease>[];
    for (var page = 1; page <= _maxPages; page++) {
      final url = Uri.parse(
        'https://api.github.com/repos/$owner/$repository/releases'
        '?per_page=$_perPage&page=$page',
      );
      final response =
          await _httpClient.get(url, headers: _apiHeaders).timeout(timeout);
      if (response.statusCode != 200) {
        throw LibraryHttpException.fromResponse(
          response,
          uri: url,
          message: messages.releasesRequestFailed(response.statusCode),
        );
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! List) {
        throw FormatException(messages.releasesResponseNotList);
      }
      all.addAll(
        decoded.whereType<Map<String, dynamic>>().map(LibraryRelease.fromJson),
      );
      if (decoded.length < _perPage) break; // העמוד האחרון
    }
    return all;
  }

  /// מוריד ומפענח manifest דלתאי מכתובת [url]. זורק בכשל רשת או parse.
  @override
  Future<DeltaManifest> fetchManifest(String url) async {
    final messages = LibraryUpdaterMessages.current;
    final response = await _httpClient.get(
      Uri.parse(url),
      headers: {'Accept': 'application/json', 'User-Agent': userAgent},
    ).timeout(timeout);
    if (response.statusCode != 200) {
      throw LibraryHttpException.fromResponse(
        response,
        uri: Uri.parse(url),
        message: messages.manifestDownloadFailed(url, response.statusCode),
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw FormatException(messages.manifestNotJsonObject(url));
    }
    return DeltaManifest.fromJson(decoded);
  }

  /// מוריד את מניפסט הפיצול [manifestAsset] ומחזיר את הנכס שהוא מתאר. זורק
  /// בכשל רשת, ו-[FormatException] על מניפסט פגום או על חלק חסר.
  Future<ReleaseAsset> resolveSplitAsset(
    LibraryRelease release,
    ReleaseAsset manifestAsset,
  ) async {
    final response = await _httpClient.get(
      Uri.parse(manifestAsset.downloadUrl),
      headers: {'Accept': 'application/json', 'User-Agent': userAgent},
    ).timeout(timeout);
    if (response.statusCode != 200) {
      throw LibraryHttpException.fromResponse(
        response,
        uri: Uri.parse(manifestAsset.downloadUrl),
        message: LibraryUpdaterMessages.current.splitManifestDownloadFailed(
          manifestAsset.name,
          response.statusCode,
        ),
      );
    }
    final index = release.assetIndex;
    final split = SplitAsset.fromManifestJson(
      jsonDecode(utf8.decode(response.bodyBytes)),
      manifestName: manifestAsset.name,
      partUrls: index.urls,
      partSizes: index.sizes,
    );
    return ReleaseAsset.fromSplit(manifestAsset, split);
  }

  /// סוגר את לקוח ה-HTTP אם הוא נוצר פנימית.
  @override
  void dispose() {
    if (_ownsClient) _httpClient.close();
  }
}
