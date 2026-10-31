/// **本机账本打不开**时的常驻说明条（2026-10-31 联调 #0，用户裁定 A 第一阶段）。
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
/// ## 裁定（`docs/reply.md` §三/§四，2026-10-31）
///
/// **A 第一阶段 = 降级只读**：照常进主界面、照常看（概览 / 库存 / 往来 / 导出 /
/// 同步状态），**开单与主数据修改暂时禁用**；明确告知「现在用的是手机上的
/// 镜像数据」并显示最近一次同步时间；**不删除、不覆盖**损坏的旧主库。
///
/// 用户明确否掉了「一键重建」这条路：「既然它已经不再是主要业务数据源，
/// 我认为也没有必要急着重建。保留原文件、让 App 使用健康镜像，反而更加简单。」
/// ⇒ 这里只给**一个**出口「怎么办」：把恢复路径（重试 / 导出 / 重装）摆出来。
/// 真正的「重建」要留给**镜像损坏**那条路 —— 那里才有不可重建的 `sync_queue`。
///
/// ## 为什么是「常驻条」而不是弹一次就完
///
/// 这是**库级状况**，不是某一页的问题（与 `read_failure_banner.dart` 同一理由）。
/// 弹一次就消失的话，用户下次发现开单点不动会以为是软件坏了。
///
/// ## ⚠️ 大字号
///
/// 正文用 `Expanded` 换行、按钮用 `Wrap` —— 200% 字号下**不许溢出**（仓内硬纪律）。
/// 文案只到「一句话说清 + 一个动作」，长解释放对话框（那里可以滚动阅读）。
library;

import 'package:flutter/material.dart';

class LocalDbBanner extends StatelessWidget {
  const LocalDbBanner({
    super.key,
    required this.message,
    required this.onAdvice,
  });

  /// 一句话说明（**不含**「怎么办」—— 那是 [onAdvice] 按钮的事）
  final String message;

  /// `null` = 不给出口（只说明）
  final VoidCallback? onAdvice;

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
            if (onAdvice != null)
              // ⚠️ `Wrap`：200% 字号下按钮放不下就换行（不是溢出）
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: <Widget>[
                  // 2026-10-31 真机：原来用 `TextButton`（只有文字、无边框），
                  // 在粉色底上看起来**就是一行字**，用户和我都没意识到能点。
                  // ⇒ 改成带边框的 `OutlinedButton` + 图标：一眼看出是按钮。
                  OutlinedButton.icon(
                    key: const Key('local-db-advice'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: ink,
                      side: BorderSide(color: ink.withValues(alpha: 0.6)),
                    ),
                    onPressed: onAdvice,
                    icon: const Icon(Icons.help_outline, size: 18),
                    label: const Text('怎么办'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
