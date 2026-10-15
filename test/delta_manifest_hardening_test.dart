import 'dart:convert';

import 'package:seforim_library_updater/src/messages/library_updater_messages.dart';
import 'package:seforim_library_updater/src/models/delta_manifest.dart';
import 'package:test/test.dart';

void main() {
  group('DeltaManifest.fromJson', () {
    // manifest אמיתי מתוך patch-v1-v2.db.zst.manifest.json
    const validJson = '''
    {
      "fromVersion": 1,
      "toVersion": 2,
      "fromSchemaVersion": 1,
      "toSchemaVersion": 1,
      "fromContentHash": "35d499985cc1c37fd02904682d4f67a8c915625ef3768c0e856d3f79a4fc96c1",
      "toContentHash": "2be5318d73e4ffa6b32c5d265699e6000cd84f776c304db4a9b192e7d67b3d06",
      "patchFiles": [
        {
          "file": "patch-v1-v2.db.zst",
          "compression": "zstd",
          "sha256": "c4eb8984f9c45d0e61463f7474133b66461f82320039327acfaf7ba288ee0d9b",
          "size": 1040075,
          "uncompressedSha256": "c02ccccd132e2b331e24ee60ca7886c4ee35b122d2b602d3690176e633c8ea05",
          "uncompressedSize": 5726208
        }
      ]
    }
    ''';

    for (final name in [
      '../seforim.db.zst',
      r'..\seforim.db.zst',
      'sub/patch-v1-v2.db.zst',
      '.',
      '..',
    ]) {
      test('שם קובץ patch שאינו שם פשוט נדחה: $name', () {
        final json = jsonDecode(validJson) as Map<String, dynamic>;
        (json['patchFiles'] as List).first['file'] = name;
        expect(() => DeltaManifest.fromJson(json), throwsFormatException);
      });
    }
    test('איבר patchFiles שאינו אובייקט → FormatException ולא TypeError', () {
      final json = jsonDecode(validJson) as Map<String, dynamic>;
      json['patchFiles'] = ['patch-v1-v2.db.zst'];
      expect(() => DeltaManifest.fromJson(json), throwsFormatException);
    });

    test('booksTouched ו-catalogBlobName מסוג שגוי נקראים בסלחנות', () {
      final json = jsonDecode(validJson) as Map<String, dynamic>;
      json['booksTouched'] = ['123', 7, null, 8.0];
      json['catalogBlobName'] = 42;
      final m = DeltaManifest.fromJson(json);
      expect(m.booksTouched, [7, 8]);
      expect(m.catalogBlobName, isNull);
    });

    // פענוח שנכשל היה מעלים את הגרסה מהגרף; הפסילה נעשית ב-PatchEdge.
    // מניפסט שנפסל בפענוח עדיין נספר ל-latest לפי שמו (ראו בדיקות הגילוי).
    test('compression שאינו zstd נפסל בפענוח, ומסומן כלא נתמך במודל', () {
      final json = jsonDecode(validJson) as Map<String, dynamic>;
      (json['patchFiles'] as List).first['compression'] = 'gzip';
      expect(
        () => DeltaManifest.fromJson(json),
        throwsA(isA<FormatException>().having(
            (e) => e.message,
            'message',
            LibraryUpdaterMessages.current
                .unsupportedPatchCompression('gzip'))),
      );
      const manifest = DeltaManifest(
        fromVersion: 1,
        toVersion: 2,
        fromSchemaVersion: 2,
        toSchemaVersion: 2,
        fromContentHash: 'a',
        toContentHash: 'b',
        patchFiles: [
          PatchFileEntry(
            file: 'p.db.zst',
            compression: 'gzip',
            sha256: 'x',
            size: 1,
            uncompressedSha256: 'y',
            uncompressedSize: 1,
          ),
        ],
      );
      expect(manifest.hasSupportedCompression, isFalse);
    });

    test('compression zstd נתמך', () {
      final manifest =
          DeltaManifest.fromJson(jsonDecode(validJson) as Map<String, dynamic>);
      expect(manifest.hasSupportedCompression, isTrue);
    });

    group('fullRebase', () {
      test('ברירת מחדל false, ונקרא כשהוא מוצהר', () {
        final json = jsonDecode(validJson) as Map<String, dynamic>;
        expect(DeltaManifest.fromJson(json).fullRebase, isFalse);
        json['fullRebase'] = true;
        expect(DeltaManifest.fromJson(json).fullRebase, isTrue);
      });

      test('ערך שאינו בוליאני הוא מניפסט פגום', () {
        final json = jsonDecode(validJson) as Map<String, dynamic>;
        json['fullRebase'] = 'yes';
        expect(() => DeltaManifest.fromJson(json), throwsFormatException);
      });
    });

    group('patchFormatVersion', () {
      test('נקרא כשהוא מוצהר', () {
        final json = jsonDecode(validJson) as Map<String, dynamic>;
        json['patchFormatVersion'] = 4;
        expect(DeltaManifest.fromJson(json).patchFormatVersion, 4);
      });

      // ⚠️ מניפסט שנפסל בפענוח נעלם מהגרף, ואיתו הגרסה שהוא מוביל אליה —
      // המחשב הלא-מקוון רואה "מעודכן" ונתקע. לכן היעדר השדה אינו כשל, גם
      // בסכמה שבה היצרן כותב אותו תמיד.
      test('היעדרו מותר רק בסכמות 1–3', () {
        final json = jsonDecode(validJson) as Map<String, dynamic>;
        json['fromSchemaVersion'] = 3;
        json['toSchemaVersion'] = 3;
        json.remove('patchFormatVersion');
        expect(DeltaManifest.fromJson(json).patchFormatVersion, isNull);
        json['fromSchemaVersion'] = 4;
        json['toSchemaVersion'] = 5;
        expect(() => DeltaManifest.fromJson(json), throwsFormatException);
      });

      test('ערך שאינו מספר הוא מניפסט פגום', () {
        final json = jsonDecode(validJson) as Map<String, dynamic>;
        json['patchFormatVersion'] = 'four';
        expect(() => DeltaManifest.fromJson(json), throwsFormatException);
      });
    });
  });
}
