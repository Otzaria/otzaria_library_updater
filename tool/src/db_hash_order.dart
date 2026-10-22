import 'package:seforim_library_updater/seforim_library_updater.dart'
    show
        LocalDbVersionReader,
        hashRowOrderForSchemaVersion,
        hashTableOrderForSchemaVersion;

/// סדר ה-hash לפי `schema_meta.db_schema_version` של ה-DB שב-[dbPath].
/// ברירת המחדל של הספרייה היא הסכמה הנוכחית, ועל DB ישן היא נותנת hash שגוי.
List<String> hashTableOrderForDbFile(String dbPath) =>
    hashTableOrderForSchemaVersion(_schemaOf(dbPath));

/// סדר השורות ב-hash לפי סכמת ה-DB שב-[dbPath], לצד [hashTableOrderForDbFile].
Map<String, List<String>>? hashRowOrderForDbFile(String dbPath) =>
    hashRowOrderForSchemaVersion(_schemaOf(dbPath));

int _schemaOf(String dbPath) {
  final schema = const LocalDbVersionReader().read(dbPath).schemaVersion;
  if (schema == null) {
    throw StateError('חסר schema_meta.db_schema_version ב-$dbPath');
  }
  return schema;
}
