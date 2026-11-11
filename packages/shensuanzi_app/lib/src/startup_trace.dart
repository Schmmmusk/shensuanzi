/// 启动耗时埋点（**编译期开关**，正式包零成本）。
///
/// ## 为什么是编译期常量（2026-10-28 用户裁定「甲」）
///
/// ```bash
/// flutter build windows --release --dart-define=SSZ_STARTUP_TRACE=true
/// ```
///
/// `const bool.fromEnvironment(...)` 在**编译期**求值：不传这个 define 时
/// [kStartupTrace] 是 `false`，于是所有 `if (!kStartupTrace) return;` 与
/// `kStartupTrace ? … : …` 都会被常量折叠 + tree shaking **整段抠掉** ——
/// 正式包里连一个字节的机器码都不留，运行时零分支、零开销。
///
/// 为什么不选「运行时读环境变量」：Windows 用户是**双击 exe** 启动的，
/// 让他去改环境变量不现实；而且那段读取代码会永久留在包里。
/// 为什么不选 `kDebugMode`：debug 是 JIT，与 release（AOT）的启动/渲染特性
/// 差一个量级，debug 下测出来的数**解释不了真机**。
///
/// ## ⚠️ 埋点自己不许拖慢启动（用户 2026-10-28 点名）
///
/// 打点只做一件事：**往内存里塞一个整数**（`Stopwatch.elapsedMilliseconds`）。
/// **绝不在 `main()` 里同步写盘** —— 否则「启动 4 秒」里有一半是埋点自己造成的。
/// 落盘统一在**首帧之后**、用异步 `writeAsString` 一次写完（[flushStartup]）。
///
/// ## 六个点位
///
/// | 点位 | 位置 | 慢了说明什么 |
/// |---|---|---|
/// | `T0_main` | `main()` 第一行 | 到 `main` 之前的加载器 / 引擎开销 |
/// | `T1_run_app` | `runApp` 之前 | 绑定初始化 + 日志 + 环境探测 |
/// | `T2_db_open` | `Db.open` 返回（含迁移） | 开库 / WAL 恢复 / 迁移 |
/// | `T3_services` | 服务构造完（自动备份判定之前） | 启动期的准备工作 |
/// | `T4_first_frame` | 首帧绘制完 | **Widget 树构建 + 布局 + 光栅** |
/// | `T5_page` | 每次切页（进入 → 该页首帧） | 单页构建成本；对比第 1 次与第 2 次 |
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 埋点总开关。**编译期常量**：不传 `--dart-define=SSZ_STARTUP_TRACE=true` 时恒 `false`。
const bool kStartupTrace = bool.fromEnvironment('SSZ_STARTUP_TRACE');

/// 时间戳收集器。**只碰内存**，落盘见 [flushStartup]。
class StartupTrace {
  StartupTrace._();

  /// 从**第一次打点**开始计时 —— 所以 `T0_main` 恒为 0 ms。
  static final Stopwatch _clock = Stopwatch()..start();

  static final List<Map<String, Object?>> _marks = <Map<String, Object?>>[];

  /// 本次打开的库（路径 + MB）。
  ///
  /// ⚠️ 2026-10-28 第二次实跑踩到：用户这次开的是**小库**（单据页 4 ms），
  /// 而性能问题是 478 MB 那个库。埋点里不记库，两轮数据根本分不清 ——
  /// 所以补上。路径不是经营数据（与崩溃日志同口径，可以记）。
  static String? _dbPath;
  static double? _dbMb;

  /// 开库之后调一次。
  ///
  /// ⚠️ **顺手把落盘位置也定下来**（2026-11-01 真机发现埋点一直是哑的）：
  /// [defaultFile] 靠 `Platform.environment['APPDATA']`，那是 Windows 的写法；
  /// Android 上它为空 ⇒ 退回 `Directory.systemTemp`，而 Android 上那是
  /// `/tmp`（不存在、也不可写）⇒ 写盘抛异常、被 [flushStartup] 的 catch 吞掉
  /// ⇒ **一行记录都不会有**。所以改成「跟着数据库走」：库在数据目录里，
  /// `日志/` 是它的兄弟目录，两端都成立。
  static void noteDatabase(String path, double? sizeMb) {
    if (!kStartupTrace) return;
    _dbPath = path;
    _dbMb = sizeMb;
    _file = traceFileFor(path);
  }

  /// 落盘路径：**跟着数据库走** —— `<数据目录>/日志/startup-trace.jsonl`。
  ///
  /// 纯函数（可测）：Android 上没有 `APPDATA`，只能靠「库在哪、日志就在它旁边」。
  static File traceFileFor(String databasePath) =>
      File(p.join(p.dirname(databasePath), '日志', 'startup-trace.jsonl'));

  /// 本次进程的记录文件（首帧后第一次 flush 时才真正创建）。
  static File? _file;

  /// 打过的时间戳（按顺序）。测试用；生产里只有 `flushStartup` 读它。
  static List<Map<String, Object?>> get marks =>
      List<Map<String, Object?>>.unmodifiable(_marks);

  /// 打一个点。**开关关着时是空操作**（编译期折叠，连调用都不会留）。
  ///
  /// ⚠️ `T3_services` 会**立刻**触发落盘 —— 它是启动阶段的最后一点。
  /// 但 `T2/T3` 在本 App 里发生在**首帧之后**（数据库是异步打开的，
  /// 实测 T4=23 ms、T3 在 6 秒后），所以落盘绝不能挂在 T4 上
  /// （2026-10-28 第一次跑就漏了 T2/T3）。
  static void mark(String name) {
    if (!kStartupTrace) return;
    _marks.add(<String, Object?>{
      'name': name,
      'ms': _clock.elapsedMilliseconds,
    });
    if (name == _lastStartupMark) {
      _flushTimer?.cancel();
      _flushTimer = null;
      unawaited(flushStartup());
    }
  }

  /// 启动阶段的最后一个点位：到它就落盘。
  /// ⚠️ 必须是**最后一个**点位。2026-10-28 第四轮实跑发现：改成 `T3_services`
  /// 触发落盘后，紧跟其后的 `T3b_backup_status` **永远写不进去**（先写了才打点）。
  /// 现在由 `T3b` 触发；它若没到（中途抛异常），靠 [flushAfterFirstFrame] 的 10 秒兜底。
  static const String _lastStartupMark = 'T3b_backup_status';

  static Timer? _flushTimer;

  /// 首帧之后调用：**等 10 秒**再落盘（给 T2/T3 留时间）。
  ///
  /// 为什么不是立刻写：本 App 的首帧只是**空壳**（23 ms 就画完了），
  /// 真正的内容要等数据库打开。立刻写会漏掉 T2/T3，等于白埋。
  /// 若 T3 先到，[mark] 会取消这个兜底定时器并立刻写。
  static void flushAfterFirstFrame() {
    if (!kStartupTrace) return;
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(seconds: 10), () {
      unawaited(flushStartup());
    });
  }

  /// 默认落点：`%APPDATA%\神算子\日志\startup-trace.jsonl`（与崩溃日志同目录）。
  ///
  /// 拿不到 `APPDATA`（非 Windows / 精简环境）时退回系统临时目录 ——
  /// 埋点不该因为找不到目录就抛异常（它是诊断工具，不是功能）。
  static File defaultFile() {
    final String? appData = Platform.environment['APPDATA'];
    final String base = (appData == null || appData.isEmpty)
        ? Directory.systemTemp.path
        : appData;
    return File(p.join(base, '神算子', '日志', 'startup-trace.jsonl'));
  }

  /// 把**启动阶段**的时间戳一次写进文件（异步、不阻塞）。
  ///
  /// 只在首帧之后调一次。文件**整份重写**（每次启动一行新的 summary），
  /// 这样同一个文件里可以横向比较多次启动。
  static Future<void> flushStartup({File? file}) async {
    if (!kStartupTrace || _marks.isEmpty) return;
    final File target = file ?? _file ?? defaultFile();
    _file = target;
    // ⚠️ **半条记录要自曝**（2026-11-10 第二次真机冷启动）：10 秒兜底定时器会在
    // 「库还没打开」时先把已有的点写出去 —— 那条记录缺 `T2_db_open`，
    // 而且因为 `noteDatabase` 还没跑，它会落到 `%APPDATA%` 那份文件里
    // （数据目录那份没有它）。缺了 T2 却被当成"开库很快"，就是误读。
    final bool partial = !_marks.any(
      (Map<String, Object?> m) => m['name'] == 'T2_db_open',
    );
    final String line = startupLine(
      _marks,
      DateTime.now(),
      db: _dbPath,
      dbMb: _dbMb,
      host: Platform.localHostname,
      partial: partial,
    );
    try {
      await target.parent.create(recursive: true);
      // ⚠️ **必须补换行**：JSONL 靠换行分条。2026-10-28 第三次实跑发现
      // 三条记录粘成一行（`{...}{...}`），任何按行解析的脚本都会炸。
      await target.writeAsString(
        '$line\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (_) {
      // 埋点失败绝不影响软件运行（目录只读 / 磁盘满都会走到这里）
    }
  }

  /// 记一行「**这次到底打开了哪个文件、它多大**」—— 独立于 `startup` 行。
  ///
  /// ## 为什么需要它（2026-11-11 真机）
  ///
  /// `startup` 行的 `db` / `dbMb` 出现了**自相矛盾**的证据：库确实是 **498 MiB**
  /// （造数与启动是独立事件，用户确认），而 `dbMb` 报 **0.0**。更糟的是那几行的
  /// **行首被截断**，`"db"` 字段整个丢了 ⇒ 事后**无法反查是哪条路径**。
  ///
  /// 所以这里刻意做三件事：
  ///
  /// 1. **单独一行**（`kind` = `dbprobe`）：不依附 `startup` 行，被截断也不影响判读；
  /// 2. **两条独立途径读同一个大小**（`lengthSync` 与 `statSync().size`）：
  ///    两者不一致 ⇒ API / 过滤驱动读错；一致且为 0 ⇒ 文件真小；
  /// 3. 记**前 16 字节**（正常库是 `SQLite format 3\0`）：
  ///    能区分「空文件」与「根本不是库」。
  ///
  /// 另外记同目录下所有 `shensuanzi.db*` 的大小 —— 能看出是否另有一个 0 字节的同名库。
  ///
  /// 开销：一次 `stat` + 一次 16 字节读，微秒级；**只在开关打开时执行**。
  static void flushDbProbe(String dbPath) {
    if (!kStartupTrace) return;
    final File target = _file ?? defaultFile();
    unawaited(_appendLine(target, dbProbeLine(dbPath, DateTime.now())));
  }

  /// 往 JSONL 追加一行（**失败吞掉**）。埋点绝不许拖累软件。
  static Future<void> _appendLine(File target, String line) async {
    try {
      await target.parent.create(recursive: true);
      await target.writeAsString(
        '$line\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (_) {
      // 目录只读 / 磁盘满 / 库被挪走都会走到这里
    }
  }

  /// 记一次切页（进入 → 该页首帧的毫秒数）。异步追加，不阻塞。
  static Future<void> appendSwitch(String page, int ms, {File? file}) async {
    if (!kStartupTrace) return;
    final File target = file ?? _file ?? defaultFile();
    _file = target;
    try {
      await target.parent.create(recursive: true);
      await target.writeAsString(
        '${pageLine(page, ms, DateTime.now())}\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (_) {
      // 同上：诊断工具，失败不抛
    }
  }

  /// 记一次「**页面稳定**」（2026-10-28 第五轮）。
  ///
  /// 与 [appendSwitch] 的区别：那个记「首帧画完」（下限），这个记
  /// 「静默 500 ms / 到达硬上限」（上限）。用户体感对应的是后者。
  static Future<void> appendSettled({
    required String page,
    required int firstMs,
    required int settledMs,
    required int frames,
    required bool timedOut,
    File? file,
  }) async {
    if (!kStartupTrace) return;
    final File target = file ?? _file ?? defaultFile();
    _file = target;
    try {
      await target.parent.create(recursive: true);
      await target.writeAsString(
        '${settledLine(page: page, firstMs: firstMs, settledMs: settledMs, frames: frames, timedOut: timedOut)}\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (_) {
      // 诊断工具，失败不抛
    }
  }

  /// 清空内存里的记录（**只给测试用**；生产进程里不需要重置）。
  static void resetForTest() {
    _marks.clear();
    _file = null;
    _clock
      ..reset()
      ..start();
  }
}

/// 拼一行「启动汇总」的 JSON（**纯函数**，单测直接喂数据）。
///
/// 抽出来的理由：开关是编译期常量，测试里打不开 —— 但**格式**必须能测
/// （写歪了现场解析不出来，比没有埋点更糟）。
String startupLine(
  List<Map<String, Object?>> marks,
  DateTime now, {
  String? db,
  double? dbMb,
  String? host,
  bool partial = false,
}) {
  final StringBuffer buffer = StringBuffer()
    ..write('{"kind":"startup","ts":"')
    ..write(now.toIso8601String())
    ..write('"');
  // `partial: true` = 这条记录**缺 T2_db_open**（10 秒兜底先落盘，库还没开完）。
  // 没有这个标记，缺 T2 的记录会被读成「开库快到没打点」——正好反了。
  if (partial) buffer.write(',"partial":true');
  // 库信息放在 marks 之前：现场第一眼要看的就是「这次测的是哪个库」
  // ⚠️ 注意引号：`ts` 已经收尾了，这里每段都要**自带前导逗号**；
  // 第一版写成 `","db":"`（多了个引号）⇒ 生成 `478.1","marks"` 非法 JSON。
  if (db != null) {
    buffer
      ..write(',"db":"')
      ..write(db.replaceAll('\\', '/'))
      ..write('","dbMb":')
      ..write(dbMb?.toStringAsFixed(1) ?? 'null');
  }
  // 机器名：2026-10-28 用户指正 —— 「8 秒」是第一台机器凭回忆记的、没有埋点，
  // 而这次跑的是另一台。不记机器名，两份数据永远对不上号。
  if (host != null) {
    buffer
      ..write(',"host":"')
      ..write(host)
      ..write('"');
  }
  buffer.write(',"marks":[');
  for (int i = 0; i < marks.length; i++) {
    if (i > 0) buffer.write(',');
    buffer
      ..write('{"name":"')
      ..write(marks[i]['name'])
      ..write('","ms":')
      ..write(marks[i]['ms'])
      ..write('}');
  }
  buffer.write(']}');
  return buffer.toString();
}

/// 拼一行「**库探针**」的 JSON（纯函数：读盘的部分也放在里面，但每个字段各自 `try`）。
///
/// 为什么「两条途径读同一个大小」：2026-11-11 真机上 `lengthSync()` 报 0，
/// 而库实际是 498 MiB —— 必须能分辨是「文件真小」还是「这个 API 读错了」。
/// 两条途径一致 ⇒ 可信；不一致 ⇒ 是读法/驱动的问题。
String dbProbeLine(String dbPath, DateTime now) {
  final File f = File(dbPath);

  int? lengthBytes;
  try {
    lengthBytes = f.existsSync() ? f.lengthSync() : null;
  } catch (_) {
    lengthBytes = null;
  }

  int? statBytes;
  String statType = '?';
  String statModified = '?';
  try {
    final FileStat st = f.statSync();
    // ⚠️ `statSync()` 对**不存在的文件不抛异常** —— 它返回 `type = notFound, size = 0`。
    // 不把 size 置 null，"文件根本不在"就会被读成"空库"，
    // 而「分辨这两件事」正是这个探针存在的理由（2026-11-11 的 `dbMb: 0.0`）。
    if (st.type == FileSystemEntityType.notFound) {
      statBytes = null;
      statType = 'notFound';
    } else {
      statBytes = st.size;
      statType = st.type.toString().split('.').last;
      statModified = st.modified.toIso8601String();
    }
  } catch (_) {
    statBytes = null;
  }

  // 前 16 字节：正常 SQLite 库是 "SQLite format 3\0"
  List<int>? head;
  try {
    if (f.existsSync()) {
      final RandomAccessFile raf = f.openSync();
      try {
        head = raf.readSync(16);
      } finally {
        raf.closeSync();
      }
    }
  } catch (_) {
    head = null;
  }

  // 同目录下所有 `shensuanzi.db*`（库 / -wal / -shm / 另一个同名库）
  final List<String> siblings = <String>[];
  try {
    final Directory dir = f.parent;
    if (dir.existsSync()) {
      for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
        final String name = p.basename(e.path);
        if (!name.startsWith('shensuanzi.db')) continue;
        int size = -1;
        try {
          size = e.statSync().size;
        } catch (_) {
          size = -1;
        }
        siblings.add('$name:$size');
      }
      siblings.sort();
    }
  } catch (_) {
    // 目录不可读：留空数组也比抛异常好
  }

  final StringBuffer buffer = StringBuffer()
    ..write('{"kind":"dbprobe","ts":"')
    ..write(now.toIso8601String())
    ..write('","db":"')
    ..write(dbPath.replaceAll('\\', '/'))
    ..write('","lengthSync":')
    ..write(lengthBytes ?? 'null')
    ..write(',"statBytes":')
    ..write(statBytes ?? 'null')
    ..write(',"statType":"')
    ..write(statType)
    ..write('","statModified":"')
    ..write(statModified)
    ..write('","head":')
    ..write(head == null ? 'null' : jsonEncode(head))
    ..write(',"siblings":')
    ..write(jsonEncode(siblings))
    ..write('}');
  return buffer.toString();
}

/// 拼一行「切页」的 JSON（纯函数）。
String pageLine(String page, int ms, DateTime now) =>
    '{"kind":"page","ts":"${now.toIso8601String()}",'
    '"page":"$page","ms":$ms}';

/// 拼一行「页面稳定」的 JSON（纯函数）。
///
/// `firstMs` = 首帧；`settledMs` = 静默判定时刻；`frames` = 这段时间画了几帧。
/// `timedOut` = 一直没静下来（转圈 / 动画），被 10 秒硬上限截断。
String settledLine({
  required String page,
  required int firstMs,
  required int settledMs,
  required int frames,
  required bool timedOut,
}) =>
    '{"kind":"settled","ts":"${DateTime.now().toIso8601String()}",'
    '"page":"$page","firstMs":$firstMs,"settledMs":$settledMs,'
    '"frames":$frames,"timedOut":$timedOut}';
