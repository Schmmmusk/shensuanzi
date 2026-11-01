/// **写入是否被强制关闭**（以及为什么）—— 2026-11-01。
///
/// ## 为什么单独一个文件
///
/// 判据原来内联在 `app.dart` 的 `build()` 里（`readOnly = _localDbFailure != null ||
/// _integrity == low || untrusted`）。内联的后果是：**只能靠真机验**。
/// 而真机上想造出「Low 完整性」得先把 exe 打上 Low 标签、测完再清干净 ——
/// 用户明确说过「本机环境已经变了，没办法在这测」。
///
/// 抽成纯函数之后，`test/write_blocked_test.dart` 直接喂枚举就能钉住：
///
/// - `low` / `untrusted` ⇒ **必须** `true`（否则低权限下用户能录单、白干）；
/// - `unknown` ⇒ **必须** `false`（查不出来不能擅自废掉功能）；
/// - `medium` / `high` / `system` ⇒ `false`。
///
/// ## 两条判据为什么合在一个函数里
///
/// 「本机账本打不开」和「进程低权限」在 UI 上是**同一件事**（写入被关），
/// 但**原因文案不同**（下一步动作也不同：前者重装/重试，后者复制到别的位置）。
/// 分成 `isWriteBlocked` 与 `writeBlockedReason` 两个函数，而不是两个布尔 ——
/// 免得调用点自己拼条件、漏掉一半。
library;

import 'integrity.dart';

/// 写入是否被**强制**关闭。
///
/// [integrity] = 本进程完整性级别；[localDbFailed] = 本机账本打不开。
///
/// ⚠️ `IntegrityLevel.unknown` **不算**关闭：非 Windows 平台、或查询失败时
/// 都会落到 `unknown`，把它当只读等于「查不出来就废掉功能」——
/// 用户裁定（提案 57 批复 §三）明确不许这么做，只记日志。
bool isWriteBlocked({
  required IntegrityLevel integrity,
  required bool localDbFailed,
}) =>
    localDbFailed ||
    integrity == IntegrityLevel.low ||
    integrity == IntegrityLevel.untrusted;

/// 写入被关的**原因**（人话）；`null` = 可以写。
///
/// 两种原因分开说，因为用户下一步做的事完全不同：
///
/// | 原因 | 用户该做什么 |
/// |---|---|
/// | 低权限启动 | 把程序文件夹**复制到别的位置**再打开（或右键解除锁定） |
/// | 本机账本打不开 | 重装 / 重试；看数、查库存、导出都照常 |
///
/// 文案里不出现 `errno` / `ACL` / `完整性级别` 这类词 —— 用户读不懂，
/// 而且它们指向「找技术支持」，而我们想让他先自己走一步。
String? writeBlockedReason({
  required IntegrityLevel integrity,
  required bool localDbFailed,
}) {
  if (integrity == IntegrityLevel.low ||
      integrity == IntegrityLevel.untrusted) {
    return '这个程序是以「低权限」方式启动的，**什么都存不下来**，'
        '所以现在只能看、不能录单和改资料。'
        '把程序文件夹复制到别的位置再打开就能恢复（详见启动时的提示）。';
  }
  if (localDbFailed) {
    return '本机账本打不开，开单和改资料暂时关闭（看数、查库存、查往来、导出都照常）。';
  }
  return null;
}
