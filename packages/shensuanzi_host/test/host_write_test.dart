// `host.json` 写入的**三级降级 + 故障注入** —— 2026-10-31 用户裁定
// （提案 56 批复 §三「有条件批准 L2」）。
//
// ## 裁定原文的要求（逐条对应用例）
//
// | 故障时机 | 预期结果 | 用例 |
// |---|---|---|
// | 打开文件失败 | 旧文件保持完整 | 「截断前就失败」 |
// | 截断后写入失败 | 尽力恢复旧内容，记录恢复结果 | 「截断后失败 ⇒ 恢复旧内容」 |
// | 写入过程中进程异常退出 | 下次启动识别损坏文件、不崩 | `auth_test` 的「半截 JSON」 |
// | flush 失败 | 不得报告持久化成功 | 「写临时文件就失败」 |
// | L2 失败 | 正确降级到 L3 | 「L2 也失败 ⇒ 降级内存」 |
//
// ## 为什么要有假 IO
//
// 真实文件系统上造不出「截断成功、写入失败」「rename 返回 5」这些中间态。
// 把每一步文件操作抽成 `HostWriteIo`，就能精确地在**指定步骤**注入故障。
//
// 运行：`dart test`
import 'dart:io';

import 'package:shensuanzi_host/shensuanzi_host.dart';
import 'package:test/test.dart';

/// 内存文件系统 + 可编程故障。
class FakeIo extends HostWriteIo {
  FakeIo({
    this.failRename = false,
    this.failWriteTemp = 0,
    this.failTruncate = 0,
    this.failRead = false,
    this.failCreateParent = false,
  });

  final bool failRename;

  /// 前 N 次「写临时文件」失败（模拟 flush / 写盘失败）
  int failWriteTemp;

  /// 前 N 次「原地重写」失败（模拟截断后写入失败）
  int failTruncate;

  final bool failRead;
  final bool failCreateParent;

  final Map<String, String> files = <String, String>{};

  /// 每步调用记录（断言「到底走到哪一步」）
  final List<String> calls = <String>[];

  @override
  bool exists(File file) => files.containsKey(file.path);

  @override
  void createParent(File file) {
    calls.add('createParent');
    if (failCreateParent) {
      throw const FileSystemException('create parent failed', null, OSError('拒绝访问。', 5));
    }
  }

  @override
  void writeString(File file, String text) {
    calls.add('writeString:${file.path}');
    if (failWriteTemp > 0) {
      failWriteTemp--;
      throw const FileSystemException('flush failed', null, OSError('拒绝访问。', 5));
    }
    files[file.path] = text;
  }

  @override
  void rename(File from, File to) {
    calls.add('rename');
    if (failRename) {
      throw const FileSystemException('rename failed', null, OSError('拒绝访问。', 5));
    }
    final String? content = files.remove(from.path);
    if (content == null) {
      throw const FileSystemException('source missing');
    }
    files[to.path] = content;
  }

  @override
  String readString(File file) {
    calls.add('readString');
    if (failRead) {
      throw const FileSystemException('read failed', null, OSError('拒绝访问。', 5));
    }
    return files[file.path]!;
  }

  @override
  void truncateAndWrite(File file, String text) {
    calls.add('truncateAndWrite');
    if (failTruncate > 0) {
      failTruncate--;
      // 截断已经发生（文件被清空）—— 这正是 L2 最危险的中间态
      files[file.path] = '';
      throw const FileSystemException('write after truncate', null, OSError('磁盘空间不足。', 112));
    }
    files[file.path] = text;
  }

  @override
  void delete(File file) {
    calls.add('delete');
    files.remove(file.path);
  }
}

void main() {
  final File target = File('/data/host.json');
  final String oldText = '{"host_id":"old","token_hash":"h1"}';
  final String newText = '{"host_id":"old","token_hash":"h2"}';

  HostWriteReport report() => HostWriteReport(
    level: HostWriteLevel.memory,
    target: target.path,
    temp: '${target.path}.tmp',
    targetExisted: false,
    steps: <String>[],
    retries: <String>[],
  );

  HostWriteReport run(FakeIo io) => writeIdentityFile(
    target: target,
    text: newText,
    report: report(),
    io: io,
    backoff: (int _) => Duration.zero,
  );

  test('L1 正常：临时文件 + rename，落地内容正确，不留 .tmp', () {
    final FakeIo io = FakeIo()..files[target.path] = oldText;
    final HostWriteReport r = run(io);

    expect(r.level, HostWriteLevel.rename);
    expect(r.ok, isTrue);
    expect(io.files[target.path], newText);
    expect(io.files.containsKey('${target.path}.tmp'), isFalse);
    expect(r.targetExisted, isTrue, reason: '操作前目标存在 —— 与首次创建是两回事');
    expect(r.steps, contains('rename-ok'));
  });

  test('写临时文件就失败（flush 失败）⇒ 重试三次都不算成功，转 L2 才落地', () {
    final FakeIo io = FakeIo(failWriteTemp: 3)..files[target.path] = oldText;
    final HostWriteReport r = run(io);

    // 每一次 L1 尝试都必须记成 `write-temp` 失败 —— 不许混进 `rename`
    //（裁定原文：两种情况调查方向完全不同）
    expect(r.retries.length, 3);
    expect(r.retries.every((String x) => x.contains('write-temp')), isTrue);
    expect(
      r.steps.where((String x) => x.startsWith('temp-write-failed')).length,
      3,
    );
    expect(
      r.steps.where((String x) => x.startsWith('rename-failed')),
      isEmpty,
      reason: '根本没走到 rename，不许记成 rename 失败',
    );
    expect(r.level, HostWriteLevel.inPlace, reason: 'L1 三次都失败 ⇒ 走 L2');
    expect(io.files[target.path], newText);
  });

  test('rename 一直失败（真机 errno 5）⇒ L2 原地重写成功，内容正确', () {
    final FakeIo io = FakeIo(failRename: true)..files[target.path] = oldText;
    final HostWriteReport r = run(io);

    expect(r.level, HostWriteLevel.inPlace);
    expect(r.ok, isTrue);
    expect(io.files[target.path], newText);
    expect(r.retries, isNotEmpty);
    expect(r.toLogLine(), contains('rename'));
  });

  test('截断后写入失败 ⇒ 尽力恢复旧内容，并**记录恢复结果**', () {
    // 第一次 truncateAndWrite 失败（= 截断后写入失败），第二次是恢复写入 ⇒ 成功
    final FakeIo io = FakeIo(failRename: true, failTruncate: 1)
      ..files[target.path] = oldText;
    final HostWriteReport r = run(io);

    expect(r.level, HostWriteLevel.memory, reason: 'L2 失败 ⇒ L3');
    expect(r.restoreOutcome, 'ok');
    expect(io.files[target.path], oldText, reason: '旧内容必须写回去');
    expect(r.stage, 'in-place-write');
    expect(r.toLogLine(), contains('restore=ok'));
  });

  test('L2 失败且**恢复写入也失败** ⇒ 如实记 failed（不许声称一定回滚成功）', () {
    final FakeIo io = FakeIo(failRename: true, failTruncate: 2)
      ..files[target.path] = oldText;
    final HostWriteReport r = run(io);

    expect(r.level, HostWriteLevel.memory);
    expect(r.restoreOutcome, startsWith('failed:'));
    expect(r.ok, isFalse);
  });

  test('截断前就读不出旧内容 ⇒ 仍试一次原地写；恢复结果记 nothing-to-restore', () {
    final FakeIo io = FakeIo(failRename: true, failRead: true, failTruncate: 1)
      ..files[target.path] = oldText;
    final HostWriteReport r = run(io);

    expect(r.level, HostWriteLevel.memory);
    expect(r.restoreOutcome, 'nothing-to-restore');
    expect(r.steps, contains('old-read-failed:5'));
  });

  test('父目录都建不了 ⇒ 直接 L3，且 stage 说清是哪一步', () {
    final FakeIo io = FakeIo(failCreateParent: true);
    final HostWriteReport r = run(io);

    expect(r.level, HostWriteLevel.memory);
    expect(r.stage, 'create-parent');
    expect(r.ok, isFalse);
    expect(r.steps, contains('parent-failed:5'));
  });

  test('目标文件本来不存在（首次创建）⇒ targetExisted = false', () {
    final FakeIo io = FakeIo();
    final HostWriteReport r = run(io);
    expect(r.targetExisted, isFalse);
    expect(io.files[target.path], newText);
  });

  test('日志行带齐现场：level / ok / stage / errno / 每步结果', () {
    final FakeIo io = FakeIo(failRename: true, failTruncate: 1)
      ..files[target.path] = oldText;
    final String line = run(io).toLogLine();
    expect(line, contains('level='));
    expect(line, contains('ok='));
    expect(line, contains('errno='));
    expect(line, contains('rename-failed:5'), reason: '每步的 errno 都要留');
    expect(line, contains('steps='));
    expect(line, contains('retries='));
    expect(line, contains('restore=ok'));
  });
}
