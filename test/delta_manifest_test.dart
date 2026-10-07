import 'dart:convert';

import 'package:test/test.dart';
import 'package:seforim_library_updater/src/models/delta_manifest.dart';

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

    test('מפענח manifest תקין', () {
      final m =
          DeltaManifest.fromJson(jsonDecode(validJson) as Map<String, dynamic>);
      expect(m.fromVersion, 1);
      expect(m.toVersion, 2);
      expect(m.fromSchemaVersion, 1);
      expect(m.toSchemaVersion, 1);
      expect(m.patchFormatVersion, isNull);
      expect(m.fromContentHash, startsWith('35d49998'));
      expect(m.toContentHash, startsWith('2be5318d'));
      expect(m.patchFiles, hasLength(1));
      expect(m.patchFiles.first.file, 'patch-v1-v2.db.zst');
      expect(m.patchFiles.first.size, 1040075);
      expect(m.totalCompressedSize, 1040075);
    });

    test('מפענח patchFormatVersion אופציונלי ודוחה טיפוס לא תקין', () {
      final json = jsonDecode(validJson) as Map<String, dynamic>;
      json['patchFormatVersion'] = 4;
      expect(DeltaManifest.fromJson(json).patchFormatVersion, 4);

      json['patchFormatVersion'] = '4';
      expect(() => DeltaManifest.fromJson(json), throwsFormatException);
    });

    test('schema 4 ומעלה מחייב patchFormatVersion', () {
      final json = jsonDecode(validJson) as Map<String, dynamic>;
      json['toSchemaVersion'] = 4;
      expect(() => DeltaManifest.fromJson(json), throwsFormatException);

      json['patchFormatVersion'] = 4;
      expect(DeltaManifest.fromJson(json).patchFormatVersion, 4);
    });

    test('מפענח את שתי מפות ה-hash לפי טבלה', () {
      final json = jsonDecode(validJson) as Map<String, dynamic>;
      json['fromTableContentHashes'] = {'source': 'aa', 'book': 'bb'};
      json['toTableContentHashes'] = {'source': 'aa', 'book': 'cc'};
      final m = DeltaManifest.fromJson(json);
      expect(m.fromTableContentHashes, {'source': 'aa', 'book': 'bb'});
      expect(m.toTableContentHashes, {'source': 'aa', 'book': 'cc'});
    });

    test('מפות חסרות → null', () {
      final m =
          DeltaManifest.fromJson(jsonDecode(validJson) as Map<String, dynamic>);
      expect(m.fromTableContentHashes, isNull);
      expect(m.toTableContentHashes, isNull);
    });

    test('רק אחת מהמפות קיימת → שתיהן null', () {
      final json = jsonDecode(validJson) as Map<String, dynamic>;
      json['toTableContentHashes'] = {'source': 'aa'};
      final m = DeltaManifest.fromJson(json);
      expect(m.toTableContentHashes, isNull);
      expect(m.fromTableContentHashes, isNull);
    });

    test('מפה בטיפוס לא תקין → FormatException', () {
      final json = jsonDecode(validJson) as Map<String, dynamic>;
      json['fromTableContentHashes'] = ['source'];
      expect(() => DeltaManifest.fromJson(json), throwsFormatException);

      json['fromTableContentHashes'] = {'source': 1};
      expect(() => DeltaManifest.fromJson(json), throwsFormatException);

      json['fromTableContentHashes'] = {'source': ''};
      expect(() => DeltaManifest.fromJson(json), throwsFormatException);
    });

    test('optionalTableContentHashes: קיים, חסר ולא תקין', () {
      final json = jsonDecode(validJson) as Map<String, dynamic>;
      expect(DeltaManifest.fromJson(json).optionalTableContentHashes, isNull);

      json['optionalTableContentHashes'] = {
        'book_banner': 'aa',
        'book_protection': 'bb',
      };
      final m = DeltaManifest.fromJson(json);
      expect(m.optionalTableContentHashes,
          {'book_banner': 'aa', 'book_protection': 'bb'});
      // עומד לבדו — אינו תלוי בזוג מפות ה-hash של סכמת ה-DB.
      expect(m.toTableContentHashes, isNull);
      expect(m, isNot(DeltaManifest.fromJson(jsonDecode(validJson))));

      json['optionalTableContentHashes'] = ['book_banner'];
      expect(() => DeltaManifest.fromJson(json), throwsFormatException);
      json['optionalTableContentHashes'] = {'book_banner': 1};
      expect(() => DeltaManifest.fromJson(json), throwsFormatException);
    });

    test('fullRebase אופציונלי: ברירת מחדל false, דוחה טיפוס לא בוליאני', () {
      final json = jsonDecode(validJson) as Map<String, dynamic>;
      expect(DeltaManifest.fromJson(json).fullRebase, isFalse);

      json['fullRebase'] = true;
      expect(DeltaManifest.fromJson(json).fullRebase, isTrue);

      json['fullRebase'] = 'true';
      expect(() => DeltaManifest.fromJson(json), throwsFormatException);
      json['fullRebase'] = 1;
      expect(() => DeltaManifest.fromJson(json), throwsFormatException);
    });

    test('מניפסט מחסום של סכמה 6 מתפרש', () {
      final json = jsonDecode(validJson) as Map<String, dynamic>;
      json
        ..['fromVersion'] = 28
        ..['toVersion'] = 29
        ..['fromSchemaVersion'] = 5
        ..['toSchemaVersion'] = 6
        ..['patchFormatVersion'] = 999
        ..['fullRebase'] = true
        ..['fromContentHash'] = 'full-rebase'
        ..['toContentHash'] = 'full-rebase';
      final m = DeltaManifest.fromJson(json);
      expect(m.fullRebase, isTrue);
      expect(m.toSchemaVersion, 6);
      expect(m.patchFormatVersion, 999);
      expect(m,
          isNot(equals(DeltaManifest.fromJson(json..['fullRebase'] = false))));
    });

    test('סלחני לשדות לא מוכרים', () {
      final json = jsonDecode(validJson) as Map<String, dynamic>;
      json['someFutureField'] = {'a': 1};
      json['booksTouched'] = [10, 20, 30];
      final m = DeltaManifest.fromJson(json);
      expect(m.toVersion, 2);
      expect(m.booksTouched, [10, 20, 30]);
    });

    test('זורק כשחסר שדה חובה (fromContentHash)', () {
      final json = jsonDecode(validJson) as Map<String, dynamic>;
      json.remove('fromContentHash');
      expect(() => DeltaManifest.fromJson(json), throwsFormatException);
    });

    test('זורק כשחסר patchFiles', () {
      final json = jsonDecode(validJson) as Map<String, dynamic>;
      json.remove('patchFiles');
      expect(() => DeltaManifest.fromJson(json), throwsFormatException);
    });

    test('זורק כש-patchFiles ריק', () {
      final json = jsonDecode(validJson) as Map<String, dynamic>;
      json['patchFiles'] = [];
      expect(() => DeltaManifest.fromJson(json), throwsFormatException);
    });

    test('זורק על compression שאינו zstd', () {
      final json = jsonDecode(validJson) as Map<String, dynamic>;
      (json['patchFiles'] as List).first['compression'] = 'gzip';
      expect(() => DeltaManifest.fromJson(json), throwsFormatException);
    });
  });
}
