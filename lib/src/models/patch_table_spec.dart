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
  PatchTableSpec('book_base_text', ['bookId', 'baseBookId'], updatable: false),
  PatchTableSpec('book_topic', ['bookId', 'topicId'], updatable: false),
  PatchTableSpec('book_pub_place', ['bookId', 'pubPlaceId'], updatable: false),
  PatchTableSpec('book_pub_date', ['bookId', 'pubDateId'], updatable: false),
  PatchTableSpec('book_acronym', ['bookId', 'term'], updatable: false),
  PatchTableSpec('book_generation', ['bookId', 'generationId'],
      updatable: false),
  PatchTableSpec('tocEntry', ['id'], updatable: true),
  PatchTableSpec('line', ['id'], updatable: true),
  // סכמה 6. תוכן השורה בטבלה נפרדת, שורה אחת לכל שורת line עם אותו id.
  PatchTableSpec('line_content', ['id'], updatable: true),
  // סכמה 6. מילון ה-zstd של טקסט השורות; החלפתו היא תמיד הורדה מלאה.
  PatchTableSpec('zstd_dict', ['id'], updatable: true),
  PatchTableSpec('line_toc', ['lineId'], updatable: true),
  // סכמה 4. טבלת מפתח טהורה — כל עמודותיה PK, אין מה לעדכן בהתנגשות.
  PatchTableSpec('line_ref', ['bookId', 'refKeyHash', 'lineIndex'],
      updatable: false),
  // סכמה 5. אינדקס דיבורי-המתחיל — dhDisplay (הצורה המודפסת) נלווית למפתח.
  PatchTableSpec('line_dh', ['bookId', 'dhText', 'lineIndex'], updatable: true),
  PatchTableSpec('link', ['id'], updatable: true),
  PatchTableSpec('link_anchor', ['linkId', 'side', 'charStart'],
      updatable: true),
  PatchTableSpec('link_range', ['linkId', 'side'], updatable: true),
  PatchTableSpec('link_coverage', ['lineId', 'linkId', 'side'],
      updatable: false),
  // reasonMask עשוי להשתנות כאשר המפתח נשאר זהה.
  PatchTableSpec('link_suppressed_side', ['linkId', 'side'], updatable: true),
  PatchTableSpec('book_has_links', ['bookId'], updatable: true),
  PatchTableSpec('book_version', ['id'], updatable: true),
  PatchTableSpec('version_line', ['versionId', 'lineId'], updatable: true),
  PatchTableSpec('alt_toc_structure', ['id'], updatable: true),
  PatchTableSpec('alt_toc_entry', ['id'], updatable: true),
  PatchTableSpec('line_alt_toc', ['lineId', 'structureId'], updatable: true),
  PatchTableSpec('default_commentator', ['bookId', 'commentatorBookId'],
      updatable: true),
  PatchTableSpec('default_targum', ['bookId', 'targumBookId'], updatable: true),
  PatchTableSpec('schema_meta', ['key'], updatable: true),
];

/// סדר ה-hash הקפוא של סכמה-2 (34 טבלאות, ללא `link_suppressed_side`) —
/// משחזר בדיוק את ה-hash של ארטיפקטי סכמה-2. לעולם אין לערוך.
const List<String> kHashTableOrderSchema2 = [
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
  'book_base_text',
  'book_pub_place',
  'book_pub_date',
  'book_generation',
  'tocEntry',
  'line',
  'line_toc',
  'link',
  'link_anchor',
  'link_range',
  'link_coverage',
  'book_has_links',
  'book_version',
  'version_line',
  'book_acronym',
  'alt_toc_structure',
  'alt_toc_entry',
  'line_alt_toc',
  'default_commentator',
  'default_targum',
  'schema_meta',
];

/// גרסת סכמת ה-DB הלוגית הגבוהה ביותר שה-hasher וה-planner מכירים.
const int kSupportedDbSchemaVersion = 6;

/// הסכמה שצרכן מקבל כשאינו מצהיר אחרת. קורא `line_content` (סכמה 6) מצהיר
/// במפורש, כך ש-build של אפליקציה ישנה מול `ref: main` צף לא יוריד DB שאינו קורא.
const int kDefaultConsumerDbSchemaVersion = 5;

/// גרסת פורמט `patch.db` הגבוהה ביותר שה-applier יודע להחיל.
///
/// זהו חוזה נפרד מסכמת ה-DB: producer חדש יכול לכתוב format 4 גם עבור
/// מעבר DB לוגי 2→3. כאשר `patchFormatVersion` קיים במניפסט, ה-planner
/// מסנן גם לפיו; במניפסטים היסטוריים האימות נשאר ב-preflight של ה-applier.
const int kSupportedPatchFormatVersion = 4;

/// סדר ה-hash הקפוא של סכמה-3 (35 טבלאות, ללא טבלאות סכמה-4: `line_ref`
/// ו-`line_dh`) — משחזר בדיוק את ה-hash של ארטיפקטי סכמה-3. לעולם אין לערוך.
/// `link_suppressed_side` יושבת מיד אחרי `link_coverage` — אותו מיקום בדיוק
/// כמו בצד הקוטליני.
const List<String> kHashTableOrderSchema3 = [
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
  'book_base_text',
  'book_pub_place',
  'book_pub_date',
  'book_generation',
  'tocEntry',
  'line',
  'line_toc',
  'link',
  'link_anchor',
  'link_range',
  'link_coverage',
  'link_suppressed_side',
  'book_has_links',
  'book_version',
  'version_line',
  'book_acronym',
  'alt_toc_structure',
  'alt_toc_entry',
  'line_alt_toc',
  'default_commentator',
  'default_targum',
  'schema_meta',
];

/// סדר ה-hash הקפוא של סכמה 4. סכמה 5 משנה עמודה ב-`line_dh`, לא את סדר
/// הטבלאות — ראו [kHashTableOrderSchema5]. לעולם אין לערוך.
const List<String> kHashTableOrderSchema4 = [
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
  'book_base_text',
  'book_pub_place',
  'book_pub_date',
  'book_generation',
  'tocEntry',
  'line',
  'line_toc',
  'line_ref',
  'line_dh',
  'link',
  'link_anchor',
  'link_range',
  'link_coverage',
  'link_suppressed_side',
  'book_has_links',
  'book_version',
  'version_line',
  'book_acronym',
  'alt_toc_structure',
  'alt_toc_entry',
  'line_alt_toc',
  'default_commentator',
  'default_targum',
  'schema_meta',
];

/// סדר ה-hash הקפוא של סכמה 5 — זהה לסכמה 4 (השינוי בעמודה, לא בטבלאות).
const List<String> kHashTableOrderSchema5 = kHashTableOrderSchema4;

/// סדר ה-hash הקפוא של סכמה 6 (39 טבלאות): `line_content` מיד אחרי `line`,
/// ו-`zstd_dict` (מילון המסגרות של טקסט השורות) מיד אחריה. `zstd_dict` נוספה
/// לפני שסכמה 6 שוחררה; מעכשיו לעולם אין לערוך.
const List<String> kHashTableOrderSchema6 = [
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
  'book_base_text',
  'book_pub_place',
  'book_pub_date',
  'book_generation',
  'tocEntry',
  'line',
  'line_content',
  'zstd_dict',
  'line_toc',
  'line_ref',
  'line_dh',
  'link',
  'link_anchor',
  'link_range',
  'link_coverage',
  'link_suppressed_side',
  'book_has_links',
  'book_version',
  'version_line',
  'book_acronym',
  'alt_toc_structure',
  'alt_toc_entry',
  'line_alt_toc',
  'default_commentator',
  'default_targum',
  'schema_meta',
];

/// סדר ה-hash הנוכחי (סכמה 6).
const List<String> kHashTableOrder = kHashTableOrderSchema6;

/// סדר ה-hash הקפוא של סכמה-1 (33 טבלאות, ללא `book_base_text`) — משחזר בדיוק
/// את ה-hash של ארטיפקטי סכמה-1 ההיסטוריים. לעולם אין לערוך.
const List<String> kHashTableOrderSchema1 = [
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
  'link_anchor',
  'link_range',
  'link_coverage',
  'book_has_links',
  'book_version',
  'version_line',
  'book_acronym',
  'alt_toc_structure',
  'alt_toc_entry',
  'line_alt_toc',
  'default_commentator',
  'default_targum',
  'schema_meta',
];

/// מפרט טבלה אופציונלית: אינה בחוזה ה-hash של הסכמה ואינה ב-upserts/deletes.
/// ה-patch נושא עבורה snapshot מלא (`optional_<name>`) שמחליף את כל תוכנה.
class OptionalPatchTableSpec {
  final String name;
  final List<String> primaryKey;

  /// העמודות בסדר ה-DDL — אלה שמועתקות מה-snapshot.
  final List<String> columns;

  const OptionalPatchTableSpec(this.name, this.primaryKey, this.columns);
}

/// הטבלאות האופציונליות שה-applier מכיר, משוכפל מ-SeforimLibrary.
/// TODO: בסכמה 7 להעביר אותן לחוזה הסכמה ולבטל את ערוץ הצד.
const List<OptionalPatchTableSpec> kOptionalPatchTables = [
  OptionalPatchTableSpec('book_banner', ['bookId'], ['bookId', 'text']),
  OptionalPatchTableSpec('book_protection', ['bookId'], ['bookId', 'level']),
];
