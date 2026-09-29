/// 最小日志（§AG-5 裁定）。
///
/// ## 位置为什么在 `%APPDATA%`，不在数据目录
///
/// | | 性质 | 用户会不会拷走 |
/// |---|---|---|
/// | 数据目录 | **经营数据** | 会（备份、换电脑、给会计） |
/// | `%APPDATA%\神算子\` | **设备本地状态** | 不会（换机器没必要带） |
///
/// 配置已经在 `%APPDATA%\神算子\`（§O 裁定），日志跟它走是同一个原则。
///
/// 实现上更进一步：**日志目录 = 配置文件的兄弟目录下的 `日志/`**
/// （见 [AppLog.besideConfig]）。好处有两条：
///
/// 1. 生产环境自动落在 `%APPDATA%\神算子\日志\`，**不需要第二处路径推导**
///    （少一处推导 = 少一处漂移，与「判断只有一处」同源）；
/// 2. **测试自动安全** —— widget 测试把 `configStore` 指向沙箱时，日志也跟着进沙箱。
///    否则启动测试会往开发者**真实的** `%APPDATA%` 里写文件
///    （`docs/testing.md` §K 明令禁止的事）。
///
/// ## ⚠️ 铁律：**绝不记录经营数据**
///
/// 商品名 / 金额 / 往来方 / 单据内容**一律不写**。日志是用来回答「程序为什么打不开」
/// 的，不是用来复盘生意的。这条同时是**隐私承诺**：日志文件被拷走也不泄露生意。
/// （所以 [crash] 只记异常与堆栈 —— 而异常文本来自我们自己抛的字符串。）
///
/// ## 形态与边界
///
/// - 纯文本，**追加不轮转**；一行一条，异常从第二行起是堆栈
/// - 不引日期格式化库：`DateTime.toIso8601String()` 够用
/// - **写日志失败绝不影响主流程** —— 全部 `try/catch` 吞掉（磁盘满、目录被设只读时，
///   程序该跑还得跑）
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_config.dart';

/// 日志文件名。**中文名**：用户要能在资源管理器里一眼找到它。
const String logFileName = '神算子-日志.txt';

/// 日志目录名（配置文件的兄弟目录）
const String logFolderName = '日志';

/// 日志行前缀：本地时间 + 级别。
///
/// ⚠️ 用**本地时间**而不是 UTC：看日志的是用户和客服，他们要对照「我什么时候出的问题」。
String formatLogLine(DateTime now, String level, String message) {
  final String clock = now.toIso8601String();
  return '[$clock] [$level] $message';
}

/// 最小日志写入器。**只在启动与崩溃时用**，不做分级、不做轮转。
class AppLog {
  AppLog({required this.directory, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// 日志目录 = **配置文件的兄弟目录下的 `日志/`**（见文件头说明）。
  ///
  /// 生产环境因此自动是 `%APPDATA%\神算子\日志\`；
  /// 测试里 `configStore` 指沙箱时，日志也自动落在沙箱里。
  factory AppLog.besideConfig(AppConfigStore configStore) => AppLog(
    directory: Directory(
      p.join(configStore.file.parent.path, logFolderName),
    ),
  );

  /// 日志目录（`null` 状态的 AppLog 不存在 —— 目录总是算得出来）
  final Directory directory;

  final DateTime Function() _now;

  /// 日志文件
  File get file => File(p.join(directory.path, logFileName));

  /// 记一条启动信息：**启动时间 + 版本号 + 操作系统**（§AG-5 裁定的三项）。
  ///
  /// 至于「数据格式版本」：它回答的是「用户的库是哪一代」，排障第一问。
  void startup({
    required String appVersion,
    String? schemaVersion,
    String? osVersion,
  }) {
    final String os = osVersion ?? Platform.operatingSystemVersion;
    final String schema = schemaVersion == null
        ? ''
        : ' · schema v$schemaVersion';
    write('启动 神算子 v$appVersion$schema · $os');
  }

  /// 记一次崩溃 / 未捕获异常（**完整堆栈** —— 没有堆栈的日志等于没写）。
  void crash(Object error, StackTrace stack, {String label = '未捕获异常'}) {
    write('$label：$error\n$stack');
  }

  /// 底层写入。**永不抛异常**（写日志失败不能拖垮程序）。
  void write(String message, {String level = '信息'}) {
    try {
      if (!directory.existsSync()) directory.createSync(recursive: true);
      file.writeAsStringSync(
        '${formatLogLine(_now(), level, message)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 故意吞掉：磁盘满、目录只读、权限不足 —— 都不是「该让程序停下来」的理由
    }
  }
}
