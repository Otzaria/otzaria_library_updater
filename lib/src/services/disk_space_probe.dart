import 'dart:io';

import '../messages/library_updater_messages.dart';
import 'disk_space_native_stub.dart'
    if (dart.library.ffi) 'disk_space_native.dart';

/// כמה מקום פנוי יש על הנפח שבו יושב נתיב נתון. כשל מדידה מחזיר null ולא
/// אפס: מדידה שלא הצליחה אינה עדות שאין מקום, ואסור לה לחסום עדכון.
abstract final class DiskSpaceProbe {
  static String formatBytes(int bytes) {
    const gb = 1 << 30;
    const mb = 1 << 20;
    final messages = LibraryUpdaterMessages.current;
    if (bytes >= gb) return messages.gigabytes((bytes / gb).toStringAsFixed(1));
    return messages.megabytes((bytes / mb).round().toString());
  }

  /// הבייטים הפנויים לחשבון הנוכחי על הנפח של [path] (גם קובץ שעוד אינו
  /// קיים — נמדדת התיקייה הקיימת הראשונה מעליו), או null.
  static int? freeBytesFor(String path) {
    final dir = _nearestExistingDir(path);
    if (dir == null) return null;
    try {
      if (Platform.isWindows) return windowsFreeBytes(dir);
      if (Platform.isMacOS || Platform.isLinux) return _posixFreeBytes(dir);
    } catch (_) {
      // ספרייה חסרה, הרשאות, פלט לא צפוי — הכל "לא יודע".
    }
    return null;
  }

  static String? _nearestExistingDir(String path) {
    var current =
        Directory(path).existsSync() ? Directory(path) : Directory(path).parent;
    // חסם: נתיב שאינו קיים כלל (כונן שנשלף) לא ילופף לנצח.
    for (var depth = 0; depth < 64; depth++) {
      if (current.existsSync()) return current.path;
      final parent = current.parent;
      if (parent.path == current.path) return null;
      current = parent;
    }
    return null;
  }

  /// `df -k` — פשוט ואמין יותר מ-`statfs` ב-FFI, שהמבנה שלו משתנה בין מערכות.
  static int? _posixFreeBytes(String dir) {
    final result = Process.runSync('df', ['-kP', dir]);
    if (result.exitCode != 0) return null;
    final lines = (result.stdout as String).trim().split('\n');
    if (lines.length < 2) return null;
    final fields = lines.last.trim().split(RegExp(r'\s+'));
    if (fields.length < 4) return null;
    final availableKb = int.tryParse(fields[3]);
    if (availableKb == null) return null;
    return availableKb * 1024;
  }

  static const int fatMaxFileBytes = 0xFFFFFFFF;

  static bool isKnownFat(String path) {
    final dir = _nearestExistingDir(path);
    if (dir == null) return false;
    try {
      final String? name;
      if (Platform.isWindows) {
        name = windowsFileSystemName(dir);
      } else if (Platform.isMacOS || Platform.isLinux) {
        name = _posixFileSystemName(dir);
      } else {
        name = null;
      }
      return name != null && isFatFileSystemName(name);
    } catch (_) {
      return false;
    }
  }

  static bool isFatFileSystemName(String name) => const {
        'fat',
        'fat12',
        'fat16',
        'fat32',
        'msdos',
        'vfat',
      }.contains(name.trim().toLowerCase());

  static String? fileSystemFromMountTable(String mountOutput, String device) {
    final prefix = '$device on ';
    for (final line in mountOutput.split('\n')) {
      if (!line.startsWith(prefix)) continue;
      final linux = RegExp(r' type (\S+) \(').allMatches(line);
      if (linux.isNotEmpty) return linux.last.group(1);
      final options = line.lastIndexOf(' (');
      if (options < 0) return null;
      final rest = line.substring(options + 2);
      final end = rest.indexOf(RegExp('[,)]'));
      return (end < 0 ? rest : rest.substring(0, end)).trim();
    }
    return null;
  }

  static String? _posixFileSystemName(String dir) {
    final df = Process.runSync('df', ['-P', '-k', dir]);
    if (df.exitCode != 0) return null;
    final lines = (df.stdout as String).trim().split('\n');
    if (lines.length < 2) return null;
    final device = lines.last.trim().split(RegExp(r'\s+')).first;
    if (device.isEmpty) return null;
    final mount = Process.runSync('mount', const []);
    if (mount.exitCode != 0) return null;
    return fileSystemFromMountTable(mount.stdout as String, device);
  }

  static const int defaultHeadroomBytes = 256 << 20;

  static bool lacksSpace(
    int? freeBytes,
    int neededBytes, {
    int headroomBytes = defaultHeadroomBytes,
  }) =>
      freeBytes != null && freeBytes < neededBytes + headroomBytes;

  static bool isKnownInsufficient(
    String path,
    int neededBytes, {
    int headroomBytes = defaultHeadroomBytes,
  }) =>
      lacksSpace(freeBytesFor(path), neededBytes, headroomBytes: headroomBytes);
}
