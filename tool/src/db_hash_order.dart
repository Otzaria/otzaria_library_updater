import 'package:seforim_library_updater/seforim_library_updater.dart'
    show LocalDbVersionReader, hashTableOrderForSchemaVersion;

/// סדר ה-hash לפי `schema_meta.db_schema_version` של ה-DB שב-[dbPath].
/// ברירת המחדל של הספרייה היא הסכמה הנוכחית, ועל DB ישן היא נותנת hash שגוי.
List<String> hashTableOrderForDbFile(String dbPath) {
  final schema = const LocalDbVersionReader().read(dbPath).schemaVersion;
  if (schema == null) {
    throw StateError('חסר schema_meta.db_schema_version ב-$dbPath');
  }
  return hashTableOrderForSchemaVersion(schema);
}
