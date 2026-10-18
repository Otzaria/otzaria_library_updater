import 'package:seforim_library_updater/src/messages/library_updater_messages.dart';

/// מימוש לא-עברי של חלק מההודעות — מוכיח שההודעות עוברות דרך
/// [LibraryUpdaterMessages.current] ולא ליטרל.
class EnglishTestMessages extends HebrewLibraryUpdaterMessages {
  const EnglishTestMessages();

  @override
  String megabytes(String amount) => '$amount MB';
  @override
  String gigabytes(String amount) => '$amount GB';
  @override
  String mirrorManifestMissing(String fileName, String mirrorDir) =>
      '$fileName not found in $mirrorDir';
  @override
  String get localDbLocked =>
      'The library is locked, probably because Otzaria is open.';
  @override
  String localVersionMismatch(int? localVersion, int expected) =>
      'Local DB version $localVersion does not match the patch ($expected)';
}
