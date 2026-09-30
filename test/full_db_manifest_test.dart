import 'dart:convert';

import 'package:seforim_library_updater/seforim_library_updater.dart'
    show FullDbManifest, kSupportedFullDbManifestVersion;
import 'package:test/test.dart';

Map<String, dynamic> _valid() => {
      'manifestVersion': 1,
      'file': 'seforim-schema6.zdb',
      'size': 1073741824,
      'sha256': 'AB' * 32,
      'zdb': {
        'formatMajor': 1,
        'formatMinor': 2,
        'fileUuid': '0123456789ABCDEF0123456789abcdef',
        'contentXxh64': 'fedcba9876543210',
        'logicalSize': 4294967296,
        'pageSize': 4096,
        'dictName': 'seforim-v1',
        'dictId': 305419896,
        'level': -3,
      },
      'dbVersion': 29,
      'dbSchemaVersion': 6,
      'contentHash': 'c0ffee',
      'converter': {
        'repository': 'Otzaria/otzaria_zvfs',
        'commit': '1a2b3c4d',
      },
    };

/// עותק עמוק שנערך ב-[edit] — כדי שכל מקרה יתחיל ממניפסט תקין.
Map<String, dynamic> _edited(void Function(Map<String, dynamic> m) edit) {
  final m = jsonDecode(jsonEncode(_valid())) as Map<String, dynamic>;
  edit(m);
  return m;
}

void main() {
  test('מניפסט תקין מפוענח במלואו, hex מנורמל לאותיות קטנות', () {
    final m = FullDbManifest.fromJson(_valid());
    expect(m.manifestVersion, kSupportedFullDbManifestVersion);
    expect(m.file, 'seforim-schema6.zdb');
    expect(m.size, 1073741824);
    expect(m.sha256, 'ab' * 32);
    expect(m.zdb.formatMajor, 1);
    expect(m.zdb.formatMinor, 2);
    expect(m.zdb.fileUuid, '0123456789abcdef0123456789abcdef');
    expect(m.zdb.contentXxh64, 'fedcba9876543210');
    expect(m.zdb.logicalSize, 4294967296);
    expect(m.zdb.pageSize, 4096);
    expect(m.zdb.dictName, 'seforim-v1');
    expect(m.zdb.dictId, 305419896);
    expect(m.zdb.level, -3);
    expect(m.dbVersion, 29);
    expect(m.dbSchemaVersion, 6);
    expect(m.contentHash, 'c0ffee');
    expect(m.converter.repository, 'Otzaria/otzaria_zvfs');
    expect(m.converter.commit, '1a2b3c4d');
    expect(FullDbManifest.fromJson(_valid()), m);
  });

  test('שדות לא מוכרים אינם מכשילים', () {
    final m = FullDbManifest.fromJson(_edited((m) {
      m['future'] = true;
      (m['zdb'] as Map)['future'] = 1;
    }));
    expect(m.file, 'seforim-schema6.zdb');
  });

  for (final version in [0, 2, '1', null]) {
    test('manifestVersion=$version נדחה', () {
      expect(
        () => FullDbManifest.fromJson(
            _edited((m) => m['manifestVersion'] = version)),
        throwsFormatException,
      );
    });
  }

  for (final key in [
    'file',
    'size',
    'sha256',
    'zdb',
    'dbVersion',
    'dbSchemaVersion',
    'contentHash',
    'converter',
  ]) {
    test('שדה חסר: $key', () {
      expect(
        () => FullDbManifest.fromJson(_edited((m) => m.remove(key))),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains(key))),
      );
    });
  }

  for (final key in [
    'formatMajor',
    'formatMinor',
    'fileUuid',
    'contentXxh64',
    'logicalSize',
    'pageSize',
    'dictName',
    'dictId',
    'level',
  ]) {
    test('שדה חסר: zdb.$key', () {
      expect(
        () => FullDbManifest.fromJson(
            _edited((m) => (m['zdb'] as Map).remove(key))),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('zdb.$key'))),
      );
    });
  }

  for (final key in ['repository', 'commit']) {
    test('שדה חסר: converter.$key', () {
      expect(
        () => FullDbManifest.fromJson(
            _edited((m) => (m['converter'] as Map).remove(key))),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('converter.$key'))),
      );
    });
  }

  final invalid = <String, void Function(Map<String, dynamic>)>{
    'sha256 קצר': (m) => m['sha256'] = 'ab',
    'sha256 לא hex': (m) => m['sha256'] = 'zz' * 32,
    'fileUuid באורך 31': (m) => (m['zdb'] as Map)['fileUuid'] = '0' * 31,
    'contentXxh64 באורך 17': (m) =>
        (m['zdb'] as Map)['contentXxh64'] = '0' * 17,
    'size כמחרוזת': (m) => m['size'] = '100',
    'size אפס': (m) => m['size'] = 0,
    'dbVersion שבור': (m) => m['dbVersion'] = 29.5,
    'logicalSize אפס': (m) => (m['zdb'] as Map)['logicalSize'] = 0,
    'dictId שלילי': (m) => (m['zdb'] as Map)['dictId'] = -1,
    'zdb כרשימה': (m) => m['zdb'] = [],
    'file ריק': (m) => m['file'] = '',
  };
  invalid.forEach((name, edit) {
    test('ערך לא תקין: $name', () {
      expect(
          () => FullDbManifest.fromJson(_edited(edit)), throwsFormatException);
    });
  });
}
