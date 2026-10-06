/// 单实例锁（§审查 OBS-14）。
///
/// ## 为什么必须有
///
/// 同一个数据目录被两个实例同时打开 = 两条写路径（开单 / 核销 / **迁移**）。
/// SQLite 在 WAL 下多进程写会 `SQLITE_BUSY`，而「更改数据位置」要**关库** ——
/// 另一个实例正在写时，关库会失败甚至丢数据。同步（B2/B3）上线后更糟：
/// 双实例 = 双 `SyncServer` = 端口冲突 + 重复拉取 + 镜像损坏。
///
/// ## 为什么用**文件锁**
///
/// 纯 Dart（`RandomAccessFile.lockSync`）· 零依赖 · 跨平台，且**进程退出时由
/// 操作系统自动释放** —— 断电 / 强杀都不会留下死锁。这是「锁文件」方案最常见
/// 的反对理由（「异常退出会有残留锁」），其实不成立。
///
/// ## 三条硬约束
///
/// 1. **锁不住就放行**：锁是保护措施，不能变成新的故障点。目录只读 / 锁文件
///    建不出来时返回 [InstanceLockResult.unavailable]，调用方**照常启动**。
/// 2. **换目录要换锁**：[acquire] 自己会先 release，迁移 / 切回已有目录直接调。
/// 3. **不删锁文件**：删了会有竞态（A 释放并 unlink、B 的句柄指向已 unlink 的
///    inode ⇒ B 的锁形同虚设）。锁文件本身是空的，留着无害。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 锁文件名 —— 与数据目录里的标记文件并列。
const String instanceLockFileName = '.shensuanzi.lock';

/// 加锁结果。
enum InstanceLockResult {
  /// 拿到了（或本来就没别人）
  acquired,

  /// **别人正开着这个数据目录** —— 调用方应拦下来，让用户去任务栏找
  alreadyRunning,

  /// 锁机制本身用不了（目录只读 / 平台不支持）—— 调用方**照常启动**
  unavailable,
}

/// 文件锁实现的单实例互斥。
class InstanceLock {
  RandomAccessFile? _handle;
  String? _directory;

  /// 当前是否握着锁（`false` = 没锁 / 拿不到 / 已释放）。
  bool get held => _handle != null;

  /// 当前锁着哪个目录；没锁时为 `null`。
  String? get directory => _directory;

  /// 尝试给 [directory] 加排他锁。
  InstanceLockResult acquire(String directory) {
    release(); // 约束 2：换目录先放旧的

    final File file = File(p.join(directory, instanceLockFileName));
    final RandomAccessFile handle;
    try {
      file.parent.createSync(recursive: true);
      handle = file.openSync(mode: FileMode.write);
    } catch (_) {
      // 约束 1：连锁文件都建不出来 ⇒ 不是「有人在用」，是锁用不了 ⇒ 放行
      return InstanceLockResult.unavailable;
    }

    try {
      // ⚠️ `FileLock.exclusive` 是**非阻塞**的：拿不到就抛 —— 正是要的语义。
      // （`blockingExclusive` 会一直等，第二个实例会「假死」在启动页。）
      handle.lockSync(FileLock.exclusive);
    } catch (_) {
      try {
        handle.closeSync();
      } catch (_) {
        // 关不上也无所谓，句柄会被进程回收
      }
      return InstanceLockResult.alreadyRunning;
    }

    _handle = handle;
    _directory = directory;
    return InstanceLockResult.acquired;
  }

  /// 放锁（不删锁文件，见类注释约束 3）。
  void release() {
    final RandomAccessFile? handle = _handle;
    _handle = null;
    _directory = null;
    if (handle == null) return;
    try {
      handle.unlockSync();
    } catch (_) {
      // 进程即将退出，解不开也没关系（操作系统会收）
    }
    try {
      handle.closeSync();
    } catch (_) {
      // 同上
    }
  }
}
