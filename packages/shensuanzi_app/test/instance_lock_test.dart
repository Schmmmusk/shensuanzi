// 单实例锁（§审查 OBS-14）—— 纯 Dart 测试。
//
// ## 为什么用「同进程 + 两个句柄」而不是真子进程
//
// 真子进程测试最直白，但**本机 `dart test` 建不出子进程**（Dart 在 Windows 上
// 的已知限制，`CreateFile failed 231`）。好在 Windows 的 `LockFileEx` 是**按文件
// 句柄**判定的：同一进程里开两个句柄对同一区间加排他锁，第二个会失败
// （`ERROR_LOCK_VIOLATION`）—— 所以这个测法在 **Windows 上等价于跨进程**，
// 而桌面正是我们的目标平台（Windows 端是唯一权威数据源）。
//
// ⚠️ POSIX 的 `fcntl` 记录锁是**按进程**的，同进程测不出来 —— 那种平台要真子进程。
//    锁在跨进程下由操作系统保证，这正是选文件锁的理由（见 `instance_lock.dart`）。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:test/test.dart';

void main() {
  late Directory box;
  late String dir;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_lock_');
    dir = p.join(box.path, 'data');
    Directory(dir).createSync(recursive: true);
  });

  tearDown(() {
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉（句柄还没放等）不影响结论
    }
  });

  test('拿到锁 → held；锁文件落在数据目录里', () {
    final InstanceLock lock = InstanceLock();
    expect(lock.acquire(dir), InstanceLockResult.acquired);
    expect(lock.held, isTrue);
    expect(lock.directory, dir);
    expect(File(p.join(dir, instanceLockFileName)).existsSync(), isTrue);
    lock.release();
    expect(lock.held, isFalse);
  });

  test('⚠️ 第二个「实例」被拦住（Windows 按句柄判定 ⇒ 等价跨进程）', () {
    final InstanceLock first = InstanceLock();
    expect(first.acquire(dir), InstanceLockResult.acquired);

    final InstanceLock second = InstanceLock();
    final InstanceLockResult result = second.acquire(dir);

    if (Platform.isWindows) {
      expect(
        result,
        InstanceLockResult.alreadyRunning,
        reason: '§审查 OBS-14：同一个数据目录不许两个实例同时开库',
      );
      expect(second.held, isFalse, reason: '没拿到就别假装持有');
    } else {
      // POSIX：fcntl 锁按进程，同进程测不出互斥 —— 只能验「不抛」
      expect(result, isA<InstanceLockResult>());
    }

    // 第一个放锁之后，第二个必须能拿到（否则锁就变成「一旦有人拿过就废」）
    first.release();
    expect(second.acquire(dir), InstanceLockResult.acquired);
    second.release();
  });

  test('换目录 = 换锁（迁移 / 切回已有目录都会连续调）', () {
    final String other = p.join(box.path, 'other');
    Directory(other).createSync(recursive: true);

    final InstanceLock lock = InstanceLock();
    expect(lock.acquire(dir), InstanceLockResult.acquired);
    expect(lock.acquire(other), InstanceLockResult.acquired, reason: '换目录要先放旧锁');
    expect(lock.directory, other);

    // 旧目录已经放开 —— 别人能拿
    final InstanceLock other2 = InstanceLock();
    expect(other2.acquire(dir), InstanceLockResult.acquired);
    other2.release();

    if (Platform.isWindows) {
      final InstanceLock other3 = InstanceLock();
      expect(other3.acquire(other), InstanceLockResult.alreadyRunning);
      other3.release();
    }
    lock.release();
  });

  test('建不出锁文件 ⇒ unavailable（**放行**：锁不能变成新故障点）', () {
    // ⚠️ `createSync(recursive: true)` 会自动建中间目录 —— 用「不存在的盘」
    //    试不出来。要触发失败，得让**父路径是一个普通文件**。
    final File blocker = File(p.join(box.path, '一个文件'))
      ..writeAsStringSync('我不是目录');

    final InstanceLock lock = InstanceLock();
    expect(
      lock.acquire(p.join(blocker.path, 'x')),
      InstanceLockResult.unavailable,
      reason: '锁用不了 ≠ 有人在用；调用方应当照常启动',
    );
    expect(lock.held, isFalse);
  });

  test('释放后可重复加锁（acquire → release → acquire）', () {
    final InstanceLock lock = InstanceLock();
    expect(lock.acquire(dir), InstanceLockResult.acquired);
    lock.release();
    expect(lock.acquire(dir), InstanceLockResult.acquired);
    lock.release();
  });
}
