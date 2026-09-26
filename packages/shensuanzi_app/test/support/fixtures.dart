/// 应用层测试夹具：**用代码构造「各种机器」**。
///
/// 路径策略要判断「这块盘是不是 U 盘」「`%LOCALAPPDATA%` 在哪」——
/// 这些是本机事实。真机取值只在 `AppEnvironment.detect()` 做一次，
/// 其余全是纯函数，所以测试可以造出「有 U 盘 / 有网盘 / 无 D 盘」的机器
/// —— **不需要真的插一个 U 盘**。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';

const int gb = 1024 * 1024 * 1024;

// ---------------------------------------------------------------- 盘

/// C 系统盘：充足
const DriveInfo cDrive = DriveInfo(
  root: r'C:\',
  kind: DriveKind.fixed,
  freeBytes: 100 * gb,
);

/// D 数据盘：充足（默认期望它被选中）
const DriveInfo dDrive = DriveInfo(
  root: r'D:\',
  kind: DriveKind.fixed,
  freeBytes: 128 * gb,
);

/// E U 盘：充足，但**可移动**
const DriveInfo eUsb = DriveInfo(
  root: r'E:\',
  kind: DriveKind.removable,
  freeBytes: 16 * gb,
);

/// Z 网络盘
const DriveInfo zNetwork = DriveInfo(
  root: r'Z:\',
  kind: DriveKind.network,
  freeBytes: 500 * gb,
);

/// F 固定盘，但**剩余空间不足**
const DriveInfo fTight = DriveInfo(
  root: r'F:\',
  kind: DriveKind.fixed,
  freeBytes: 50 * 1024 * 1024,
);

// ---------------------------------------------------------------- 机器

/// 造一台机器。默认 = 「最普通的 Windows 台式机」：C 系统盘 + D 数据盘。
AppEnvironment machine({
  String home = r'C:\Users\tester',
  List<DriveInfo>? drives,
  Map<String, String>? environment,
  bool isWindows = true,
}) => AppEnvironment(
  isWindows: isWindows,
  homeDirectory: home,
  drives: drives ?? <DriveInfo>[cDrive, dDrive],
  environment:
      environment ??
      <String, String>{
        'USERPROFILE': home,
        'LOCALAPPDATA': r'C:\Users\tester\AppData\Local',
        'APPDATA': r'C:\Users\tester\AppData\Roaming',
        'TEMP': r'C:\Users\tester\AppData\Local\Temp',
      },
);

/// 只有系统盘的机器（没有可用的非系统盘）
AppEnvironment systemDriveOnly({String home = r'C:\Users\tester'}) =>
    machine(home: home, drives: <DriveInfo>[cDrive]);

// ---------------------------------------------------------------- 沙箱

/// 一个用完即弃的临时目录。
///
/// **绝不能在测试里碰真实的 `%APPDATA%`** —— 那会把开发者自己的配置写坏。
Directory sandbox() =>
    Directory.systemTemp.createTempSync('shensuanzi_app_test_');

/// 把配置也关进沙箱
AppBootstrap bootstrapIn(Directory box, {AppEnvironment? environment}) =>
    AppBootstrap(
      environment: environment ?? machine(),
      configStore: AppConfigStore(File(p.join(box.path, 'config.json'))),
    );

/// 数据目录服务（UI 入口），配置同样关进沙箱
DataDirectoryService serviceIn(Directory box, {AppEnvironment? environment}) =>
    DataDirectoryService(
      environment: environment ?? machine(),
      configStore: AppConfigStore(File(p.join(box.path, 'config.json'))),
    );

/// 指向沙箱里的数据目录
String sandboxPath(Directory box, String name) => p.join(box.path, name);
