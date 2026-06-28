/// מפרט טבלה אחת במנגנון ה-patch: שמה, עמודות המפתח הראשי, והאם היא ניתנת
/// לעדכון (יש לה עמודות שאינן PK) או שהיא טבלת junction טהורה.
///
/// משוכפל מ-`PatchTables.kt` (PATCH_TABLES_IN_FK_ORDER) ב-SeforimLibrary.
class PatchTableSpec {
  final String name;
  final List<String> primaryKey;

  /// `true` כאשר לטבלה יש עמודות שאינן PK (upsert עם `DO UPDATE`).
  /// `false` לטבלת junction טהורה שכל עמודותיה הן PK (upsert עם `DO NOTHING`).
  final bool updatable;

  const PatchTableSpec(this.name, this.primaryKey, {required this.updatable});
}

/// סדר הטבלאות להחלת patch — לפי תלויות מפתח זר (FK).
/// upserts מורצים בסדר זה; deletes בסדר ההפוך.
///
/// משוכפל אות-באות מ-`PATCH_TABLES_IN_FK_ORDER` ב-SeforimLibrary.
/// שים לב: הסדר כאן שונה מסדר ה-hash ב-[kHashTableOrder].
const List<PatchTableSpec> kPatchTablesInFkOrder = [
  PatchTableSpec('source', ['id'], updatable: true),
  PatchTableSpec('author', ['id'], updatable: true),
  PatchTableSpec('topic', ['id'], updatable: true),
  PatchTableSpec('pub_place', ['id'], updatable: true),
  PatchTableSpec('pub_date', ['id'], updatable: true),
  PatchTableSpec('connection_type', ['id'], updatable: true),
  PatchTableSpec('tocText', ['id'], updatable: true),
  PatchTableSpec('generation', ['id'], updatable: true),
  PatchTableSpec('category', ['id'], updatable: true),
  PatchTableSpec('category_closure', ['ancestorId', 'descendantId'],
      updatable: false),
  PatchTableSpec('book', ['id'], updatable: true),
  PatchTableSpec('book_author', ['bookId', 'authorId'], updatable: false),
  PatchTableSpec('book_topic', ['bookId', 'topicId'], updatable: false),
  PatchTableSpec('book_pub_place', ['bookId', 'pubPlaceId'], updatable: false),
  PatchTableSpec('book_pub_date', ['bookId', 'pubDateId'], updatable: false),
  PatchTableSpec('book_acronym', ['bookId', 'term'], updatable: false),
  PatchTableSpec('book_generation', ['bookId', 'generationId'],
      updatable: false),
  PatchTableSpec('tocEntry', ['id'], updatable: true),
  PatchTableSpec('line', ['id'], updatable: true),
  PatchTableSpec('line_toc', ['lineId'], updatable: true),
  PatchTableSpec('link', ['id'], updatable: true),
  PatchTableSpec('book_has_links', ['bookId'], updatable: true),
  PatchTableSpec('alt_toc_structure', ['id'], updatable: true),
  PatchTableSpec('alt_toc_entry', ['id'], updatable: true),
  PatchTableSpec('line_alt_toc', ['lineId', 'structureId'], updatable: true),
  PatchTableSpec('default_commentator', ['bookId', 'commentatorBookId'],
      updatable: true),
  PatchTableSpec('default_targum', ['bookId', 'targumBookId'], updatable: true),
  PatchTableSpec('schema_meta', ['key'], updatable: true),
];

/// סדר הטבלאות לחישוב logical content hash.
///
/// משוכפל אות-באות מ-`DEFAULT_TABLES` ב-`LogicalContentHasher.kt`.
/// הסדר כאן שונה מ-[kPatchTablesInFkOrder] — אסור להחליף ביניהם.
const List<String> kHashTableOrder = [
  'source',
  'author',
  'topic',
  'pub_place',
  'pub_date',
  'connection_type',
  'generation',
  'category',
  'category_closure',
  'tocText',
  'book',
  'book_topic',
  'book_author',
  'book_pub_place',
  'book_pub_date',
  'book_generation',
  'tocEntry',
  'line',
  'line_toc',
  'link',
  'book_has_links',
  'book_acronym',
  'alt_toc_structure',
  'alt_toc_entry',
  'line_alt_toc',
  'default_commentator',
  'default_targum',
  'schema_meta',
];
