/// 神算子应用运行时 —— **纯 Dart、可测**。
///
/// ## 这个包管什么
///
/// Windows / Android 应用启动时要处理、且**不该塞进 UI 代码**的事：
///
/// | 关注点 | 入口 |
/// |---|---|
/// | 数据放哪、能不能放 | `DataDirectoryPolicy`、`AppBootstrap` |
/// | 上次选的位置 | `AppConfig` / `AppConfigStore` |
/// | 「这个目录是我的数据目录」 | `DataMarker` |
/// | 界面缩放等设备偏好 | `UiScale` |
/// | 界面字体栈 | `AppTypography` |
///
/// ## 为什么单独一个包
///
/// `shensuanzi_core` 是**数据层**（schema / 规则 / 同步协议），
/// `shensuanzi_host` 是**主机服务**（shelf / SyncServer / 令牌）；
/// 而「数据目录策略」既不是业务规则也不是服务 —— 它是**运行环境**。
/// 放进来会污染那两个包的语义，所以单开一个。
///
/// ## 为什么全部可测
///
/// 路径策略依赖「这块盘是不是 U 盘」「`%LOCALAPPDATA%` 在哪」这类**本机事实**。
/// 真机取值只在 [AppEnvironment.detect] 做一次，**判断逻辑全是纯函数**，
/// 于是测试可以构造出「有 U 盘 / 有网盘 / 无 D 盘」等各种机器
/// —— 不需要真的插一个 U 盘。
library;

export 'src/app_config.dart' show AppConfig, AppConfigStore, UiScale;
export 'src/bootstrap.dart'
    show AppBootstrap, DataDirectoryRejected, DataLocation;
export 'src/data_directory.dart'
    show DataDirectoryPolicy, DirectoryAdvice, DirectoryVerdict, formatBytes;
export 'src/data_directory_service.dart' show DataDirectoryService;
export 'src/data_marker.dart'
    show DataMarker, DirectoryContents, contentsOf;
export 'src/dialog_model.dart'
    show ConfirmOutcome, DataDirectoryDialogModel, DialogNoticeKind;
export 'src/environment.dart' show AppEnvironment, DriveInfo, DriveKind;
export 'src/navigation.dart'
    show AppNavigation, NavDestination, NavSection;
export 'src/backup.dart'
    show
        BackupFileName,
        BackupOutcome,
        BackupService,
        backupOutcomeMessage,
        backupReminderText,
        backupStatusLine,
        daysSince,
        expiredAutoBackups,
        formatBackupTime,
        needsBackupAttention,
        shouldAutoBackup,
        weekKeyOf;
export 'src/typography.dart' show AppTypography;

// ---- §AF 数据导出 ----
export 'src/csv.dart' show csvBom, csvBytes, csvEscape, csvLine;
export 'src/export.dart'
    show
        ExportEmpty,
        ExportFailed,
        ExportFileName,
        ExportOutcome,
        ExportService,
        ExportSink,
        ExportSuccess,
        ExportTable,
        exportOutcomeMessage;
export 'src/export_tables.dart'
    show
        documentExportTable,
        partyExportTable,
        partyFlowExportTable,
        productExportTable,
        stockExportTable;
export 'src/format.dart'
    show
        activeLabel,
        docStatusLabel,
        documentPartyLabel,
        formatDate,
        formatDateTime,
        formatFileDate,
        partyRoleLabel,
        partyRolesLabel;
export 'src/fs.dart' show ensureWritableDirectory;
