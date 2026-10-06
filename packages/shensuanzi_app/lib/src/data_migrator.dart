/// 数据位置迁移执行器（§BK·三，2026-10-05 裁定落地）。
///
/// ## 职责边界
///
/// **只做文件搬迁**：算计划 → 拷到带 UUID 的暂存目录 → 原子改名 → 在旧目录写说明文件。
/// 「停 host / 关库 / 更新 config / 重开库」是**应用层的事**（`app.dart`）——
/// 顺序错了会死锁，放在这里谁都能误用。
///
/// ## 裁定的七条工程细节在本文件的落点
///
/// | 裁定 | 落点 |
/// |---|---|
/// | ① 空间校验算全（数据 + 备份 + 100 MB 余量） | [plan] 的 [MigrationPlan.requiredBytes]（应用层拿它对目标盘剩余空间比） |
/// | ④ 说明文件含恢复指引 | [_legacyNoteText] —— **「在确认新位置工作正常之前，请勿删除」**是原文 |
/// | ⑦ 失败退路有保护（不误删用户文件） | 暂存目录 `<目标>.migrating-<uuid>`（目标的**兄弟**，同盘 ⇒ 改名原子）；失败只删它，用户已有文件永不碰 |
///
/// ②（等同步/事务结束）③（进度反馈）⑤（config 位置）⑥（导出不动）在 `app.dart` 与调用方注释里。
///
/// ## 为什么导出目录不搬
///
/// 「神算子导出」里是**用户主动导出的文件**（给会计的 CSV），不是系统管理的数据；
/// 自动搬动它 = 动用户的文件。若它恰好在数据目录**内部**，会随目录整体被拷走
/// —— 那是物理事实，不是主动行为（裁定 ⑥ 的原文区分）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'instance_lock.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart' show newId;

/// 一次迁移的**计划**（执行前算好，给确认对话框与空间校验用）。
class MigrationPlan {
  const MigrationPlan({
    required this.from,
    required this.to,
    required this.fileCount,
    required this.byteCount,
  });

  /// 旧数据目录
  final String from;

  /// 新数据目录
  final String to;

  /// 数据目录 + 备份目录的**文件总数**（不含目录本身）
  final int fileCount;

  /// 数据目录 + 备份目录的**总字节数**
  final int byteCount;

  /// 目标盘需要的空间 = 数据 + 备份 + **100 MB 余量**（裁定 ①：
  /// 备份目录可能有 30 天自动备份 + 手动包，只算数据目录会炸）。
  static const int safetyMarginBytes = 100 * 1024 * 1024;

  int get requiredBytes => byteCount + safetyMarginBytes;
}

/// 迁移进度（给全屏遮罩的进度反馈 —— 裁定 ③：死等会让用户强杀进程）。
class MigrationProgress {
  const MigrationProgress({required this.filesCopied, required this.totalFiles});

  /// 已拷贝的文件数
  final int filesCopied;

  /// 总文件数（来自 [MigrationPlan.fileCount]）
  final int totalFiles;

  /// 0.0 ~ 1.0；总数为 0 时恒 1（空库也能迁）
  double get fraction => totalFiles == 0 ? 1 : (filesCopied / totalFiles).clamp(0.0, 1.0);
}

/// 迁移结果。**失败时旧目录一定原样**（见 [DataMigrator.execute] 的退路）。
class DataMigrationResult {
  const DataMigrationResult.ok(this.legacyNotePath)
    : error = null;

  const DataMigrationResult.failed(this.error) : legacyNotePath = null;

  bool get ok => error == null;

  /// 失败原因（给用户的原话；成功为 `null`）
  final String? error;

  /// 旧目录里说明文件的路径（成功才有）
  final String? legacyNotePath;
}

/// 迁移执行器。
///
/// 测试注入 [debugFailCopyFor]：对匹配路径的文件返回 `true` ⇒ 拷它时抛异常
/// —— 真实机器上造不出「拷贝到一半失败」，只能注入（与 `driveEnumerator` 同款思路）。
class DataMigrator {
  DataMigrator({
    required this.dataDirectory,
    required this.backupDirectory,
    required this.newDataDirectory,
    required this.newBackupDirectory,
    this.debugFailCopyFor,
  });

  /// 旧数据目录（含 db / WAL / 标记文件 / host.json）
  final String dataDirectory;

  /// 旧备份目录（数据目录的兄弟「神算子备份」）
  final String backupDirectory;

  /// 新数据目录（**必须不存在或为空** —— 应用层在选位置时校验）
  final String newDataDirectory;

  /// 新备份目录（新数据目录的兄弟，与旧布局同构）
  final String newBackupDirectory;

  /// 测试钩子：对某路径返回 `true` ⇒ 拷它时失败
  final bool Function(String path)? debugFailCopyFor;

  /// 算计划：枚举数据 + 备份两棵树，数文件、累字节。
  ///
  /// ⚠️ 数据目录**不存在**（首启前）时本类不该被调用 —— 调用方保证。
  MigrationPlan plan() {
    int files = 0;
    int bytes = 0;
    // 与 `execute` 同口径：备份同位（没被搬）就不计入计划 —— 否则进度总数对不上
    final bool backupInPlace = _samePath(backupDirectory, newBackupDirectory);
    final List<String> roots = backupInPlace
        ? <String>[dataDirectory]
        : <String>[dataDirectory, backupDirectory];
    for (final String root in roots) {
      final Directory dir = Directory(root);
      if (!dir.existsSync()) continue; // 备份目录可能还没建过（从没备份过）
      files += _walk(dir, (final int size) => bytes += size);
    }
    return MigrationPlan(
      from: dataDirectory,
      to: newDataDirectory,
      fileCount: files,
      byteCount: bytes,
    );
  }

  /// 执行迁移。
  ///
  /// ## 序列（每一步的失败都走同一条退路：删暂存、旧目录原样）
  ///
  /// 1. 在**目标的兄弟**建暂存目录 `<新数据目录>.migrating-<uuid>`（裁定 ⑦：
  ///    带 UUID ⇒ 不会撞上用户已有文件夹；同盘 ⇒ 最后的改名是原子的）
  /// 2. 拷数据目录 → `<暂存>\`；拷备份目录 → `<新备份>.migrating-<uuid>\`
  ///    （每拷完一个文件回调 [onProgress] —— 裁定 ③）
  /// 3. 原子改名两个暂存目录为正式名字
  /// 4. 旧数据目录 + 旧备份目录各写一份说明文件（裁定 ④：含恢复指引）
  ///
  /// ## 退路
  ///
  /// 任何一步失败：删掉两个暂存目录（**只删它们**），返回 [DataMigrationResult.failed]。
  /// 旧目录与旧文件**从不删除、从不修改**（除了追加说明文件——成功后才写）。
  DataMigrationResult execute({void Function(MigrationProgress)? onProgress}) {
    final MigrationPlan plan = this.plan();
    // ⚠️ 新备份目录与旧备份目录**同位**（新数据目录与旧数据目录同级时必然：
    // 兄弟目录算法算出同一个「神算子备份」）—— 备份本来就在位，
    // **整个跳过搬迁**（拷了再改名会撞上已存在的旧备份，真机炸过 errno 183）
    final bool backupInPlace = _samePath(backupDirectory, newBackupDirectory);
    final String stagingData = '$newDataDirectory.migrating-${newId()}';
    final String stagingBackup = '$newBackupDirectory.migrating-${newId()}';
    try {
      int copied = 0;
      void report() {
        if (onProgress != null) {
          onProgress(MigrationProgress(filesCopied: copied, totalFiles: plan.fileCount));
        }
      }

      // 前置：**Windows 的 rename 不覆盖已存在路径**（errno 183，真机炸过）——
      // 目标已存在 ⇒ 只允许**空目录**，先删掉它腾位；有内容 ⇒ 明确失败
      //（正常流程到不了这里：选位置时已拒非空目标，这是执行器的自我防线）
      _prepareRenameTarget(newDataDirectory, '新数据目录');
      if (!backupInPlace) {
        _prepareRenameTarget(newBackupDirectory, '新备份目录');
      }

      Directory(stagingData).createSync(recursive: true);
      _copyTree(
        from: Directory(dataDirectory),
        to: Directory(stagingData),
        onFile: () {
          copied++;
          report();
        },
      );
      final Directory oldBackup = Directory(backupDirectory);
      if (!backupInPlace && oldBackup.existsSync()) {
        Directory(stagingBackup).createSync(recursive: true);
        _copyTree(
          from: oldBackup,
          to: Directory(stagingBackup),
          onFile: () {
            copied++;
            report();
          },
        );
      }

      // 原子改名（同盘同一父目录 ⇒ OS 级 rename；目标已在前置里腾空）
      Directory(stagingData).renameSync(newDataDirectory);
      if (!backupInPlace && Directory(stagingBackup).existsSync()) {
        Directory(stagingBackup).renameSync(newBackupDirectory);
      }

      // 说明文件 —— 成功后才写（失败时旧目录连一个字节都不该多）。
      // 备份同位时**不给旧备份目录写** —— 它没被迁走，仍是现役备份目录。
      final String notePath = _writeLegacyNote(
        directory: dataDirectory,
        newDataDirectory: newDataDirectory,
      );
      if (!backupInPlace) {
        _writeLegacyNote(directory: backupDirectory, newDataDirectory: newDataDirectory);
      }
      return DataMigrationResult.ok(notePath);
    } catch (error) {
      // 退路：只删**自己建的**暂存目录。用户在目标位置已有的任何文件不碰
      //（目标非空在选位置时就被拒了；这里连空的都不留——改名失败时清掉）
      _deleteIfExists(stagingData);
      _deleteIfExists(stagingBackup);
      return DataMigrationResult.failed('$error');
    }
  }

  /// 改名前置（errno 183 的防线）：目标不存在 ⇒ 放行；
  /// 是**空目录** ⇒ 删掉腾位（Windows rename 不覆盖已存在路径）；
  /// 有内容 ⇒ 明确失败（消息说人话，不做静默覆盖）。
  void _prepareRenameTarget(String path, String what) {
    final Directory dir = Directory(path);
    if (!dir.existsSync()) return;
    if (dir.listSync().isEmpty) {
      dir.deleteSync();
      return;
    }
    throw StateError('$what（$path）已存在且有内容');
  }

  /// 两个路径是否同一个位置（Windows 大小写不敏感，`path` 包按平台处理）。
  bool _samePath(String a, String b) =>
      p.equals(p.normalize(a), p.normalize(b));

  // ---------------------------------------------------------------- 内部

  /// 递归拷贝（保留相对结构）。[onFile] 每成功拷完一个**文件**回调一次。
  void _copyTree({
    required Directory from,
    required Directory to,
    required void Function() onFile,
  }) {
    for (final FileSystemEntity entity in from.listSync()) {
      final String target = p.join(to.path, p.basename(entity.path));
      if (entity is Directory) {
        Directory(target).createSync(recursive: true);
        _copyTree(from: entity, to: Directory(target), onFile: onFile);
      } else if (entity is File && !_skipOnMove(entity.path)) {
        final String sourcePath = entity.path;
        if (debugFailCopyFor != null && debugFailCopyFor!(sourcePath)) {
          throw StateError('模拟拷贝失败：$sourcePath');
        }
        entity.copySync(target);
        onFile();
      }
    }
  }

  /// 搬家时**跳过**的文件（§审查 OBS-14）。
  ///
  /// `.shensuanzi.lock` 是**本机运行态**文件：它正被当前进程**排他锁着**，
  /// 而 Windows 上带内容的被锁文件**拷不动**（实测 `errno 0`）；搬到新位置也
  /// 没有意义（那边会自己生成一个）。所以计划（[_walk]，算进度总数与所需空间）
  /// 与拷贝（[_copyTree]）**两处都要跳过** —— 少跳一处，进度总数就对不上。
  ///
  /// ⚠️ 本次实测它恰好是 0 字节、侥幸能拷 —— 但那是**巧合**，不是保证。
  static bool _skipOnMove(String path) =>
      p.basename(path) == instanceLockFileName;

  /// 遍历目录：对每个文件回调其大小，返回**文件数**（跳过 [_skipOnMove] 的）。
  int _walk(Directory dir, void Function(int bytes) onFile) {
    int count = 0;
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is Directory) {
        count += _walk(entity, onFile);
      } else if (entity is File && !_skipOnMove(entity.path)) {
        count++;
        onFile(entity.lengthSync());
      }
    }
    return count;
  }

  /// 旧目录里的说明文件（裁定 ④ 的**原文要求**：含恢复指引 ——
  /// 新位置坏了时，旧目录才是唯一完好的备份）。
  String _writeLegacyNote({
    required String directory,
    required String newDataDirectory,
  }) {
    final File note = File(
      p.join(directory, '已迁移-请先阅读.txt'),
    );
    note.writeAsStringSync(_legacyNoteText(newDataDirectory), flush: true);
    return note.path;
  }

  /// 说明文件内容。⚠️ 三条指引是裁定原文，改措辞前先对台账。
  String _legacyNoteText(String newDataDirectory) =>
      '神算子数据已迁移到：$newDataDirectory。\n'
      '此目录中的数据仍然完好。\n'
      '- 如果要继续在新位置使用，请删除此目录。\n'
      '- 如果新位置出问题（盘坏 / 误删），可以重新启动神算子并把此目录'
      '指定为数据位置，数据会立刻回来。\n'
      '- 在确认新位置工作正常之前，请勿删除此目录。\n';

  void _deleteIfExists(String path) {
    final Directory dir = Directory(path);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  }
}
