/// לקוח Dart לצריכת הפצות הדלתא של `Otzaria/SeforimLibrary`.
///
/// מייצא את ה-API הציבורי בלבד: מודלים של פורמט ההפצה, גילוי ותכנון מסלול,
/// הורדה ואימות, חישוב hash לוגי, והחלת patch אטומית.
///
/// **פעולות חוסמות:** `LogicalContentHasher.compute` ו-`PatchApplier.apply`
/// סינכרוניות וכבדות (ה-hash עד עשרות שניות על DB מלא). אל תריץ אותן על ה-UI
/// isolate — עטוף ב-`Isolate.run`.
library;

export 'src/models/delta_manifest.dart' show DeltaManifest, PatchFileEntry;
export 'src/models/library_release.dart'
    show LibraryRelease, ReleaseAsset, fullDbArchiveNameForSchema;
export 'src/models/library_update_plan.dart'
    show LibraryUpdatePlan, LibraryUpdatePlanKind, PatchEdge;
export 'src/models/split_asset.dart'
    show SplitAsset, SplitAssetPart, kGithubAssetLimit, kSplitManifestSuffix;
export 'src/models/patch_table_spec.dart'
    show
        PatchTableSpec,
        kPatchTablesInFkOrder,
        kHashTableOrder,
        kDefaultConsumerDbSchemaVersion,
        kSupportedDbSchemaVersion;
export 'src/services/github_library_release_client.dart'
    show GithubLibraryReleaseClient;
export 'src/services/library_db_recovery_service.dart'
    show LibraryDbRecoveryService, RecoveryResult, RecoveryAction;
export 'src/services/library_update_discovery.dart'
    show LibraryUpdateDiscovery, LibraryDiscoveryResult;
export 'src/services/library_update_planner.dart'
    show LibraryUpdatePlanner, kDefaultMaxDeltaUncompressedRatio;
export 'src/services/local_db_version_reader.dart'
    show LocalDbVersionReader, LocalDbVersion;
export 'src/services/logical_content_hasher.dart'
    show LogicalContentHasher, LogicalContentHashReport;
export 'src/services/patch_applier.dart'
    show
        PatchApplier,
        PatchApplyResult,
        PatchApplyException,
        PatchHashMismatchStage,
        hashTableOrderForSchemaVersion,
        kBooksTouchedTables,
        kDefaultApplyChunkSize;
export 'src/services/patch_downloader.dart'
    show
        PatchDownloader,
        PatchDownloadException,
        PatchDownloadCancelled,
        PatchNetworkException;
