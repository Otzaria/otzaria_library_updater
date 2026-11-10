import 'package:seforim_library_updater/seforim_library_updater.dart';

/// Frozen pre-pruning message contract, to catch source compatibility breaks.
///
/// Unlike subclasses of HebrewLibraryUpdaterMessages, a direct implementer
/// cannot inherit new members. Keep this fixture independent of optional
/// message capabilities when adding informational progress messages.
class LegacyLibraryUpdaterMessages implements LibraryUpdaterMessages {
  const LegacyLibraryUpdaterMessages();

  static const _delegate = HebrewLibraryUpdaterMessages();

  @override
  String megabytes(String amount) => _delegate.megabytes(amount);

  @override
  String gigabytes(String amount) => _delegate.gigabytes(amount);

  @override
  String unsupportedPatchCompression(String compression) =>
      _delegate.unsupportedPatchCompression(compression);

  @override
  String get manifestMissingPatchFiles => _delegate.manifestMissingPatchFiles;

  @override
  String manifestMissingField(String key) =>
      _delegate.manifestMissingField(key);

  @override
  String get manifestMissingPatchFormatVersion =>
      _delegate.manifestMissingPatchFormatVersion;

  @override
  String manifestInvalidOptionalField(String key) =>
      _delegate.manifestInvalidOptionalField(key);

  @override
  String manifestInvalidHashMap(String key) =>
      _delegate.manifestInvalidHashMap(key);

  @override
  String releasesRequestFailed(int statusCode) =>
      _delegate.releasesRequestFailed(statusCode);

  @override
  String get releasesResponseNotList => _delegate.releasesResponseNotList;

  @override
  String manifestDownloadFailed(String url, int statusCode) =>
      _delegate.manifestDownloadFailed(url, statusCode);

  @override
  String manifestNotJsonObject(String url) =>
      _delegate.manifestNotJsonObject(url);

  @override
  String splitManifestDownloadFailed(String name, int statusCode) =>
      _delegate.splitManifestDownloadFailed(name, statusCode);

  @override
  String mirrorManifestMissing(String fileName, String mirrorDir) =>
      _delegate.mirrorManifestMissing(fileName, mirrorDir);

  @override
  String mirrorManifestCorrupt(
    String fileName,
    String mirrorDir,
    String error,
  ) => _delegate.mirrorManifestCorrupt(fileName, mirrorDir, error);

  @override
  String mirrorManifestUnexpectedShape(String fileName, String mirrorDir) =>
      _delegate.mirrorManifestUnexpectedShape(fileName, mirrorDir);

  @override
  String mirrorPatchManifestMissing(String url) =>
      _delegate.mirrorPatchManifestMissing(url);

  @override
  String mirrorPatchManifestCorrupt(String url, String error) =>
      _delegate.mirrorPatchManifestCorrupt(url, error);

  @override
  String mirrorPatchManifestNotJson(String url) =>
      _delegate.mirrorPatchManifestNotJson(url);

  @override
  String get interruptedUpdateFound => _delegate.interruptedUpdateFound;

  @override
  String get interruptedUpdateWithoutBackup =>
      _delegate.interruptedUpdateWithoutBackup;

  @override
  String get interruptedUpdateRestored => _delegate.interruptedUpdateRestored;

  @override
  String get localDbLocked => _delegate.localDbLocked;

  @override
  String get localDbInterruptedWrite => _delegate.localDbInterruptedWrite;

  @override
  String get localDbReadOnlyLocation => _delegate.localDbReadOnlyLocation;

  @override
  String get planLocalVersionUnknown => _delegate.planLocalVersionUnknown;

  @override
  String planNoDeltaRoute(int localVersion, int latestVersion) =>
      _delegate.planNoDeltaRoute(localVersion, latestVersion);

  @override
  String planNoFullDbEither(String reason) =>
      _delegate.planNoFullDbEither(reason);

  @override
  String planSchemaNeedsAppUpdate(int schemaVersion, int supportedSchema) =>
      _delegate.planSchemaNeedsAppUpdate(schemaVersion, supportedSchema);

  @override
  String planSchemaBarrierNeedsFullDownload(int schemaVersion) =>
      _delegate.planSchemaBarrierNeedsFullDownload(schemaVersion);

  @override
  String planDeltaNeedsAppUpdate(
    int latestVersion,
    int supportedSchema,
    int supportedPatchFormat,
  ) => _delegate.planDeltaNeedsAppUpdate(
    latestVersion,
    supportedSchema,
    supportedPatchFormat,
  );

  @override
  String planHeavyDelta(String deltaSize, String localDbSize) =>
      _delegate.planHeavyDelta(deltaSize, localDbSize);

  @override
  String planContentChangedWithoutVersionBump(String releaseTag) =>
      _delegate.planContentChangedWithoutVersionBump(releaseTag);

  @override
  String planFullDbFasterThanPatches(
    int stepCount,
    int patchMinutes,
    int fullDbMinutes,
  ) => _delegate.planFullDbFasterThanPatches(
    stepCount,
    patchMinutes,
    fullDbMinutes,
  );

  @override
  String planPatchSchemaTooNew(int schemaVersion, int latestVersion) =>
      _delegate.planPatchSchemaTooNew(schemaVersion, latestVersion);

  @override
  String planPatchFormatTooNew(int patchFormatVersion, int latestVersion) =>
      _delegate.planPatchFormatTooNew(patchFormatVersion, latestVersion);

  @override
  String planFullDbWouldNotProgress(
    int reachableVersion,
    int localVersion,
    int latestVersion,
  ) => _delegate.planFullDbWouldNotProgress(
    reachableVersion,
    localVersion,
    latestVersion,
  );

  @override
  String planNewSchemaNeedsFullDb(int latestVersion, int schemaVersion) =>
      _delegate.planNewSchemaNeedsFullDb(latestVersion, schemaVersion);

  @override
  String planPartialDeltaSchemaStop(
    int reachedVersion,
    int latestVersion,
    int schemaVersion,
  ) => _delegate.planPartialDeltaSchemaStop(
    reachedVersion,
    latestVersion,
    schemaVersion,
  );

  @override
  String planPartialDeltaFormatStop(
    int reachedVersion,
    int latestVersion,
    int patchFormatVersion,
  ) => _delegate.planPartialDeltaFormatStop(
    reachedVersion,
    latestVersion,
    patchFormatVersion,
  );

  @override
  String unsupportedSchemaForHashOrder(int schemaVersion) =>
      _delegate.unsupportedSchemaForHashOrder(schemaVersion);

  @override
  String localVersionMismatch(int? localVersion, int expected) =>
      _delegate.localVersionMismatch(localVersion, expected);

  @override
  String localSchemaMismatch(int localSchema, int expected) =>
      _delegate.localSchemaMismatch(localSchema, expected);

  @override
  String get contentHashMismatchNeedsFullDownload =>
      _delegate.contentHashMismatchNeedsFullDownload;

  @override
  String patchUniqueConflictNeedsFullDownload(String table, String detail) =>
      _delegate.patchUniqueConflictNeedsFullDownload(table, detail);

  @override
  String foreignKeyViolationsGrew(int before, int after) =>
      _delegate.foreignKeyViolationsGrew(before, after);

  @override
  String resultHashMismatch(String actual, String expected) =>
      _delegate.resultHashMismatch(actual, expected);

  @override
  String tableHashMismatch(String tables) =>
      _delegate.tableHashMismatch(tables);

  @override
  String patchOpenFailed(String path, String detail) =>
      _delegate.patchOpenFailed(path, detail);

  @override
  String get patchMetaSchemaVersionMissing =>
      _delegate.patchMetaSchemaVersionMissing;

  @override
  String patchFormatTooNew(int patchFormatVersion, int supported) =>
      _delegate.patchFormatTooNew(patchFormatVersion, supported);

  @override
  String patchFormatMismatch(int inPatch, int inManifest) =>
      _delegate.patchFormatMismatch(inPatch, inManifest);

  @override
  String patchVersionRangeMismatch(
    int? from,
    int? to,
    int manifestFrom,
    int manifestTo,
  ) => _delegate.patchVersionRangeMismatch(from, to, manifestFrom, manifestTo);

  @override
  String get networkInterrupted => _delegate.networkInterrupted;

  @override
  String get compressedFileSizeLabel => _delegate.compressedFileSizeLabel;

  @override
  String get compressedFileHashLabel => _delegate.compressedFileHashLabel;

  @override
  String get extractedFileSizeLabel => _delegate.extractedFileSizeLabel;

  @override
  String get extractedFileHashLabel => _delegate.extractedFileHashLabel;

  @override
  String get patchExtractionFailed => _delegate.patchExtractionFailed;

  @override
  String get deleteExistingWithoutResumeIdentityFailed =>
      _delegate.deleteExistingWithoutResumeIdentityFailed;

  @override
  String get deletePartialFromPreviousVersionFailed =>
      _delegate.deletePartialFromPreviousVersionFailed;

  @override
  String get deletePartialWithoutValidatorFailed =>
      _delegate.deletePartialWithoutValidatorFailed;

  @override
  String get deletePartialFromPreviousRepresentationFailed =>
      _delegate.deletePartialFromPreviousRepresentationFailed;

  @override
  String get deletePartialBeforeRetryFailed =>
      _delegate.deletePartialBeforeRetryFailed;

  @override
  String get deletePreviousArchiveFailed =>
      _delegate.deletePreviousArchiveFailed;

  @override
  String fullDbSizeMismatch(int downloaded, int expected) =>
      _delegate.fullDbSizeMismatch(downloaded, expected);

  @override
  String get fullDbHashMismatch => _delegate.fullDbHashMismatch;

  @override
  String joinedArchiveSizeMismatch(int written, int expected) =>
      _delegate.joinedArchiveSizeMismatch(written, expected);

  @override
  String get joinedArchiveHashMismatch => _delegate.joinedArchiveHashMismatch;

  @override
  String resumeRoundLimit(int maxRounds, String url) =>
      _delegate.resumeRoundLimit(maxRounds, url);

  @override
  String contentLengthMismatch(int responseLength, int expectedSize) =>
      _delegate.contentLengthMismatch(responseLength, expectedSize);

  @override
  String truncatedBody(int declared, int received) =>
      _delegate.truncatedBody(declared, received);

  @override
  String downloadHttpError(int statusCode, String url) =>
      _delegate.downloadHttpError(statusCode, url);

  @override
  String resumeMadeNoProgress(String url) =>
      _delegate.resumeMadeNoProgress(url);

  @override
  String resumeFailedAfterRetry(String url) =>
      _delegate.resumeFailedAfterRetry(url);

  @override
  String downloadExceedsExpectedSize(int expectedSize) =>
      _delegate.downloadExceedsExpectedSize(expectedSize);

  @override
  String saveDownloadedFileFailed(String error) =>
      _delegate.saveDownloadedFileFailed(error);

  @override
  String tooManyRedirects(String url) => _delegate.tooManyRedirects(url);

  @override
  String writeResumeSidecarFailed(String path, String error) =>
      _delegate.writeResumeSidecarFailed(path, error);

  @override
  String get downloadAlreadyInProgress => _delegate.downloadAlreadyInProgress;

  @override
  String destinationBusy(String path) => _delegate.destinationBusy(path);

  @override
  String checksumMismatchDetailed(
    String label,
    String expected,
    String actual,
  ) => _delegate.checksumMismatchDetailed(label, expected, actual);

  @override
  String checksumMismatch(String label) => _delegate.checksumMismatch(label);

  @override
  String localFileNotFound(String path) => _delegate.localFileNotFound(path);

  @override
  String localFileTooLarge(int maxBytes, String path) =>
      _delegate.localFileTooLarge(maxBytes, path);

  @override
  String localSourceNotFound(String url) => _delegate.localSourceNotFound(url);

  @override
  String localFileSizeMismatch(int expected, int actual, String url) =>
      _delegate.localFileSizeMismatch(expected, actual, url);

  @override
  String localFileHashMismatch(String url) =>
      _delegate.localFileHashMismatch(url);

  @override
  String get exportLoadingReleases => _delegate.exportLoadingReleases;

  @override
  String get exportNoReleases => _delegate.exportNoReleases;

  @override
  String exportPersonalFrom(int localVersion) =>
      _delegate.exportPersonalFrom(localVersion);

  @override
  String exportPersonalUpToDate(int localVersion) =>
      _delegate.exportPersonalUpToDate(localVersion);

  @override
  String exportReusingFullDb(int version, String tag) =>
      _delegate.exportReusingFullDb(version, tag);

  @override
  String exportDownloading(String tag, String asset) =>
      _delegate.exportDownloading(tag, asset);

  @override
  String exportVerifying(String tag, String asset, int percent) =>
      _delegate.exportVerifying(tag, asset, percent);

  @override
  String exportAssembling(String tag, String asset, int percent) =>
      _delegate.exportAssembling(tag, asset, percent);

  @override
  String exportSplitFullDbSkipped(String tag, String detail) =>
      _delegate.exportSplitFullDbSkipped(tag, detail);

  @override
  String exportSplitPartCorrupted(String asset, String parts) =>
      _delegate.exportSplitPartCorrupted(asset, parts);

  @override
  String exportAssembledReplaceFailed(String path, String detail) =>
      _delegate.exportAssembledReplaceFailed(path, detail);

  @override
  String exportWritingManifest(String fileName) =>
      _delegate.exportWritingManifest(fileName);

  @override
  String get exportDone => _delegate.exportDone;

  @override
  String get exportCancelled => _delegate.exportCancelled;

  @override
  String get exporterDoesNotExtract => _delegate.exporterDoesNotExtract;

  @override
  String exportManifestUnreadable(String asset, String detail) =>
      _delegate.exportManifestUnreadable(asset, detail);

  @override
  String exportManifestFetchFailed(String asset, String detail) =>
      _delegate.exportManifestFetchFailed(asset, detail);

  @override
  String exportPatchAssetMissing(String tag, String file) =>
      _delegate.exportPatchAssetMissing(tag, file);

  @override
  String exportSkippingUnappliablePatch(
    String tag,
    String file,
    int schemaVersion,
  ) => _delegate.exportSkippingUnappliablePatch(tag, file, schemaVersion);

  @override
  String exportSkippingUnsupportedPatchFormat(
    String tag,
    String file,
    int patchFormatVersion,
  ) => _delegate.exportSkippingUnsupportedPatchFormat(
    tag,
    file,
    patchFormatVersion,
  );

  @override
  String exportFullDbRequiredBySchema(int schemaVersion, int latestVersion) =>
      _delegate.exportFullDbRequiredBySchema(schemaVersion, latestVersion);

  @override
  String exportFullDbRequiredByPatchFormat(
    int patchFormatVersion,
    int latestVersion,
  ) => _delegate.exportFullDbRequiredByPatchFormat(
    patchFormatVersion,
    latestVersion,
  );

  @override
  String exportFullDbSchemaUnsupported(String tag, int schemaVersion) =>
      _delegate.exportFullDbSchemaUnsupported(tag, schemaVersion);

  @override
  String exportSkippingPatchesFullDbWins(int fileCount, int fullDbVersion) =>
      _delegate.exportSkippingPatchesFullDbWins(fileCount, fullDbVersion);

  @override
  String exportFullDbInsteadOfSlowPatches(
    int fileCount,
    int patchMinutes,
    int fullDbMinutes,
    int toVersion,
  ) => _delegate.exportFullDbInsteadOfSlowPatches(
    fileCount,
    patchMinutes,
    fullDbMinutes,
    toVersion,
  );

  @override
  String exportPersonalNeedsFullDb(int fromVersion, int latestVersion) =>
      _delegate.exportPersonalNeedsFullDb(fromVersion, latestVersion);

  @override
  String exportPersonalNoFullDbEither(int fromVersion, int latestVersion) =>
      _delegate.exportPersonalNoFullDbEither(fromVersion, latestVersion);

  @override
  String mirrorNotEnoughDiskSpace(String dir, String needed, String free) =>
      _delegate.mirrorNotEnoughDiskSpace(dir, needed, free);
}
