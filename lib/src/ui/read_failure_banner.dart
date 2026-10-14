/// #42 甲 · **L4「不静默」的兑现**：读数据不全时的提示条
/// （2026-10-14 裁定 §二·接线 2 = A：挂在壳的内容区顶部）。
///
/// ## 为什么必须有它
///
/// core 的读路径现在会**跳过**读不出来的行（`decodeRows` + `ReadFailureLog`）。
/// 跳过 = 那一条**看不见** —— 对记账 App，可能是一笔**没显示出来的欠款**。
/// 所以「跳过」必须配「告诉用户」，否则就是**悄悄丢数据**（甲的原话：L4 是 L1 的前提）。
///
/// ## 位置与共用
///
/// 桌面壳（`AppShell`）与手机壳（`MobileShell`）**共用同一个 widget**
/// —— 照 `appShellPage` 的先例：两套壳各写一份必然漂移。
/// 提示条是**库级**状况（不是某一页的问题），所以放内容区顶部常驻。
///
/// ## 文案出处
///
/// 三句都来自 core（`readFailureNotice` / `readFailureCause` / `readFailureAdvice`），
/// **UI 只取值、不造句**（`ui_principles.md` §五）。
///
/// ## ⚠️ 为什么它**订阅**日志，而不是自己在 `build` 里读一次计数
///
/// 计数是**子页面读数据时**才涨的。第一版只在自己的 `build` 里读一次 `count`，
/// 靠「这次读到的不一样 ⇒ `addPostFrameCallback` 再 `setState`」来补 —— **那是错的**：
/// `log.record()` 本身**不会让任何 widget 重建**，于是「父级恰好重建」才更新，
/// 在没有别的重建理由时（正是 widget 测试的场景）**提示条根本不出现**
/// （2026-10-14 被 `widget_test` 抓到，两条断言同时红）。
/// 现在：`ReadFailureLog` 变化时**主动通知**，本 widget 订阅它。
///
/// ⚠️ **通知回调里不能直接 `setState`**：页面可能**在 `build` 里读库**
/// （#42 的原始异常就是这么抛进 `build` 的）⇒ 那时 `record()` 落在**别人的 build 期间**，
/// 直接 `setState` 会被框架判错。所以统一推迟到**帧末**再 `setState`。
///
/// ## ⚠️ 大字号
///
/// 正文用 `Expanded` 换行、按钮用 `Wrap` —— 200% 字号下**不许溢出**（仓内硬纪律）。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

class ReadFailureBanner extends StatefulWidget {
  const ReadFailureBanner({super.key, required this.log});

  /// `null` = 不接线（测试 / 未就绪）⇒ 恒不显示。
  final ReadFailureLog? log;

  @override
  State<ReadFailureBanner> createState() => _ReadFailureBannerState();
}

class _ReadFailureBannerState extends State<ReadFailureBanner> {
  @override
  void initState() {
    super.initState();
    widget.log?.addListener(_onLogChanged);
  }

  @override
  void didUpdateWidget(ReadFailureBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.log, widget.log)) {
      oldWidget.log?.removeListener(_onLogChanged);
      widget.log?.addListener(_onLogChanged);
    }
  }

  @override
  void dispose() {
    widget.log?.removeListener(_onLogChanged);
    super.dispose();
  }

  /// 日志变了 ⇒ 帧末再 `setState`（见文件头：`record` 可能落在别人的 build 期间）。
  void _onLogChanged() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
    // ⚠️ `addPostFrameCallback` **不会自己排帧** ⇒ 必须顺手排一帧，
    // 否则「帧外发生的变化」（异步回调里读库）要等下一次**无关**的重绘才显示出来。
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    final int count = widget.log?.count ?? 0;
    // 计数为 0 ⇒ 完全不占位（桌面现状零变化）
    if (count == 0) return const SizedBox.shrink();

    final ThemeData theme = Theme.of(context);
    // 底色是 errorContainer ⇒ 按钮显式取 onErrorContainer（别指望主题自动配出对比度）
    final ButtonStyle buttonStyle = TextButton.styleFrom(
      foregroundColor: theme.colorScheme.onErrorContainer,
    );
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
                Icon(
                  Icons.warning_amber_rounded,
                  size: 20,
                  color: theme.colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${readFailureNotice(count)}\n$readFailureCause',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
            // ⚠️ `Wrap`：200% 字号下两个按钮放不下就换行（不是溢出）
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: <Widget>[
                TextButton(
                  style: buttonStyle,
                  onPressed: _dismiss,
                  child: const Text('知道了'),
                ),
                TextButton(
                  style: buttonStyle,
                  onPressed: () => _showAdvice(context),
                  child: const Text('去设置看怎么办'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 「知道了」= **已告知**：清掉当前计数，并让**同一批**坏行不再重复提醒
  /// （`ReadFailureLog.clear` 的语义；新出现的坏行照常提醒）。
  /// 清完由订阅回调触发重建 ⇒ 这里不需要自己 `setState`。
  void _dismiss() => widget.log?.clear();

  /// 「去设置看怎么办」= 把 core 的「怎么办」原文摆出来。
  ///
  /// 这里**不跳转**设置页：两套壳的「设置」入口不同（桌面左侧导航 / 手机「我的」），
  /// 跳转要按壳分叉；而用户要的是**这句话**。⛔ 不在这里自己造句。
  void _showAdvice(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('这些数据怎么办'),
        content: const Text(readFailureAdvice),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
