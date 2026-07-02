import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../models/delta_manifest.dart';
import '../models/patch_table_spec.dart';
import 'logical_content_hasher.dart';

/// תוצאת החלת patch מוצלחת.
class PatchApplyResult {
  final int migrations;
  final Map<String, int> upserts;
  final Map<String, int> deletes;
  final String resultHash;

  const PatchApplyResult({
    required this.migrations,
    required this.upserts,
    required this.deletes,
    required this.resultHash,
  });
}

/// נזרק כאשר preflight או אימות נכשלים — ה-DB לא שונה (לא בוצע commit).
class PatchApplyException implements Exception {
  final String message;
  const PatchApplyException(this.message);
  @override
  String toString() => 'PatchApplyException: $message';
}

/// מחיל patch DB דלתאי על `seforim.db` בצורה אטומית, ומשכפל את
/// `PatchApplier.kt` בצד הייצור.
///
/// הזרימה: preflight (גרסה/סכמה/hash) → ATTACH → migrations → upserts (סדר FK)
/// → deletes (סדר FK הפוך) → foreign_key_check → אימות `toContentHash` →
/// COMMIT. כל כשל גורם ל-ROLLBACK וזריקה, וה-DB נשאר ללא שינוי.
///
/// המתודה סינכרונית וחוסמת — יש להריצה ב-Isolate או אחרי
/// `closeForExternalWrite`.
class PatchApplier {
  final LogicalContentHasher hasher;

  /// גרסת הסכמה הגבוהה ביותר שהאפליקציה יודעת להחיל.
  final int supportedSchemaVersion;

  const PatchApplier({
    this.hasher = const LogicalContentHasher(),
    this.supportedSchemaVersion = 1,
  });

  /// מחיל את ה-patch שב-[patchPath] על ה-DB שב-[dbPath] לפי [manifest].
  ///
  /// [verifyFromHash] — אם פעיל, מחשב את ה-hash המקומי לפני apply ומשווה ל-
  /// `fromContentHash` (יקר אך מזהה DB ששונה ידנית/corruption).
  /// [checkForeignKeys] — אם פעיל, מוודא ש-`foreign_key_check` לא גדל.
  PatchApplyResult apply({
    required String dbPath,
    required String patchPath,
    required DeltaManifest manifest,
    bool verifyFromHash = true,
    bool checkForeignKeys = true,
    void Function(String stage)? onStage,
    void Function(int hashedBytes, int totalBytes)? onVerifyProgress,
    int? verifyTotalBytesHint,
  }) {
    // ללא hint (סך-הבתים מריצה קודמת), גודל הקובץ הוא הערכת-יתר — כולל
    // אינדקסים ו-overhead של דפים שאינם נכנסים ל-hash, והמד לא יגיע ל-100%.
    final totalBytes = onVerifyProgress == null
        ? 0
        : (verifyTotalBytesHint ?? File(dbPath).lengthSync());
    final void Function(int)? verifyProgress = onVerifyProgress == null
        ? null
        : (bytes) => onVerifyProgress(bytes, totalBytes);

    final db = sqlite3.sqlite3.open(dbPath);
    var attached = false;
    var inTransaction = false;
    try {
      db.execute('PRAGMA busy_timeout = 5000');
      // אכיפת FK פעילה (כמו צד הייצור). מחוץ ל-transaction — לא ניתן לשינוי
      // בתוך transaction. בתוך ה-transaction מוסיפים defer_foreign_keys.
      db.execute('PRAGMA foreign_keys = ON');

      // ── preflight: גרסה וסכמה מקומיות ──
      onStage?.call('preflight');
      final localVersion = _readSchemaMetaInt(db, 'db_version', schema: 'main');
      final localSchema =
          _readSchemaMetaInt(db, 'db_schema_version', schema: 'main');
      if (localVersion != manifest.fromVersion) {
        throw PatchApplyException(
          'גרסת ה-DB המקומי ($localVersion) אינה תואמת ל-patch '
          '(${manifest.fromVersion})',
        );
      }
      if (localSchema != null && localSchema != manifest.fromSchemaVersion) {
        throw PatchApplyException(
          'סכמת ה-DB המקומי ($localSchema) אינה תואמת ל-patch '
          '(${manifest.fromSchemaVersion})',
        );
      }

      // ── preflight: hash מקומי מול fromContentHash ──
      if (verifyFromHash) {
        onStage?.call('verifyFromHash');
        final localHash = hasher.compute(db, onProgress: verifyProgress);
        if (localHash != manifest.fromContentHash) {
          throw PatchApplyException(
            'ה-DB המקומי שונה מהצפוי — hash לא תואם ל-fromContentHash. '
            'נדרשת הורדה מלאה.',
          );
        }
      }

      // ── ATTACH (חייב להיות מחוץ ל-transaction) ──
      onStage?.call('attach');
      db.execute('ATTACH DATABASE ? AS patch', [patchPath]);
      attached = true;
      _assertPatchCompatible(db, manifest);

      final preFk = checkForeignKeys ? _countFkViolations(db) : 0;

      // ── transaction ──
      db.execute('BEGIN');
      inTransaction = true;
      db.execute('PRAGMA defer_foreign_keys = ON');

      onStage?.call('migrations');
      final migrations = _runMigrations(db);

      onStage?.call('upserts');
      final upserts = _runUpserts(db);

      onStage?.call('deletes');
      final deletes = _runDeletes(db);

      if (checkForeignKeys) {
        onStage?.call('foreignKeyCheck');
        final postFk = _countFkViolations(db);
        if (postFk > preFk) {
          throw PatchApplyException(
            'מספר הפרות מפתח זר גדל ($preFk→$postFk) — ה-patch אינו תקין',
          );
        }
      }

      onStage?.call('verifyToHash');
      final resultHash = hasher.compute(db, onProgress: verifyProgress);
      if (resultHash != manifest.toContentHash) {
        throw PatchApplyException(
          'ה-hash אחרי apply ($resultHash) אינו תואם ל-toContentHash '
          '(${manifest.toContentHash})',
        );
      }

      onStage?.call('commit');
      db.execute('COMMIT');
      inTransaction = false;

      db.execute('DETACH DATABASE patch');
      attached = false;

      return PatchApplyResult(
        migrations: migrations,
        upserts: upserts,
        deletes: deletes,
        resultHash: resultHash,
      );
    } catch (_) {
      if (inTransaction) {
        try {
          db.execute('ROLLBACK');
        } catch (_) {}
      }
      if (attached) {
        try {
          db.execute('DETACH DATABASE patch');
        } catch (_) {}
      }
      rethrow;
    } finally {
      db.close();
    }
  }

  void _assertPatchCompatible(sqlite3.Database db, DeltaManifest manifest) {
    final schemaVersion = _readPatchMetaInt(db, 'schema_version');
    if (schemaVersion == null) {
      throw const PatchApplyException('patch_meta.schema_version חסר ב-patch');
    }
    if (schemaVersion > supportedSchemaVersion) {
      throw PatchApplyException(
        'גרסת סכמת ה-patch ($schemaVersion) חדשה מהנתמך '
        '($supportedSchemaVersion) — נדרש עדכון תוכנה',
      );
    }
    final from = _readPatchMetaInt(db, 'from_version');
    final to = _readPatchMetaInt(db, 'to_version');
    if (from != manifest.fromVersion || to != manifest.toVersion) {
      throw PatchApplyException(
        'גרסאות ה-patch ($from→$to) אינן תואמות ל-manifest '
        '(${manifest.fromVersion}→${manifest.toVersion})',
      );
    }
  }

  int _runMigrations(sqlite3.Database db) {
    final result =
        db.select('SELECT sql FROM patch.migrations ORDER BY version ASC');
    var count = 0;
    for (final row in result) {
      db.execute(row['sql'] as String);
      count++;
    }
    return count;
  }

  Map<String, int> _runUpserts(sqlite3.Database db) {
    final counts = <String, int>{};
    for (final table in kPatchTablesInFkOrder) {
      final patchTable = 'upsert_${table.name}';
      if (!_patchHasTable(db, patchTable)) continue;
      final cols = _patchTableColumns(db, patchTable);
      if (cols.isEmpty) continue;

      final colsCsv = cols.map((c) => '"$c"').join(',');
      final pkCsv = table.primaryKey.map((c) => '"$c"').join(',');
      final nonPkCols =
          cols.where((c) => !table.primaryKey.contains(c)).toList();

      final String conflictClause;
      if (!table.updatable || nonPkCols.isEmpty) {
        conflictClause = 'ON CONFLICT($pkCsv) DO NOTHING';
      } else {
        final assignments =
            nonPkCols.map((c) => '"$c" = excluded."$c"').join(',');
        conflictClause = 'ON CONFLICT($pkCsv) DO UPDATE SET $assignments';
      }

      // `WHERE true` נדרש כדי שה-parser ישייך את ON CONFLICT ל-INSERT ולא ל-SELECT.
      db.execute(
        'INSERT INTO "${table.name}" ($colsCsv) '
        'SELECT $colsCsv FROM patch."$patchTable" WHERE true $conflictClause',
      );
      counts[table.name] = db.updatedRows;
    }
    return counts;
  }

  Map<String, int> _runDeletes(sqlite3.Database db) {
    final counts = <String, int>{};
    for (final table in kPatchTablesInFkOrder.reversed) {
      final patchTable = 'delete_${table.name}';
      if (!_patchHasTable(db, patchTable)) continue;
      if (table.primaryKey.isEmpty) continue;

      final pkCsv = table.primaryKey.map((c) => '"$c"').join(',');
      final String sql;
      if (table.primaryKey.length == 1) {
        final k = '"${table.primaryKey.first}"';
        sql = 'DELETE FROM "${table.name}" WHERE $k IN '
            '(SELECT $k FROM patch."$patchTable")';
      } else {
        sql = 'DELETE FROM "${table.name}" WHERE ($pkCsv) IN '
            '(SELECT $pkCsv FROM patch."$patchTable")';
      }
      db.execute(sql);
      counts[table.name] = db.updatedRows;
    }
    return counts;
  }

  int _countFkViolations(sqlite3.Database db) {
    return db.select('PRAGMA foreign_key_check').length;
  }

  bool _patchHasTable(sqlite3.Database db, String name) {
    final result = db.select(
      "SELECT 1 FROM patch.sqlite_master WHERE type='table' AND name=? LIMIT 1",
      [name],
    );
    return result.isNotEmpty;
  }

  List<String> _patchTableColumns(sqlite3.Database db, String name) {
    final result = db.select('PRAGMA patch.table_info("$name")');
    return result.map((r) => r['name'] as String).toList();
  }

  int? _readPatchMetaInt(sqlite3.Database db, String key) {
    try {
      final result = db.select(
        'SELECT value FROM patch.patch_meta WHERE key = ? LIMIT 1',
        [key],
      );
      if (result.isEmpty) return null;
      return int.tryParse(result.first['value']?.toString() ?? '');
    } catch (_) {
      return null;
    }
  }

  int? _readSchemaMetaInt(sqlite3.Database db, String key,
      {required String schema}) {
    try {
      final result = db.select(
        'SELECT value FROM $schema.schema_meta WHERE key = ? LIMIT 1',
        [key],
      );
      if (result.isEmpty) return null;
      return int.tryParse(result.first['value']?.toString() ?? '');
    } catch (_) {
      return null;
    }
  }
}
