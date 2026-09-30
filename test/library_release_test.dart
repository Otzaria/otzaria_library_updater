import 'package:seforim_library_updater/seforim_library_updater.dart'
    show
        FullDbContainer,
        fullDbArchiveNameForSchema,
        fullDbManifestNameFor,
        kDefaultConsumerDbSchemaVersion,
        kSupportedDbSchemaVersion;
import 'package:seforim_library_updater/src/models/library_release.dart';
import 'package:test/test.dart';

ReleaseAsset _asset(String name) =>
    ReleaseAsset(name: name, downloadUrl: 'https://x/$name', size: 1);

LibraryRelease _releaseWith(List<String> names) => LibraryRelease(
      tag: 'v29',
      isPrerelease: false,
      isDraft: false,
      publishedAt: null,
      assets: names.map(_asset).toList(),
    );

void main() {
  group('שם ה-DB המלא לפי סכמה', () {
    test('seforim.db.zst שמור לסכמה 5 ומטה; מ-6 zdb עם הסכמה בשם', () {
      expect(fullDbArchiveNameForSchema(1), 'seforim.db.zst');
      expect(fullDbArchiveNameForSchema(5), 'seforim.db.zst');
      expect(fullDbArchiveNameForSchema(6), 'seforim-schema6.zdb');
      expect(fullDbArchiveNameForSchema(12), 'seforim-schema12.zdb');
      expect(fullDbManifestNameFor('seforim-schema6.zdb'),
          'seforim-schema6.zdb.manifest.json');
    });

    test('fullDbSchemaVersion, isFullDbArchive ו-container לשתי הצורות', () {
      expect(_asset('seforim.db.zst').isFullDbArchive, isTrue);
      expect(_asset('seforim.db.zst').fullDbSchemaVersion, isNull);
      expect(_asset('seforim.db.zst').fullDbContainer, FullDbContainer.zst);
      expect(_asset('seforim-schema6.zdb').isFullDbArchive, isTrue);
      expect(_asset('seforim-schema6.zdb').fullDbSchemaVersion, 6);
      expect(
          _asset('seforim-schema6.zdb').fullDbContainer, FullDbContainer.zdb);
      expect(_asset('seforim-schema7.zdb').fullDbSchemaVersion, 7);
      expect(_asset('patch-v1-v2.db.zst').fullDbContainer, isNull);
    });

    test('שמות לא קנוניים, סכמה < 6 או zst מסכמה 6 אינם DB מלא', () {
      for (final name in [
        'seforim-schema6.db.zst',
        'seforim-schema7.db.zst',
        'seforim-schema5.zdb',
        'seforim-schema0.zdb',
        'seforim-schema06.zdb',
        'seforim-schema6.zdb.manifest.json',
        'seforim-schema.zdb',
        'seforim.zdb',
        'seforim.db',
        'patch-v28-v29.db.zst',
      ]) {
        expect(_asset(name).isFullDbArchive, isFalse, reason: name);
        expect(_asset(name).fullDbSchemaVersion, isNull, reason: name);
        expect(_asset(name).fullDbContainer, isNull, reason: name);
      }
    });

    test('fullDbManifestAsset מאתר את ה-manifest הצמוד בלבד', () {
      final release = _releaseWith([
        'seforim-schema6.zdb',
        'seforim-schema6.zdb.manifest.json',
        'seforim-schema7.zdb',
      ]);
      expect(release.fullDbManifestAsset(_asset('seforim-schema6.zdb'))?.name,
          'seforim-schema6.zdb.manifest.json');
      expect(
          release.fullDbManifestAsset(_asset('seforim-schema7.zdb')), isNull);
      expect(release.deltaManifestAssets, isEmpty);
    });

    test('fullDbAssetFor בוחר את הסכמה הגבוהה ביותר שנתמכת', () {
      final release = _releaseWith([
        'seforim-schema7.zdb',
        'seforim.db.zst',
        'seforim-schema6.zdb',
      ]);
      expect(
          release.fullDbAssetFor(maxSchemaVersion: 5)?.name, 'seforim.db.zst');
      expect(release.fullDbAssetFor(maxSchemaVersion: 6)?.name,
          'seforim-schema6.zdb');
      expect(release.fullDbAssetFor(maxSchemaVersion: 9)?.name,
          'seforim-schema7.zdb');
      expect(release.fullDbAssetFor(maxSchemaVersion: 4), isNull);
    });

    test('release עם DB מלא בסכמה לא נתמכת בלבד — אין asset', () {
      final release = _releaseWith(['seforim-schema6.zdb']);
      expect(release.fullDbAssetFor(maxSchemaVersion: 5), isNull);
    });

    test('fullDbAsset נשאר בסכמת ברירת המחדל של הצרכן (5)', () {
      expect(kDefaultConsumerDbSchemaVersion, 5);
      expect(
          _releaseWith(['seforim.db.zst']).fullDbAsset?.name, 'seforim.db.zst');
      expect(
          _releaseWith(['seforim.db.zst', 'seforim-schema6.zdb'])
              .fullDbAsset
              ?.name,
          'seforim.db.zst');
      expect(_releaseWith(['seforim-schema6.zdb']).fullDbAsset, isNull);
      expect(
          _releaseWith(['seforim.db.zst', 'seforim-schema6.zdb'])
              .fullDbAssetFor(maxSchemaVersion: kSupportedDbSchemaVersion)
              ?.name,
          'seforim-schema6.zdb');
    });
  });

  group('ReleaseAsset.fromJson', () {
    test('מפרסר id/updated_at/digest כשקיימים', () {
      final asset = ReleaseAsset.fromJson({
        'name': 'seforim.db.zst',
        'browser_download_url': 'https://x/seforim.db.zst',
        'size': 1197000000,
        'id': 123456,
        'updated_at': '2026-07-19T10:00:00Z',
        'digest': 'sha256:abc123',
      });
      expect(asset.name, 'seforim.db.zst');
      expect(asset.downloadUrl, 'https://x/seforim.db.zst');
      expect(asset.size, 1197000000);
      expect(asset.id, 123456);
      expect(asset.updatedAt, '2026-07-19T10:00:00Z');
      expect(asset.digest, 'sha256:abc123');
    });

    test('סובל היעדר של id/updated_at/digest (null)', () {
      final asset = ReleaseAsset.fromJson({
        'name': 'seforim.db.zst',
        'browser_download_url': 'https://x/seforim.db.zst',
        'size': 100,
      });
      expect(asset.id, isNull);
      expect(asset.updatedAt, isNull);
      expect(asset.digest, isNull);
    });

    test('השדות החדשים נכללים ב-props (שוויון)', () {
      const a = ReleaseAsset(
        name: 'a',
        downloadUrl: 'u',
        size: 1,
        id: 1,
        updatedAt: 't',
        digest: 'sha256:x',
      );
      const b = ReleaseAsset(
        name: 'a',
        downloadUrl: 'u',
        size: 1,
        id: 2,
        updatedAt: 't',
        digest: 'sha256:x',
      );
      expect(a, isNot(equals(b)));
    });
  });
}
