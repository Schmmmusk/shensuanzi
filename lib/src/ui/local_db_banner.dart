/// **本机账本打不开**时的常驻说明条（2026-10-31 联调 #0，用户裁定 A + B 相结合）。
///
/// ## 它治的是什么
///
/// 真机实测：把手机上 `files/data/shensuanzi.db` 换成一份 `integrity ok` 的同结构库
/// （或把它弄坏），App 直接进「数据文件暂时打不开」页 —— **尽管手机已配对、
/// 镜像完好、80 张单据都在镜像里**。日志真因是 `SqliteException(522): disk I/O
/// error ... PRAGMA journal_mode = WAL`。
///
/// 两条结论（`docs/reply_review.md` §CV·六十三 ②）：
///
/// 1. **镜像兜不住本地库的故障** —— 手机把本地库当「主库」，它坏了就整体不可用；
/// 2. 但手机壳的业务页**全部读镜像**（`app_shell.dart` 里 `allowBackup` 那段
///    注释写明了：主库在手机上是**空壳**）⇒ 本地库坏掉**根本不该**拦住整个 App。
///
/// ## 裁定 A + B（缺一不可）
///
/// - **A 降级**：照常进主界面。查看 / 开单都走镜像 + 待同步队列，
///   这条路**一次都不碰本地库**（所以能开单，不是只读）；本机自动备份暂停。
/// - **B 重建**：由用户点「修复本机账本」→ 确认框 → 坏文件**改名留档**
///   （`.broken-<时间>`，不删）→ 开一本空账。
///
/// ## 为什么是「常驻条」而不是弹一次就完
///
/// 这是**库级状况**，不是某一页的问题（与 `read_failure_banner.dart` 同一理由）。
/// 弹一次就消失的话，用户下次开单失败会以为是软件坏了，而不会想到点「修复」。
///
/// ## ⚠️ 大字号
///
/// 正文用 `Expanded` 换行、按钮用 `Wrap` —— 200% 字号下**不许溢出**（仓内硬纪律）。
/// 文案只到「一句话说清 + 一个动作」，长解释放确认框（那里可以滚动阅读）。
library;

import 'package:flutter/material.dart';

class LocalDbBanner extends StatelessWidget {
  const LocalDbBanner({
    super.key,
    required this.message,
    required this.onRebuild,
  });

  /// 一句话说明（**不含**「怎么办」—— 那是 [onRebuild] 按钮的事）
  final String message;

  /// `null` = 不给出口（只说明）
  final VoidCallback? onRebuild;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 底色是 errorContainer ⇒ 前景色显式取 onErrorContainer
    //（别指望主题自动配出对比度 —— `read_failure_banner.dart` 同款）
    final Color ink = theme.colorScheme.onErrorContainer;
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.error_outline, size: 20, color: ink),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: ink,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
            if (onRebuild != null)
              // ⚠️ `Wrap`：200% 字号下按钮放不下就换行（不是溢出）
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: <Widget>[
                  TextButton(
                    key: const Key('local-db-rebuild'),
                    style: TextButton.styleFrom(foregroundColor: ink),
                    onPressed: onRebuild,
                    child: const Text('修复本机账本'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
