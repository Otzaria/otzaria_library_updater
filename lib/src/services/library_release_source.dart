import '../models/delta_manifest.dart';
import '../models/library_release.dart';

/// מקור ה-releases של הספרייה: GitHub ([GithubLibraryReleaseClient]) או מראה
/// מקומית ([LocalMirrorLibraryReleaseClient]).
abstract class LibraryReleaseSource {
  Future<List<LibraryRelease>> fetchReleases();

  /// [url] הוא כתובת HTTP או נתיב קובץ — כל מקור מפרש את הצורה שלו.
  Future<DeltaManifest> fetchManifest(String url);

  /// סוגר משאבים פנימיים; לא כל מקור צריך ניקוי.
  void dispose() {}
}
