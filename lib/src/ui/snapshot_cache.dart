/// 三页「上次算好的快照」——**只用于首帧显示**，永远会被后台重算覆盖。
///
/// ## 为什么有它（2026-11-21 裁定「甲」）
///
/// 壳是「切页即现建 widget」（`app_shell.dart` 的 `_content()`，刻意不是
/// `IndexedStack`）⇒ 每次切回来 State 都重建、`initState` 重新跑一趟 isolate。
/// 真机 NVMe 上这一趟 ~0.3 s、虚拟机上 ~1 s，用户看得见「先初始态、后数据」那一下闪。
///
/// 甲案的边界（评审 `docs/reply.md` 写死的三条，本文件照此实现）：
///
/// 1. **仍然每次都重算** —— 这里只是把「上次的画面」先画出来，不改变
///    「数据以流水为准」；命中缓存**不跳过**后台重算。
/// 2. **必须提示正在刷新** —— 否则用户看到的是「旧数字」而不知道它还会变。
///    各页在命中缓存时显示一行 `_refreshing` 提示（见各页渲染）。
/// 3. **单据页的快照必须与筛选条件同键** —— 否则切回来会看到「筛选是默认、
///    行却是上次某个筛选的结果」。所以单据页的 key 里带完整筛选签名。
///
/// ⚠️ **不做的事**：不按 `remoteVersion` 跳过查询（那是被否掉的乙案 ——
/// 本地写单不改版本号，漏一处就是「数字不更新」）。
///
/// ⚠️ 缓存进程内有效、不落盘：重启进程自然清空，不存在「用一年前的数」。
library;

/// 快照表。键由各页自己拼（`'overview:<库路径>'` 这类）。
final Map<String, Object> _snapshots = <String, Object>{};

/// 取一份快照；类型不符（或没有）⇒ `null`。
T? snapshotOf<T extends Object>(String key) {
  final Object? value = _snapshots[key];
  return value is T ? value : null;
}

/// 记下一份快照（覆盖旧的）。
void rememberSnapshot(String key, Object value) => _snapshots[key] = value;

/// 测试用：清空。
///
/// 为什么需要它：这是**模块级**状态，会跨用例存活 —— 同一个测试文件里
/// 两个用例用了同一个库路径（例如都写死临时目录），第二个用例会拿到
/// 第一个的快照，断言就成了「测空气」。
void clearSnapshotCache() => _snapshots.clear();
