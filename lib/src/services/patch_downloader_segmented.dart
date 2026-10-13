part of 'patch_downloader.dart';

/// השרת אינו מכבד טווחים באופן אמין — ההורדה ממשיכה בחיבור אחד.
class _SegmentFallback implements Exception {
  const _SegmentFallback();
}

/// הנכס בשרת התחלף (ETag אחר) — כל הטווחים מתחילים מאפס.
class _SegmentRestart implements Exception {
  const _SegmentRestart();
}

/// טווחי ההורדה של קובץ אחד, כפי שנשמרים ב-`<dest>.segments`. טווח i הוא
/// `[bounds[i], bounds[i+1])`; טווח 0 נכתב ישר ל-dest והשאר ל-`<dest>.seg-i`.
class _SegmentPlan {
  _SegmentPlan(this.bounds, {this.etag, this.assembled = 1});

  final List<int> bounds;
  String? etag;

  /// כמה טווחים כבר בתוך dest (טווח 0 תמיד).
  int assembled;

  int get count => bounds.length - 1;
  int length(int i) => bounds[i + 1] - bounds[i];
}

typedef _OpenedSegment = ({http.StreamedResponse response, int length});

String _segmentPath(String destPath, int index) =>
    index == 0 ? destPath : '$destPath.seg-$index';

String _segmentStatePath(String destPath) => '$destPath.segments';

/// כתיבה דרך קובץ זמני: קובץ מצב קטוע היה נקרא כתוכנית אחרת.
void _writeSegmentStateFile(String statePath, Map<String, Object?> state) {
  final temp = File('$statePath.tmp');
  temp.writeAsStringSync(jsonEncode(state), flush: true);
  temp.renameSync(statePath);
}

/// מוחק את קובץ המצב ואת קובצי הטווחים (לא את dest עצמו).
void _deleteSegmentLeftovers(String destPath) {
  final statePath = _segmentStatePath(destPath);
  if (!File(statePath).existsSync() &&
      !File(_segmentPath(destPath, 1)).existsSync()) {
    return;
  }
  final dir = Directory(p.dirname(destPath));
  final pattern = RegExp('^${RegExp.escape(p.basename(destPath))}'
      r'\.(segments(\.tmp)?|seg-\d+)$');
  try {
    for (final entity in dir.listSync()) {
      if (entity is File && pattern.hasMatch(p.basename(entity.path))) {
        _deleteFileQuietly(entity.path);
      }
    }
  } catch (_) {}
}

extension _SegmentedDownload on PatchDownloader {
  bool _segmentationApplies(int? expectedSize) =>
      maxConnections > 1 &&
      expectedSize != null &&
      expectedSize >= segmentThresholdBytes;

  bool _hasSegmentState(String destPath, String resumeToken) {
    try {
      final state = File(_segmentStatePath(destPath));
      if (!state.existsSync()) return false;
      final json = jsonDecode(state.readAsStringSync());
      return json is Map && json['token'] == resumeToken;
    } catch (_) {
      return false;
    }
  }

  /// התוכנית השמורה, רק כשהיא כבולה לאותו נכס ([resumeToken], כתובת, גודל,
  /// sha256) והקבצים על הדיסק עקביים איתה.
  _SegmentPlan? _readSegmentPlan(String destPath, String? resumeToken,
      String url, int size, String? sha256) {
    if (resumeToken == null) return null;
    try {
      final stateFile = File(_segmentStatePath(destPath));
      if (!stateFile.existsSync()) return null;
      final json = jsonDecode(stateFile.readAsStringSync());
      if (json is! Map ||
          json['v'] != 1 ||
          json['token'] != resumeToken ||
          json['url'] != url ||
          json['size'] != size ||
          json['sha256'] != sha256) {
        return null;
      }
      final bounds = (json['bounds'] as List).cast<int>().toList();
      final assembled = json['assembled'] as int;
      final etag = json['etag'] as String?;
      if (bounds.length < 3 || bounds.first != 0 || bounds.last != size) {
        return null;
      }
      for (var i = 1; i < bounds.length; i++) {
        if (bounds[i] <= bounds[i - 1]) return null;
      }
      final plan = _SegmentPlan(bounds, etag: etag, assembled: assembled);
      if (assembled < 1 || assembled > plan.count) return null;
      if (etag == null && sha256 == null) return null;
      final dest = File(destPath);
      final destLength = dest.existsSync() ? dest.lengthSync() : 0;
      if (assembled == 1
          ? destLength > bounds[1]
          : destLength < bounds[assembled]) {
        return null;
      }
      for (var i = assembled; i < plan.count; i++) {
        final segment = File(_segmentPath(destPath, i));
        if (segment.existsSync() && segment.lengthSync() > plan.length(i)) {
          return null;
        }
      }
      return plan;
    } catch (_) {
      return null;
    }
  }

  void _writeSegmentState(String destPath, String? resumeToken, String url,
      int size, String? sha256, _SegmentPlan plan) {
    if (resumeToken == null) return;
    final statePath = _segmentStatePath(destPath);
    try {
      _writeSegmentStateFile(
        statePath,
        _segmentStateJson(resumeToken, url, size, sha256, plan),
      );
    } catch (error) {
      throw PatchDownloadException(LibraryUpdaterMessages.current
          .writeResumeSidecarFailed(statePath, '$error'));
    }
  }

  Map<String, Object?> _segmentStateJson(String resumeToken, String url,
          int size, String? sha256, _SegmentPlan plan) =>
      {
        'v': 1,
        'token': resumeToken,
        'url': url,
        'size': size,
        'sha256': sha256,
        'etag': plan.etag,
        'bounds': plan.bounds,
        'assembled': plan.assembled,
      };

  /// [have] בתים כבר ב-dest; היתרה מתחלקת שווה. null כשהיתרה קטנה מהסף.
  _SegmentPlan? _planSegments(int have, int size, String? validator) {
    final remaining = size - have;
    if (remaining < segmentThresholdBytes || remaining < 2) return null;
    final count = maxConnections < remaining ? maxConnections : remaining;
    final per = remaining ~/ count;
    return _SegmentPlan(
      [0, for (var k = 1; k < count; k++) have + per * k, size],
      etag: validator,
    );
  }

  /// הורדה בכמה חיבורים של קובץ שגודלו [size]. השרת נבדק בבקשה הראשונה:
  /// רק 206 עם הטווח וה-total הצפויים פותח את שאר החיבורים, ו-200 ננטש לפני
  /// הגוף וחוזר לחיבור אחד (`done: false`; dest נשאר תחילית עם [validator]).
  ///
  /// טווח 0 נכתב ישר ל-dest והשאר לקבצים נפרדים שמצורפים אליו לפי הסדר,
  /// וכל אחד נמחק מיד אחרי צירופו. בלי הקצאה מראש: ב-FAT32 הגדלת קובץ כותבת
  /// אפסים לכל אורכו, ואורך קובץ מוקצה אינו מעיד מה באמת נכתב בו אחרי קריסה.
  Future<({bool done, String? validator})> _downloadSegmented({
    required String url,
    required String destPath,
    required int size,
    String? sha256,
    String? resumeToken,
    _SegmentPlan? resumed,
    String? validator,
    void Function(int downloaded, int? total)? onProgress,
    void Function(int verified, int total)? onVerifyProgress,
    void Function(int bytes)? onExistingBytes,
    bool Function()? isCancelled,
  }) async {
    final file = File(destPath);
    final sidecarPath = PatchDownloader.resumeSidecarPath(destPath);
    var plan = resumed;
    var restarts = 0;
    var cleanRetryUsed = false;

    void discardAll() {
      _deleteRequired(
        destPath,
        LibraryUpdaterMessages.current.deletePartialBeforeRetryFailed,
      );
      _deleteSegmentLeftovers(destPath);
      plan = null;
      validator = null;
      onExistingBytes?.call(0);
    }

    while (true) {
      final current = plan ??
          _planSegments(
              file.existsSync() ? file.lengthSync() : 0, size, validator);
      if (current == null) return (done: false, validator: validator);
      plan = current;
      // תחילית שירדה בלי ETag אינה כבולה ל-ETag שהבדיקה תביא עכשיו.
      final unboundPrefix =
          current.etag == null && file.existsSync() && file.lengthSync() > 0;

      final outcome = await _fetchSegments(
        url: url,
        destPath: destPath,
        size: size,
        sha256: sha256,
        resumeToken: resumeToken,
        plan: current,
        onProgress: onProgress,
        onExistingBytes: onExistingBytes,
        isCancelled: isCancelled,
      );
      if (outcome is _SegmentFallback) {
        _deleteSegmentLeftovers(destPath);
        // בלי ETag אין If-Range שיכבול את התחילית לגרסת השרת.
        if (current.etag == null || unboundPrefix) {
          _deleteRequired(
            destPath,
            LibraryUpdaterMessages.current.deletePartialWithoutValidatorFailed,
          );
        }
        return (done: false, validator: unboundPrefix ? null : current.etag);
      }
      if (outcome is _SegmentRestart) {
        discardAll();
        if (++restarts > 2) return (done: false, validator: null);
        continue;
      }

      final digest = await _assembleSegmentsInIsolate(
        destPath: destPath,
        bounds: current.bounds,
        assembled: current.assembled,
        statePath: resumeToken == null ? null : _segmentStatePath(destPath),
        state: resumeToken == null
            ? const {}
            : _segmentStateJson(resumeToken, url, size, sha256, current),
        hash: sha256 != null,
        isCancelled: isCancelled,
        onProgress: onVerifyProgress,
      );
      if (sha256 == null || digest == sha256) {
        _deleteSegmentLeftovers(destPath);
        if (resumeToken != null && sha256 != null) {
          await _markVerified(sidecarPath, resumeToken, sha256, file);
        }
        return (done: true, validator: current.etag);
      }
      if (cleanRetryUsed) {
        _deleteQuietly(destPath);
        _deleteSegmentLeftovers(destPath);
        _deleteQuietly(sidecarPath);
        throw PatchDownloadException(
            LibraryUpdaterMessages.current.fullDbHashMismatch);
      }
      cleanRetryUsed = true;
      discardAll();
    }
  }

  /// מוריד את כל הטווחים החסרים של [plan]. מחזיר null כשכולם שלמים, או
  /// [_SegmentFallback]/[_SegmentRestart]; כל כשל אחר נזרק והבתים נשמרים.
  Future<Exception?> _fetchSegments({
    required String url,
    required String destPath,
    required int size,
    required String? sha256,
    required String? resumeToken,
    required _SegmentPlan plan,
    void Function(int downloaded, int? total)? onProgress,
    void Function(int bytes)? onExistingBytes,
    bool Function()? isCancelled,
  }) async {
    final present = <int>[
      for (var i = 0; i < plan.count; i++)
        if (plan.assembled > 1 && i < plan.assembled)
          plan.length(i)
        else
          File(_segmentPath(destPath, i)).existsSync()
              ? File(_segmentPath(destPath, i)).lengthSync()
              : 0,
    ];
    int presentTotal() => present.fold(0, (sum, value) => sum + value);
    onExistingBytes?.call(presentTotal());

    final incomplete = [
      for (var i = 0; i < plan.count; i++)
        if (present[i] < plan.length(i)) i,
    ];
    if (incomplete.isEmpty) return null;

    void persist() {
      _writeSegmentState(destPath, resumeToken, url, size, sha256, plan);
      if (resumeToken != null) {
        _writeSidecar(PatchDownloader.resumeSidecarPath(destPath), resumeToken,
            plan.etag);
      }
    }

    persist();

    final stop = Completer<void>();
    Object? failure;
    StackTrace? failureStack;
    void halt(Object error, StackTrace stack) {
      if (stop.isCompleted) return;
      failure = error;
      failureStack = stack;
      stop.complete();
    }

    bool stopped() => stop.isCompleted;
    bool stoppedOrCancelled() => stopped() || (isCancelled?.call() ?? false);

    final clock = Stopwatch()..start();
    var lastEmit = -1 << 30;
    void emit({bool force = false}) {
      if (onProgress == null) return;
      final now = clock.elapsedMilliseconds;
      if (!force && now - lastEmit < 100) return;
      lastEmit = now;
      onProgress(presentTotal(), size);
    }

    final poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (isCancelled?.call() ?? false) {
        halt(const PatchDownloadCancelled(), StackTrace.current);
      }
    });

    Future<void> consume(int index, _OpenedSegment opened) async {
      final sink =
          File(_segmentPath(destPath, index)).openWrite(mode: FileMode.append);
      var received = 0;
      var buffered = 0;
      try {
        await for (final chunk
            in opened.response.stream.timeout(stallTimeout)) {
          if (stopped()) break;
          if (received + chunk.length > opened.length) {
            throw const _SegmentFallback();
          }
          sink.add(chunk);
          received += chunk.length;
          present[index] += chunk.length;
          buffered += chunk.length;
          emit();
          if (buffered >= PatchDownloader._writeBufferBytes) {
            buffered = 0;
            await sink.flush();
          }
        }
      } catch (_) {
        try {
          await sink.close();
        } catch (_) {}
        rethrow;
      }
      await sink.flush();
      await sink.close();
      if (!stopped() && received != opened.length) {
        throw const HttpException('Range body ended early');
      }
    }

    Future<void> runSegment(int index, _OpenedSegment? first) async {
      var pending = first;
      var idleAttempts = 0;
      try {
        while (present[index] < plan.length(index)) {
          if (stopped()) return;
          final before = present[index];
          try {
            final opened = pending ??
                await _openSegment(
                    url, plan, index, present[index], size, sha256, stop.future,
                    probe: false);
            pending = null;
            await consume(index, opened);
          } catch (error) {
            if (stopped()) return;
            if (!PatchDownloader.isTransientNetworkError(error)) rethrow;
            // רק רצף ניסיונות שלא הביאו אף בית מפיל את הטווח.
            if (present[index] > before) idleAttempts = 0;
            if (idleAttempts >= networkRetryDelays.length) {
              throw PatchNetworkException(error);
            }
            await _waitBeforeRetry(
                networkRetryDelays[idleAttempts], stoppedOrCancelled);
            idleAttempts++;
          }
        }
      } catch (error, stack) {
        if (pending != null) await _abandonBody(pending.response);
        if (error is PatchDownloadCancelled && stopped()) return;
        halt(error, stack);
      }
    }

    try {
      final probeIndex =
          incomplete.firstWhere((i) => i > 0, orElse: () => incomplete.first);
      final _OpenedSegment probe;
      try {
        probe = await _withNetworkRetry(
          () => _openSegment(url, plan, probeIndex, present[probeIndex], size,
              sha256, stop.future,
              probe: true),
          isCancelled: isCancelled,
        );
      } on _SegmentFallback catch (outcome) {
        return outcome;
      } on _SegmentRestart catch (outcome) {
        return outcome;
      }
      try {
        persist();
      } catch (_) {
        await _abandonBody(probe.response);
        rethrow;
      }

      await Future.wait([
        for (final index in incomplete)
          runSegment(index, index == probeIndex ? probe : null),
      ]);
      final error = failure;
      if (error is _SegmentFallback || error is _SegmentRestart) {
        return error as Exception;
      }
      if (error != null) Error.throwWithStackTrace(error, failureStack!);
      emit(force: true);
      return null;
    } finally {
      poll.cancel();
      if (!stop.isCompleted) stop.complete();
    }
  }

  /// שולח בקשת טווח לטווח [index] ממשיך מ-[have], ומאמת את התשובה לפני הגוף.
  Future<_OpenedSegment> _openSegment(
    String url,
    _SegmentPlan plan,
    int index,
    int have,
    int size,
    String? sha256,
    Future<void> abortTrigger, {
    required bool probe,
  }) async {
    final start = plan.bounds[index] + have;
    final end = plan.bounds[index + 1] - 1;
    final knownEtag = plan.etag;
    final response = await _sendWithManualRedirects(
      url,
      {
        'Accept': 'application/octet-stream',
        'Range': 'bytes=$start-$end',
        if (knownEtag != null) 'If-Range': knownEtag,
      },
      abortTrigger: abortTrigger,
    );
    final etag = _strongEtag(response.headers['etag']);
    final etagChanged = knownEtag != null && etag != null && etag != knownEtag;

    if (response.statusCode == 200) {
      // 200 ננטש לפני הגוף, כך ששרת שמתעלם מ-Range אינו מוריד את הקובץ פי כמה.
      await _abandonBody(response);
      throw etagChanged ? const _SegmentRestart() : const _SegmentFallback();
    }
    if (response.statusCode != 206) {
      await _abandonBody(response);
      throw PatchDownloadException(LibraryUpdaterMessages.current
          .downloadHttpError(response.statusCode, url));
    }
    if (etagChanged) {
      await _abandonBody(response);
      throw const _SegmentRestart();
    }
    final range = _parseContentRange(response.headers['content-range']);
    final valid = range != null &&
        range.start == start &&
        range.end >= start &&
        range.end <= end &&
        range.total == size &&
        (response.contentLength == null ||
            response.contentLength == range.end - start + 1);
    if (valid && probe && knownEtag == null) plan.etag = etag;
    // בלי ETag ובלי sha256 אין דבר שכובל טווחים מחיבורים שונים לאותו תוכן.
    if (!valid || (plan.etag == null && sha256 == null)) {
      await _abandonBody(response);
      throw const _SegmentFallback();
    }
    return (response: response, length: range.end - start + 1);
  }
}

/// מצרף את הטווחים [assembled].. אל dest ב-isolate נפרד ומחזיר את ה-sha256
/// של הקובץ כולו (null כש-[hash] כבוי). הביטול נבדק בין קטעים.
Future<String?> _assembleSegmentsInIsolate({
  required String destPath,
  required List<int> bounds,
  required int assembled,
  required String? statePath,
  required Map<String, Object?> state,
  required bool hash,
  bool Function()? isCancelled,
  void Function(int done, int total)? onProgress,
}) =>
    _runCancellableWorker(
      _assembleWork(destPath, bounds, assembled, statePath, state, hash),
      isCancelled,
      onProgress,
    );

_WorkerBody<String?> _assembleWork(
  String destPath,
  List<int> bounds,
  int assembled,
  String? statePath,
  Map<String, Object?> state,
  bool hash,
) =>
    (isCancelled, onProgress) async => _assembleSegments(destPath, bounds,
        assembled, statePath, state, hash, isCancelled, onProgress);

/// כל טווח נרשם כמצורף בקובץ המצב לפני שקובצו נמחק; קריסה באמצע צירוף
/// משאירה זנב ב-dest שנחתך בריצה הבאה לפי [bounds].
String? _assembleSegments(
  String destPath,
  List<int> bounds,
  int assembled,
  String? statePath,
  Map<String, Object?> state,
  bool hash,
  bool Function()? isCancelled,
  void Function(int done, int total)? onProgress,
) {
  const chunkSize = 1 << 20;
  const reportEvery = 4 << 20;
  final total = bounds.last;
  final digestSink = hash ? Sha256DigestCollector() : null;
  final hasher = digestSink == null ? null : FastSha256.start(digestSink);
  var done = 0;
  var lastReported = 0;
  void advance(List<int> chunk) {
    if (isCancelled != null && isCancelled()) {
      throw const PatchDownloadCancelled();
    }
    hasher?.add(chunk);
    done += chunk.length;
    if (onProgress != null && done - lastReported >= reportEvery) {
      lastReported = done;
      onProgress(done, total);
    }
  }

  try {
    final prefix = bounds[assembled];
    if (hasher != null) {
      final input = File(destPath).openSync();
      try {
        for (var left = prefix; left > 0;) {
          final chunk = input.readSync(left < chunkSize ? left : chunkSize);
          if (chunk.isEmpty) break;
          advance(chunk);
          left -= chunk.length;
        }
      } finally {
        input.closeSync();
      }
    } else {
      done = prefix;
    }

    final output = File(destPath).openSync(mode: FileMode.append);
    try {
      output.truncateSync(prefix);
      output.setPositionSync(prefix);
      for (var i = assembled; i < bounds.length - 1; i++) {
        final segmentPath = _segmentPath(destPath, i);
        final input = File(segmentPath).openSync();
        try {
          for (var chunk = input.readSync(chunkSize);
              chunk.isNotEmpty;
              chunk = input.readSync(chunkSize)) {
            advance(chunk);
            output.writeFromSync(chunk);
          }
        } finally {
          input.closeSync();
        }
        output.flushSync();
        if (statePath != null) {
          _writeSegmentStateFile(statePath, {...state, 'assembled': i + 1});
        }
        _deleteFileQuietly(segmentPath);
      }
    } finally {
      output.closeSync();
    }
    onProgress?.call(done, total);
    hasher?.close();
    return digestSink?.value.toString();
  } finally {
    hasher?.dispose();
  }
}
