part of 'patch_downloader.dart';

/// Conservative output ceiling for full archives without an uncompressed size
/// in their release metadata. Consumers may expose a lower/configurable limit;
/// a manifest's exact size should always be used for a patch.
const int kDefaultMaxExtractedBytes = 64 << 30;

/// Historical filename mapping for compressed patch assets.
String extractedPatchFileName(String archiveFileName) =>
    archiveFileName.endsWith('.zst')
    ? archiveFileName.substring(0, archiveFileName.length - 4)
    : '$archiveFileName.db';

/// Runs a complete file operation under the same cross-process/cross-isolate
/// lock used by [PatchDownloader]. The parent directory must already exist.
///
/// All operations that share staging files or replace the same live database
/// must use the same [destination] until extraction, installation, rollback and
/// cleanup have settled. The lock fails immediately if another operation owns
/// it; it is not reentrant. Do not call [PatchDownloader.downloadToFile] for the
/// same destination inside [operation], since that method takes this lock too.
/// The persistent `<destination>.lock` sidecar must never be deleted or renamed.
Future<T> withFileOperationLock<T>(
  String destination,
  Future<T> Function() operation,
) async {
  final lock = _DestinationLock.acquire(destination);
  try {
    return await operation();
  } finally {
    lock.release();
  }
}

/// A bounded file-to-file decoder supplied by the host application.
///
/// The decoder must await each write, reject output exceeding [maxOutputBytes]
/// **before** writing it, and check [isCancelled] between output chunks (not
/// just input chunks: one compressed chunk can expand to many output chunks).
/// Cancellation throws [PatchDownloadCancelled]. All native handles and files
/// must be closed before the future completes, including on failure.
/// Invalid compressed data throws [FormatException] or [PatchDownloadException]
/// so it can be discarded. Resource/backend errors must use a different type
/// (for example [StateError]) to preserve a verified archive for retry.
///
/// [onProgress] reports output bytes written. The returned digest covers the
/// exact output bytes, in order, and is finalized only after the decoder has
/// validated the complete input and flushed the output. This allows callers to
/// verify the output without reading a multi-GB file a second time.
///
/// The decoder must use bounded buffers and a bounded decoding window. It must
/// not read the complete input or accumulate the output in memory. Callers own
/// [outputPath] and are responsible for deleting failed partial output; decoders
/// should also clean their partial output when used directly.
typedef FileExtractor =
    Future<FileExtractionResult> Function(
      String sourcePath,
      String outputPath, {
      required int maxOutputBytes,
      bool Function()? isCancelled,
      void Function(int bytesWritten)? onProgress,
    });

/// Output of a completed [FileExtractor], hashed while it was written.
class FileExtractionResult {
  const FileExtractionResult({
    required this.bytesWritten,
    required this.sha256,
  });

  final int bytesWritten;
  final String sha256;
}

/// Downloads and verifies the compressed patch with [downloadToFile], then
/// extracts and verifies it without holding either full file in memory.
///
/// Existing [PatchDownloader] users retain their original in-memory API. Hosts
/// with a streaming decoder can use this class for both HTTP and local mirrors.
/// The manifest's output size is passed to the decoder as a hard write limit.
/// Only a fully verified output is renamed into the reusable patch path; failed
/// extraction removes its temporary output and leaves a resumable download on
/// cancellation, network failure or a local resource failure.
class StreamingPatchDownloader extends PatchDownloader {
  StreamingPatchDownloader({
    required FileExtractor extractor,
    super.httpClient,
    super.connectTimeout,
    super.stallTimeout,
    super.networkRetryDelays,
    super.maxConnections,
    super.segmentThresholdBytes,
  }) : _extractor = extractor,
       super(decompress: _unusedDecompress);

  final FileExtractor _extractor;

  static Future<Uint8List?> _unusedDecompress(Uint8List _) =>
      throw StateError('StreamingPatchDownloader does not decode byte buffers');

  /// Returns a cached extracted patch only after rechecking its size and hash.
  /// Cancellation while checking keeps the file for the next attempt.
  Future<String?> findReusableExtracted({
    required PatchFileEntry patchFile,
    required Directory destDir,
    void Function(int bytesDone, int bytesTotal)? onVerifyProgress,
    bool Function()? isCancelled,
  }) async {
    _throwIfCancelled(isCancelled);
    final paths = _patchPaths(patchFile, destDir);
    if (!await destDir.exists()) return null;
    _throwIfCancelled(isCancelled);
    final compressedLock = _DestinationLock.acquire(paths.compressed);
    try {
      final outputLock = _DestinationLock.acquire(paths.extracted);
      try {
        if (!await _reuseExtracted(
          patchFile,
          paths.extracted,
          onVerifyProgress: onVerifyProgress,
          isCancelled: isCancelled,
        )) {
          return null;
        }
        _throwIfCancelled(isCancelled);
        await _deleteCompressed(paths.compressed);
        return paths.extracted;
      } finally {
        outputLock.release();
      }
    } finally {
      compressedLock.release();
    }
  }

  @override
  Future<String> downloadAndExtract({
    required PatchFileEntry patchFile,
    required String downloadUrl,
    required Directory destDir,
    void Function(int downloaded, int? total)? onProgress,
    void Function(int bytesDone, int bytesTotal)? onVerifyProgress,
    void Function(int bytesWritten, int bytesTotal)? onExtractionProgress,
    bool Function()? isCancelled,
  }) async {
    _throwIfCancelled(isCancelled);
    final paths = _patchPaths(patchFile, destDir);
    if (!PatchDownloader.isRemoteUrl(downloadUrl)) {
      // Reject aliases before reuse/cleanup can touch a caller-owned source.
      for (final target in [
        paths.compressed,
        paths.extracted,
        '${paths.extracted}.extracting',
        '${paths.compressed}.resume',
        '${paths.compressed}.lock',
        '${paths.extracted}.lock',
      ]) {
        await _ensureDistinctFiles(downloadUrl, target);
      }
    }
    await destDir.create(recursive: true);
    _throwIfCancelled(isCancelled);
    // Keep both locks through verification, extraction, publication and cleanup.
    // Releasing the compressed lock immediately after downloading would allow a
    // second caller to replace/remove the archive while the decoder reads it.
    final compressedLock = _DestinationLock.acquire(paths.compressed);
    try {
      final outputLock = _DestinationLock.acquire(paths.extracted);
      try {
        return await _downloadAndExtractLocked(
          patchFile: patchFile,
          downloadUrl: downloadUrl,
          compressedPath: paths.compressed,
          extractedPath: paths.extracted,
          onProgress: onProgress,
          onVerifyProgress: onVerifyProgress,
          onExtractionProgress: onExtractionProgress,
          isCancelled: isCancelled,
        );
      } finally {
        outputLock.release();
      }
    } finally {
      compressedLock.release();
    }
  }

  Future<String> _downloadAndExtractLocked({
    required PatchFileEntry patchFile,
    required String downloadUrl,
    required String compressedPath,
    required String extractedPath,
    void Function(int downloaded, int? total)? onProgress,
    void Function(int bytesDone, int bytesTotal)? onVerifyProgress,
    void Function(int bytesWritten, int bytesTotal)? onExtractionProgress,
    bool Function()? isCancelled,
  }) async {
    final messages = LibraryUpdaterMessages.current;
    final partialPath = '$extractedPath.extracting';
    final reportExtraction = onExtractionProgress ?? onVerifyProgress;
    // A process crash can leave this file behind; it is never a reusable output.
    await _deleteRequired(partialPath, messages.deletePreviousArchiveFailed);
    if (await _reuseExtracted(
      patchFile,
      extractedPath,
      onVerifyProgress: onVerifyProgress,
      isCancelled: isCancelled,
    )) {
      _throwIfCancelled(isCancelled);
      onProgress?.call(patchFile.size, patchFile.size);
      _throwIfCancelled(isCancelled);
      await _deleteCompressed(compressedPath);
      return extractedPath;
    }

    try {
      // The compressed digest remains an independent pre-extraction check.
      // The existing downloader owns HTTP retry, segmented/resumed downloads,
      // validator binding, and deletion of invalid compressed input.
      await _downloadToFileLocked(
        url: downloadUrl,
        destPath: compressedPath,
        expectedSize: patchFile.size,
        expectedSha256: patchFile.sha256,
        resumeToken: patchFile.sha256.toLowerCase(),
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      _throwIfCancelled(isCancelled);
      reportExtraction?.call(0, patchFile.uncompressedSize);
      final result = await _extractor(
        compressedPath,
        partialPath,
        maxOutputBytes: patchFile.uncompressedSize,
        isCancelled: isCancelled,
        onProgress: reportExtraction == null
            ? null
            : (written) =>
                  reportExtraction(written, patchFile.uncompressedSize),
      );
      _throwIfCancelled(isCancelled);
      _verify(
        actual: result.bytesWritten,
        expected: patchFile.uncompressedSize,
        label: messages.extractedFileSizeLabel,
      );
      final output = File(partialPath);
      if (!await output.exists()) {
        throw PatchDownloadException(messages.patchExtractionFailed);
      }
      _verify(
        actual: await output.length(),
        expected: patchFile.uncompressedSize,
        label: messages.extractedFileSizeLabel,
      );
      if (result.sha256.toLowerCase() !=
          patchFile.uncompressedSha256.toLowerCase()) {
        throw PatchDownloadException(
          messages.checksumMismatch(messages.extractedFileHashLabel),
        );
      }
      onVerifyProgress?.call(
        patchFile.uncompressedSize,
        patchFile.uncompressedSize,
      );
      _throwIfCancelled(isCancelled);
      // Decoder has already closed/flushed output. The rename is on the same
      // filesystem and is the sole publication point for the verified file.
      // No user callbacks run after this commit point.
      await output.rename(extractedPath);
      await _deleteCompressed(compressedPath);
      return extractedPath;
    } catch (error) {
      await _deletePartialQuietly(partialPath);
      // A metadata/hash mismatch is not a resumable network problem. Preserve
      // verified input on cancellation/resource errors so another extraction
      // does not need to download the same complete archive again.
      if (error is PatchDownloadException || error is FormatException) {
        await _deleteCompressed(compressedPath);
      }
      rethrow;
    }
  }

  Future<bool> _reuseExtracted(
    PatchFileEntry patchFile,
    String extractedPath, {
    void Function(int bytesDone, int bytesTotal)? onVerifyProgress,
    bool Function()? isCancelled,
  }) async {
    _throwIfCancelled(isCancelled);
    final extracted = File(extractedPath);
    if (!await extracted.exists()) return false;
    if (await extracted.length() == patchFile.uncompressedSize) {
      final hash = await _hashFileSha256InIsolate(
        extractedPath,
        isCancelled,
        onVerifyProgress,
      );
      _throwIfCancelled(isCancelled);
      if (hash == patchFile.uncompressedSha256.toLowerCase()) return true;
    }
    _throwIfCancelled(isCancelled);
    await _deleteRequired(
      extractedPath,
      LibraryUpdaterMessages.current.deletePreviousArchiveFailed,
    );
    return false;
  }

  static ({String compressed, String extracted}) _patchPaths(
    PatchFileEntry patchFile,
    Directory destDir,
  ) {
    final name = patchFile.file;
    final extractedName = extractedPatchFileName(name);
    final root = p.absolute(destDir.path);
    final compressed = p.join(root, name);
    final extracted = p.join(root, extractedName);
    // Also check manually constructed manifests, on all host platforms. A
    // Windows path must not become a permissible filename on a Linux producer.
    if (name.isEmpty ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains(':') ||
        !p.isWithin(root, compressed) ||
        !p.isWithin(root, extracted) ||
        patchFile.size <= 0 ||
        patchFile.uncompressedSize <= 0) {
      throw PatchDownloadException(
        LibraryUpdaterMessages.current.manifestMissingField('file'),
      );
    }
    return (compressed: compressed, extracted: extracted);
  }

  static Future<void> _deleteCompressed(String path) async {
    await _deletePartialQuietly(path);
    await _deletePartialQuietly(PatchDownloader.resumeSidecarPath(path));
  }

  static Future<void> _deletePartialQuietly(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Cleanup must not hide the original exception. A leftover .extracting
      // file is removed before a retry and can never be returned as verified.
    }
  }
}
