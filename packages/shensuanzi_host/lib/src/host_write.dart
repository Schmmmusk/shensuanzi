/// 主机身份文件（`host.json`）的**写入策略与诊断** —— 2026-10-31 用户裁定
/// （`docs/reply.md`，提案 56 的批复）。
///
/// ## 为什么单独一个文件
///
/// 真机上 `host.json` 写不进去（`PathAccessException ... errno = 5`），
/// 而同目录的 `shensuanzi.db` 整天在写 —— 说明**不是**「这个目录没权限」。
/// 但「不是没权限」也只是推断，所以裁定要求两件事一起做：
///
/// 1. **诊断**：下次失败时，日志要能准确说出**失败在哪一步**；
/// 2. **兜底**：L1（临时文件 + rename）→ **L2（原地重写）** → L3（内存令牌），
///    且 L2 必须有**故障注入**测试，不能只测正常写入。
///
/// ## 三级降级（裁定原文「有条件批准 L2」）
///
/// | 级 | 做法 | 什么时候用 |
/// |---|---|---|
/// | L1 | 写 `.tmp` → `rename` 覆盖 | 首选（原子） |
/// | L2 | 读旧内容 → 截断 → 写 → flush，失败用旧内容写回 | L1 失败 |
/// | L3 | 只活在本进程内存里 | L2 也失败 |
///
/// ⚠️ **L2 不是无风险的**（裁定原文）：截断后崩溃 / 断电 / 恢复写入也失败，
/// 都可能留下空文件或不完整 JSON。所以：
///
/// - 恢复写入的**结果要记**（成功 / 失败都进 [HostWriteReport]）；
/// - **不许**对外宣称「完全可靠的回滚」；
/// - **不许**假设 L2 一定能绕过文件占用 —— 它以不允许写入的共享模式被打开时一样失败。
///
/// ## 为什么要有 [HostWriteIo]
///
/// 裁定要求 L2 补故障注入测试（打开失败 / 截断后写入失败 / 写入中进程退出 /
/// flush 失败 / L2 失败降级 L3）。真实文件系统上造不出「截断成功、写入失败」，
/// 所以把**每一步文件操作**抽成接口，测试注入会失败的那一步。
library;

import 'dart:io';

/// 写入最终落在哪一级。
enum HostWriteLevel {
  /// L1：临时文件 + rename（原子）
  rename,

  /// L2：原地重写（截断 → 写 → flush）
  inPlace,

  /// L3：只在内存里
  memory,
}

/// 一次写入尝试的**现场**（只进日志，不进界面）。
class HostWriteReport {
  HostWriteReport({
    required this.level,
    required this.target,
    required this.temp,
    required this.targetExisted,
    required this.steps,
    required this.retries,
    this.stage,
    this.errno,
    this.parentWritable,
    this.attrs,
    this.integrity,
    this.restoreOutcome,
  });

  /// 最终落在哪一级
  HostWriteLevel level;

  /// 失败发生在哪一步（成功时为 `null`）
  String? stage;

  /// 原始系统错误码（`PathAccessException.osError.errorCode`）
  int? errno;

  final String target;
  final String temp;

  /// **操作前**目标文件是否存在 —— 首次创建与覆盖已有文件是两种不同情况
  bool targetExisted;

  /// 有序的每步结果（裁定要求：不能只记最终异常）
  ///
  /// 形如 `temp-written` / `temp-flushed` / `rename-ok` / `rename-failed:5`
  final List<String> steps;

  /// 每次重试的结果
  final List<String> retries;

  /// 父目录能不能新建文件（写一个探针再删）
  bool? parentWritable;

  /// Windows 文件属性（`attrib` 的第一列，如 `A` / `A R`）
  String? attrs;

  /// 进程完整性级别（`whoami /groups` 的 Mandatory Label；拿不到就是 `null`）
  String? integrity;

  /// L2 恢复旧内容的**结果**（`null` = 没走到 L2 或无需恢复）
  String? restoreOutcome;

  bool get ok => level != HostWriteLevel.memory && stage == null;

  /// 一行日志（便于 grep；不含用户可见文案）
  String toLogLine() {
    final StringBuffer out = StringBuffer()
      ..write('host.json 写入 level=${level.name}')
      ..write(' ok=$ok');
    if (stage != null) out.write(' stage=$stage');
    if (errno != null) out.write(' errno=$errno');
    out
      ..write(' targetExisted=$targetExisted')
      ..write(' target=${_short(target)}')
      ..write(' steps=${steps.join(',')}');
    if (retries.isNotEmpty) out.write(' retries=${retries.join(',')}');
    if (parentWritable != null) out.write(' parentWritable=$parentWritable');
    if (attrs != null) out.write(' attrs=$attrs');
    if (integrity != null) out.write(' integrity=$integrity');
    if (restoreOutcome != null) out.write(' restore=$restoreOutcome');
    return out.toString();
  }

  static String _short(String path) => '$path(${path.length})';
}

/// 写入用到的文件操作（**测试注入故障的接缝**）。
abstract class HostWriteIo {
  const HostWriteIo();

  bool exists(File file);
  void writeString(File file, String text);
  void rename(File from, File to);
  String readString(File file);
  void truncateAndWrite(File file, String text);
  void delete(File file);
  void createParent(File file);
}

/// 生产实现：`dart:io`。
class RealHostWriteIo extends HostWriteIo {
  const RealHostWriteIo();

  @override
  bool exists(File file) => file.existsSync();

  @override
  void writeString(File file, String text) =>
      file.writeAsStringSync(text, flush: true);

  @override
  void rename(File from, File to) => from.renameSync(to.path);

  @override
  String readString(File file) => file.readAsStringSync();

  @override
  void truncateAndWrite(File file, String text) {
    // `writeAsStringSync` 的默认 mode 就是「打开即截断」
    file.writeAsStringSync(text, flush: true);
  }

  @override
  void delete(File file) {
    if (file.existsSync()) file.deleteSync();
  }

  @override
  void createParent(File file) => file.parent.createSync(recursive: true);
}

/// 把 [text] 写进 [target]：**L1 → L2 → L3**，并把现场记进 [report]。
///
/// 返回值 = 实际落在哪一级（调用方据此决定要不要提示「只对这次运行有效」）。
HostWriteReport writeIdentityFile({
  required File target,
  required String text,
  required HostWriteReport report,
  HostWriteIo io = const RealHostWriteIo(),
  int attempts = 3,
  Duration Function(int attempt)? backoff,
}) {
  final File temp = File('${target.path}.tmp');

  // ---------------------------------------------------------------- L1
  report.targetExisted = io.exists(target);
  try {
    io.createParent(target);
    report.steps.add('parent-ok');
  } catch (error) {
    report
      ..stage = 'create-parent'
      ..errno = _errno(error);
    report.steps.add('parent-failed:${_errno(error)}');
    // 父目录都建不了 ⇒ L2/L3 也没戏（L3 由调用方兜）
    report.level = HostWriteLevel.memory;
    return report;
  }

  for (int attempt = 0; attempt < attempts; attempt++) {
    // ⚠️ **两步分开记**（裁定原文：「不能只记录最终异常」）——
    // 「临时文件创建/写入失败」与「替换目标文件失败」的调查方向完全不同：
    // 前者是磁盘/权限，后者多半是目标被别的进程占着。
    try {
      io.writeString(temp, text);
      report.steps.add('temp-written');
    } catch (error) {
      final int? code = _errno(error);
      report
        ..stage = 'write-temp'
        ..errno = code;
      report.steps.add('temp-write-failed:${code ?? '?'}');
      report.retries.add('attempt$attempt:write-temp:${code ?? '?'}');
      final Duration wait =
          backoff?.call(attempt) ??
          Duration(milliseconds: 60 * (attempt + 1));
      if (wait > Duration.zero) sleep(wait);
      continue;
    }

    try {
      io.rename(temp, target);
      report.steps.add('rename-ok');
      report.level = HostWriteLevel.rename;
      report
        ..stage = null
        ..errno = null;
      return report;
    } catch (error) {
      final int? code = _errno(error);
      report
        ..stage = 'rename'
        ..errno = code;
      report.steps.add('rename-failed:${code ?? '?'}');
      report.retries.add('attempt$attempt:rename:${code ?? '?'}');
      final Duration wait =
          backoff?.call(attempt) ??
          Duration(milliseconds: 60 * (attempt + 1));
      if (wait > Duration.zero) sleep(wait);
    }
  }

  // ---------------------------------------------------------------- L2
  // 裁定原文：L2 值得尝试，但**不许**假设它一定能绕过文件占用；
  // 也**不许**把「读旧内容、失败再写回」说成完全可靠的回滚。
  String? previous;
  try {
    previous = io.exists(target) ? io.readString(target) : null;
    report.steps.add('old-read:${previous == null ? 'none' : previous.length}');
  } catch (error) {
    report.steps.add('old-read-failed:${_errno(error)}');
    // 读不出旧内容也能试一次原地写（最坏结果与 L3 相同：重启后要重新生成码）
    previous = null;
  }

  try {
    io.truncateAndWrite(target, text);
    report.steps.add('inplace-written');
    report.level = HostWriteLevel.inPlace;
    report
      ..stage = null
      ..errno = null;
    return report;
  } catch (error) {
    report.steps.add('inplace-failed:${_errno(error)}');
    report
      ..stage = 'in-place-write'
      ..errno = _errno(error);
  }

  // L2 半途而废 ⇒ 尽力把旧内容写回去，**并记录结果**（不许声称一定成功）
  if (previous != null) {
    try {
      io.truncateAndWrite(target, previous);
      report.restoreOutcome = 'ok';
    } catch (error) {
      report.restoreOutcome = 'failed:${_errno(error)}';
    }
  } else {
    report.restoreOutcome = 'nothing-to-restore';
  }

  // ---------------------------------------------------------------- L3
  report.level = HostWriteLevel.memory;
  io.delete(temp);
  return report;
}

/// 收集**只在失败时**才值得取的那几样（都会落盘/起进程，平时不跑）。
void collectEnvironment(HostWriteReport report, File target) {
  // 父目录能不能新建文件（写个探针再删）
  try {
    final File probe = File(
      '${target.parent.path}${Platform.pathSeparator}.probe-${DateTime.now().microsecondsSinceEpoch}',
    );
    probe.writeAsStringSync('x');
    probe.deleteSync();
    report.parentWritable = true;
  } catch (_) {
    report.parentWritable = false;
  }

  // Windows 文件属性（`attrib` 第一列：A / A R / A S …）
  if (Platform.isWindows) {
    try {
      final ProcessResult r = Process.runSync('attrib', <String>[target.path]);
      final String out = '${r.stdout}'.trim();
      if (out.isNotEmpty) {
        report.attrs = out.split(RegExp(r'\s{2,}')).first.trim();
      }
    } catch (_) {
      // 拿不到就不记
    }
    // 进程完整性级别（`whoami /groups` 的 Mandatory Label）
    //
    // ⚠️ 输出是**本地化**的（中文系统写「强制标签」），所以两种都认；
    // 认不出就留 null —— 不猜。
    try {
      final ProcessResult r = Process.runSync('whoami', <String>['/groups']);
      final String out = '${r.stdout}';
      for (final String key in <String>['Mandatory Label', '强制标签']) {
        final int at = out.indexOf(key);
        if (at >= 0) {
          report.integrity = out
              .substring(at)
              .split('\n')
              .first
              .replaceAll(key, '')
              .trim();
          break;
        }
      }
    } catch (_) {
      // 拿不到就不记
    }
  }
}

int? _errno(Object error) {
  if (error is FileSystemException) return error.osError?.errorCode;
  return null;
}
