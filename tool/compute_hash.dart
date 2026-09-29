import 'dart:io';

import 'package:seforim_library_updater/src/services/logical_content_hasher.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'src/db_hash_order.dart';

/// כלי עזר: מחשב את ה-logical content hash של DB נתון ומדפיס אותו.
void main(List<String> args) {
  final order = hashTableOrderForDbFile(args.single);
  final db = sqlite3.sqlite3.open(args.single, mode: sqlite3.OpenMode.readOnly);
  try {
    final sw = Stopwatch()..start();
    final hash = const LogicalContentHasher().compute(db, tableOrder: order);
    stdout.writeln('$hash  ${args.single}  (${sw.elapsed})');
  } finally {
    db.close();
  }
}
