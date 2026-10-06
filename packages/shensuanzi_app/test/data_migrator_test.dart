// 数据位置迁移执行器（`DataMigrator`）的测试 —— §BK·三（2026-10-05 裁定）。
//
// 与 `backup_test.dart` 同款：真实临时目录 + 真实文件（迁移就是文件活，
// 桩测不出「同名覆盖 / 嵌套漏删」这类真问题）。覆盖：
// ① 计划的文件数 / 字节数 / 需要的空间（数据 + 备份 + 100 MB 余量）；
// ② 成功路径：拷齐 + 暂存消失 + **旧目录原样**（一个字节不少）；
// ③ 说明文件：新旧路径在文内 + 裁定 ④ 的「请勿删除」原文在；
// ④ 失败退路：注入拷贝失败 ⇒ 只删暂存、旧目录原样、新目录没被建出来。
//
// 运行：`dart test`（本机由用户执行）
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/src/data_migrator.dart';
import 'package:shensuanzi_app/src/instance_lock.dart';
import 'package:test/test.dart';

void main() {
  late Directory box;
  late String oldData;
  late String oldBackup;
  late String newParent;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_migrator_');
    oldData = p.join(box.path, '神算子数据');
    oldBackup = p.join(box.path, '神算子备份');
    newParent = p.join(box.path, 'newhome');
    Directory(oldData).createSync(recursive: true);
    Directory(oldBackup).createSync(recursive: true);
    Directory(newParent).createSync(recursive: true);

    // 旧数据：db + WAL + 标记 + host.json（迁移范围的真实形状）
    File(p.join(oldData, 'shensuanzi.db')).writeAsStringSync('DB' * 100);
    File(p.join(oldData, 'shensuanzi.db-wal')).writeAsStringSync('WAL' * 10);
    File(p.join(oldData, '神算子数据标记.json')).writeAsStringSync('{"v":3}');
    File(p.join(oldData, 'host.json')).writeAsStringSync('{"token":"x"}');
    // 旧备份：两份
    File(p.join(oldBackup, 'a.db')).writeAsStringSync('BAK' * 50);
    File(p.join(oldBackup, 'b.db')).writeAsStringSync('BAK' * 30);
  });

  tearDown(() {
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  DataMigrator migrator({
    required String newData,
    required String newBackup,
    bool Function(String path)? failFor,
  }) => DataMigrator(
    dataDirectory: oldData,
    backupDirectory: oldBackup,
    newDataDirectory: newData,
    newBackupDirectory: newBackup,
    debugFailCopyFor: failFor,
  );

  test('计划：文件数 / 字节数 / 需要空间 = 数据 + 备份 + 100 MB 余量（裁定 ①）', () {
    final MigrationPlan plan = migrator(
      newData: p.join(newParent, '神算子数据'),
      newBackup: p.join(newParent, '神算子备份'),
    ).plan();

    expect(plan.fileCount, 6); // 数据 4 + 备份 2
    final int dataBytes = ('DB' * 100).length + ('WAL' * 10).length +
        '{"v":3}'.length + '{"token":"x"}'.length;
    final int backupBytes = ('BAK' * 50).length + ('BAK' * 30).length;
    expect(plan.byteCount, dataBytes + backupBytes);
    expect(
      plan.requiredBytes,
      dataBytes + backupBytes + MigrationPlan.safetyMarginBytes,
    );
  });

  test('成功：文件拷齐、暂存目录消失、**旧目录原样**', () {
    final String newData = p.join(newParent, '神算子数据');
    final String newBackup = p.join(newParent, '神算子备份');

    final DataMigrationResult result = migrator(
      newData: newData,
      newBackup: newBackup,
    ).execute();

    expect(result.ok, isTrue, reason: result.error ?? '');
    expect(File(p.join(newData, 'shensuanzi.db')).existsSync(), isTrue);
    expect(File(p.join(newData, 'shensuanzi.db-wal')).existsSync(), isTrue);
    expect(File(p.join(newData, '神算子数据标记.json')).existsSync(), isTrue);
    expect(File(p.join(newData, 'host.json')).existsSync(), isTrue);
    expect(File(p.join(newBackup, 'a.db')).existsSync(), isTrue);

    // 暂存目录清干净（rename 后本就不在了；显式断言防将来改实现漏掉）
    expect(
      Directory(newParent)
          .listSync()
          .whereType<Directory>()
          .where((Directory d) => p.basename(d.path).contains('.migrating-'))
          .isEmpty,
      isTrue,
    );

    // ⚠️ 旧目录原样 —— 迁移是「拷贝」不是「搬走」，删旧目录永远是用户的决定
    expect(File(p.join(oldData, 'shensuanzi.db')).existsSync(), isTrue);
    expect(File(p.join(oldBackup, 'a.db')).existsSync(), isTrue);
  });

  test('说明文件：新旧路径在文内 + 裁定 ④ 的「请勿删除」原文在', () {
    final String newData = p.join(newParent, '神算子数据');
    final String newBackup = p.join(newParent, '神算子备份');

    final DataMigrationResult result = migrator(
      newData: newData,
      newBackup: newBackup,
    ).execute();

    expect(result.ok, isTrue);
    final String note = File(result.legacyNotePath!).readAsStringSync();
    expect(note, contains(newData), reason: '要写清新位置在哪');
    expect(note, contains('仍然完好'), reason: '防止用户以为旧数据没用了');
    expect(note, contains('请勿删除'), reason: '裁定 ④：确认新位置正常前，旧目录是唯一完好的备份');
    // 备份目录里也有一份
    expect(
      File(p.join(oldBackup, '已迁移-请先阅读.txt')).existsSync(),
      isTrue,
    );
  });

  test('进度回调：文件数从 0 数到总数（裁定 ③：遮罩上要有进度）', () {
    final String newData = p.join(newParent, '神算子数据');
    final String newBackup = p.join(newParent, '神算子备份');
    final List<int> counts = <int>[];

    migrator(newData: newData, newBackup: newBackup)
        .execute(onProgress: (MigrationProgress progress) => counts.add(progress.filesCopied));

    expect(counts, isNotEmpty);
    expect(counts.first, 1, reason: '从第一个文件就开始报');
    expect(counts.last, 6);
    expect(counts, everyElement(inInclusiveRange(1, 6)));
  });

  test('失败退路（裁定 ⑦）：注入拷贝失败 ⇒ 只删暂存，旧目录原样，新目录没建出来', () {
    final String newData = p.join(newParent, '神算子数据');
    final String newBackup = p.join(newParent, '神算子备份');

    final DataMigrationResult result = migrator(
      newData: newData,
      newBackup: newBackup,
      // 第 3 个文件（标记文件）时失败 —— 拷贝到一半
      failFor: (String path) => path.endsWith('神算子数据标记.json'),
    ).execute();

    expect(result.ok, isFalse);
    expect(result.error, isNotNull);

    // 新位置**没有被建出来**（改名没发生）
    expect(Directory(newData).existsSync(), isFalse);
    // 暂存目录被清掉（裁定 ⑦：只删自己的，且确实删了）
    expect(
      Directory(newParent)
          .listSync()
          .whereType<Directory>()
          .where((Directory d) => p.basename(d.path).contains('.migrating-'))
          .isEmpty,
      isTrue,
      reason: '失败后暂存必须清干净，不能给用户留半成品',
    );
    // 旧目录原样
    expect(File(p.join(oldData, 'shensuanzi.db')).existsSync(), isTrue);
    expect(File(p.join(oldData, '神算子数据标记.json')).existsSync(), isTrue);
    expect(File(p.join(oldBackup, 'a.db')).existsSync(), isTrue);
    // 旧目录里**没有**说明文件（失败时连一个字节都不该多）
    expect(File(p.join(oldData, '已迁移-请先阅读.txt')).existsSync(), isFalse);
  });

  test('目标是**已存在的空目录** ⇒ 先删腾位再改名（errno 183 真机炸点 ①）', () {
    // 真机场景：用户先手动建好了空文件夹，Windows 的 rename 不覆盖已存在路径
    final String newData = p.join(newParent, 'beifen');
    Directory(newData).createSync(recursive: true);

    final DataMigrationResult result = migrator(
      newData: newData,
      newBackup: p.join(newParent, '神算子备份'),
    ).execute();

    expect(result.ok, isTrue, reason: result.error ?? '');
    expect(File(p.join(newData, 'shensuanzi.db')).existsSync(), isTrue);
    expect(Directory('$newData.migrating-').existsSync(), isFalse);
  });

  test('新备份目录与旧备份目录**同位** ⇒ 跳过备份搬迁、不给它写说明（errno 183 真机炸点 ②）', () {
    // 真机场景：新数据目录与旧数据目录同级（D:\beifen）⇒ 兄弟算法算出
    // 同一个「神算子备份」——备份本来就在位，拷了再改名必撞已存在的旧备份
    final String newData = p.join(newParent, 'beifen');

    // 计划同口径：备份同位时不计入（进度总数才对得上）。
    // ⚠️ 必须在 execute **之前**算 —— 成功后旧目录会多出说明文件（4 → 5）
    expect(migrator(newData: newData, newBackup: oldBackup).plan().fileCount, 4);

    final DataMigrationResult result = migrator(
      newData: newData,
      newBackup: oldBackup, // ← 同位
    ).execute();

    expect(result.ok, isTrue, reason: result.error ?? '');
    // 数据搬过去了
    expect(File(p.join(newData, 'shensuanzi.db')).existsSync(), isTrue);
    // 备份**原地未动**：文件还在、没有改名、没有说明文件（它仍是现役备份目录）
    expect(File(p.join(oldBackup, 'a.db')).existsSync(), isTrue);
    expect(Directory('$oldBackup.migrating-').existsSync(), isFalse);
    expect(File(p.join(oldBackup, '已迁移-请先阅读.txt')).existsSync(), isFalse);
  });

  test('目标已存在且有内容 ⇒ 明确失败（执行器自我防线，消息说人话）', () {
    final String newData = p.join(newParent, 'busy');
    Directory(newData).createSync(recursive: true);
    File(p.join(newData, '用户的文件.txt')).writeAsStringSync('别动我');

    final DataMigrationResult result = migrator(
      newData: newData,
      newBackup: p.join(newParent, '神算子备份'),
    ).execute();

    expect(result.ok, isFalse);
    expect(result.error, contains('已存在且有内容'));
    // 用户的文件毫发无损
    expect(File(p.join(newData, '用户的文件.txt')).existsSync(), isTrue);
    // 旧目录原样
    expect(File(p.join(oldData, 'shensuanzi.db')).existsSync(), isTrue);
  });
  // ============================================================ §审查 OBS-14
  //
  // 单实例锁文件是**本机运行态**文件：它被当前进程排他锁着（Windows 上带内容的
  // 被锁文件**拷不动**，实测 errno 0），搬到新位置也没有意义。

  test('OBS-14：搬家**不拷** `.shensuanzi.lock`（计划也不该算它）', () {
    // 模拟「正在运行」：数据目录里躺着单实例锁
    File(p.join(oldData, instanceLockFileName)).writeAsStringSync('');

    final String newData = p.join(newParent, '神算子数据');
    final String newBackup = p.join(newParent, '神算子备份');
    final DataMigrator m = migrator(newData: newData, newBackup: newBackup);

    expect(
      m.plan().fileCount,
      6,
      reason: '数据 4 + 备份 2 —— 锁文件不算（算了进度总数就对不上）',
    );

    expect(m.execute().ok, isTrue);
    expect(
      File(p.join(newData, instanceLockFileName)).existsSync(),
      isFalse,
      reason: '本机运行态文件不该跟着数据搬家（新目录会自己生成一个）',
    );
    expect(
      File(p.join(oldData, instanceLockFileName)).existsSync(),
      isTrue,
      reason: '源目录一个字节都不动',
    );
    // 该搬的照旧
    expect(File(p.join(newData, 'shensuanzi.db')).existsSync(), isTrue);
    expect(File(p.join(newBackup, 'a.db')).existsSync(), isTrue);
  });
}
