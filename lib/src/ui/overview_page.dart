/// 概览页 —— 回答三个问题：**我的数据在哪**、**现在能不能用**、**数据安全吗**。
///
/// 这是落地页（左侧导航第一项）。刻意不塞业务数字：等核心闭环做完，
/// 这里才放「今日销售 / 库存告急 / 欠款」这类聚合（RULE-006 的查询已就绪）。
///
/// ## 裁定落点（`docs/reply_review.md` §AE-3 / §AE-5）
///
/// - **橙卡**（AE-3 的「两层机制」上层）：单次备份失败**静默**，但
///   「超过 3 天没成功备份」必须在**用户不会主动打开设置页**的地方说出来 ——
///   概览页原本就是启动落地页，它有这个位置优势。
/// - **文案与判定都来自纯 Dart**（`backupReminderText`）：这里只负责摆，
///   不造句、不算天数（`docs/ui_principles.md` §二）。
/// - **按钮防抖**（遗漏 11）：点下去立刻禁用 +「备份中…」—— 用户要确信
///   「我的操作被接受了」；服务侧的单飞是兜底，不是替代。
library;

import 'dart:io' show Process;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

/// 提醒橙 —— **不用错误红**（可以不拦人的提醒一律橙色，
/// `docs/ui_principles.md` §1.3；与 `product_form_dialog.dart` 的内联提示同色）
const Color _noticeColor = Color(0xFFB45309);
const Color _noticeBackground = Color(0xFFFFF7ED);

class OverviewPage extends StatefulWidget {
  const OverviewPage({
    super.key,
    required this.dataDirectory,
    required this.backupDirectory,
    required this.schemaVersion,
    required this.databaseReady,
    this.shopName,
    this.backupReminder,
    this.onBackupNow,
    this.locationNote,
    this.mobileShell = false,
    this.queries,
    this.pendingMarks,
    this.onNavigate,
  });

  /// 数据目录（用户选的，数据库就放在这里）
  final String dataDirectory;

  /// 备份目录（数据目录的**兄弟目录**，见 `docs/data_directory.md` §八）
  final String backupDirectory;

  final int schemaVersion;

  /// 数据库是否已成功打开
  final bool databaseReady;

  /// 店名（设置页采集；空则显示「概览」，SC-2）
  final String? shopName;

  /// 备份提醒文案（`null` = 不需要提醒 → 不显示橙卡）。
  /// 由 `shensuanzi_app` 的 `backupReminderText` 给出 —— 与设置页红字同源
  final String? backupReminder;

  /// 「立即备份」；`null` = 备份不可用（库还没打开）→ 不显示按钮
  final Future<BackupOutcome> Function()? onBackupNow;

  /// **#32（2026-10-17 裁定甲）**：聚合查询（手机壳 = 镜像实例化，与
  /// stock_page 同源 —— app.dart 装配）。`null` = 不显示经营卡（库未开）。
  final QueryDao? queries;

  /// **#32（裁定④）**：手机壳「有 N 条未同步」的数据源（诚实口径 ——
  /// 镜像算不出未同步的金额，只如实报条数）。`null` = 不显示该行。
  final PendingMarks? pendingMarks;

  /// **#32（裁定③：快捷入口 = 高频动作）**：跳转回调（销售开单 / 采购入库 /
  /// 送货）。`null` = 不显示入口卡（测试/独立预览）。
  final void Function(String destinationId)? onNavigate;

  /// 「你的数据在」的显示文案（§BH·五 B1b 裁定 2：Android 私有目录用户
  /// 打不开，显示友好文案而非具体路径；路径挪到帮助页「关于」小字）。
  /// `null` = 显示真实路径（桌面行为，零变化）。
  final String? locationNote;

  /// 手机壳（底部导航）—— 只影响「从这里开始」那句指路文案
  /// （M05：手机上不能写「左边的功能列表」）。默认 `false` = 桌面。
  final bool mobileShell;

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  bool _busy = false;

  /// 遗漏 11：**视觉反馈优先于逻辑防护** —— 先禁用按钮，再谈并发。
  /// 结果文案（含完整路径）由领域层给（`backupOutcomeMessage`，遗漏 5）。
  Future<void> _backupNow() async {
    final Future<BackupOutcome> Function()? run = widget.onBackupNow;
    if (run == null || _busy) return;
    setState(() => _busy = true);
    final BackupOutcome outcome = await run();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(backupOutcomeMessage(outcome)),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? reminder = widget.backupReminder;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        // ---- 数据安全橙卡（AE-3：用户不会主动查，所以要主动呈现）----
        if (reminder != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Card(
              margin: EdgeInsets.zero,
              color: _noticeBackground,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 22,
                      color: _noticeColor,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(reminder, style: const TextStyle(height: 1.6)),
                          const SizedBox(height: 10),
                          if (widget.onBackupNow != null)
                            FilledButton.icon(
                              key: const Key('overview-backup-now'),
                              onPressed: _busy ? null : _backupNow,
                              icon: const Icon(Icons.save_alt, size: 18),
                              label: Text(_busy ? '备份中…' : '立即备份'),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        if (widget.shopName != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              widget.shopName!,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('你的数据在', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                if (widget.locationNote != null)
                  Text(
                    widget.locationNote!,
                    style: const TextStyle(height: 1.6),
                  )
                else ...<Widget>[
                  SelectableText(
                    widget.dataDirectory,
                    style: const TextStyle(height: 1.6),
                  ),
                  const SizedBox(height: 4),
                  // 2026-10-22（§CV·八十三 批 2 第 12 条）：**把「打开文件夹」
                  // 搬到概览**。设置页早就有（`settings_page`），概览只给一条
                  // 只读路径 —— 用户想看数据在哪，还得跑去设置里翻。
                  // 手机端不显示（没有「文件管理器打开这个路径」的概念）。
                  if (!widget.mobileShell)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const Key('overview-open-folder'),
                        onPressed: () => _openFolder(widget.dataDirectory),
                        icon: const Icon(Icons.folder_open_outlined, size: 18),
                        label: const Text('打开文件夹'),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    '备份会放在旁边：${widget.backupDirectory}',
                    style: TextStyle(
                      height: 1.6,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // `ui_principles.md` 要求的那句核心承诺 —— 页面上原先没有
                  Text(
                    '数据只在这台电脑上，不会上传到任何地方。',
                    style: TextStyle(
                      height: 1.6,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Icon(
                      widget.databaseReady
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 20,
                      color: widget.databaseReady
                          ? theme.colorScheme.primary
                          : theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.databaseReady
                            ? '数据文件已就绪（版本 ${widget.schemaVersion}）'
                            : '数据文件打不开，请到设置里换一个位置',
                        style: const TextStyle(height: 1.6),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text('从这里开始', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          // M05（2026-10-08）：措辞随壳走 —— 桌面左侧列表 / 手机底部导航。
          // 文案在 `shensuanzi_app` 的 `overviewNavHint`（纯 Dart，`dart test` 钉得住）
          overviewNavHint(mobileShell: widget.mobileShell),
          style: TextStyle(
            height: 1.6,
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
        // ---- #32 经营速览（空库 = hasAnyDocument()==false ⇒ 整块不显示，
        //      不干扰首次开张引导；裁定⑤空库判据 = documents 为空）----
        //
        // 2026-10-20（用户建议）：**从页首挪到「从这里开始」下方** ——
        // 概览页先回答「数据在哪、能不能用、从哪开始」，经营数字是**第二眼**的东西。
        // ⚠️ 必须带顶部间距：手机壳这里是 `Column` 竖排三卡，
        // 紧贴上一段文字会看起来「卡片边缘叠在一起」（用户 2026-10-20 报的现象）。
        if (widget.queries != null &&
            widget.queries!.hasAnyDocument()) ...<Widget>[
          const SizedBox(height: 20),
          _businessCards(theme),
        ],
        // 2026-10-22（§CV·八十三 批 2 第 12 条）：**空库也要有入口**
        if (widget.onNavigate != null &&
            !(widget.queries?.hasAnyDocument() ?? false)) ...<Widget>[
          const SizedBox(height: 12),
          _entriesCard(theme),
        ],
      ],
    );
  }

  /// 「要开工？」入口卡（§CV·八十三 批 2 第 12 条）。
  ///
  /// **空库也要显示** —— 它原来长在 `_businessCards` 里，被
  /// `hasAnyDocument()` 那道门一起关掉；而空库恰恰是最需要指路的时候。
  /// 用系统文件管理器打开数据文件夹（Windows；失败静默 —— 不打断用户）。
  /// 与 `settings_page` 同款实现。
  Future<void> _openFolder(String path) async {
    try {
      await Process.run('explorer', <String>[path]);
    } catch (_) {
      // explorer 打不开（路径失效等）不影响页面
    }
  }

  Widget _entriesCard(ThemeData theme) {
    if (widget.onNavigate == null) return const SizedBox.shrink();
    return _bizCard(
            theme,
            key: 'overview-card-entries',
            title: '要开工？',
            lines: <Widget>[
              // 裁定③：入口 = 高频动作（查询类导航已有，不重复）
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  OutlinedButton.icon(
                    key: const Key('overview-go-sale'),
                    onPressed: () => widget.onNavigate!('sale'),
                    icon: const Icon(Icons.point_of_sale_outlined, size: 18),
                    label: const Text('销售开单'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('overview-go-purchase'),
                    onPressed: () => widget.onNavigate!('purchase'),
                    icon: const Icon(Icons.inventory_outlined, size: 18),
                    label: const Text('采购入库'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('overview-go-delivery'),
                    onPressed: () => widget.onNavigate!('delivery'),
                    icon: const Icon(Icons.local_shipping_outlined, size: 18),
                    label: const Text('送货'),
                  ),
                ],
              ),
            ],
          );
  }

  /// **#32**：经营速览三卡。桌面横排（各 1/3，裁定⑥）；手机紧凑竖排
  ///（padding 收窄 + 入口一行图标）。卡片**不可点**（裁定⑦：先做静态，
  /// 带筛选跳转超范围）。金额 `formatGrouped`（界面带千分位，裁定⑧）。
  Widget _businessCards(ThemeData theme) {
    final QueryDao queries = widget.queries!;
    final OverviewSummary today = queries.todaySummary(_dayStart());
    final ReceivablesSummary receivables = queries.receivablesSummary();
    final int transitCount = queries.deliveryInTransitCount();
    final int negativeStock = queries
        .stockByProduct()
        .values
        .where((int q) => q < 0)
        .length;
    final int unsynced = widget.pendingMarks?.unconfirmedCount() ?? 0;

    final Widget todayCard = _bizCard(
      theme,
      key: 'overview-card-today',
      title: '今日销售（按单据日期）',
      lines: <Widget>[
        Text(
          '店内销售 ${today.saleCount} 笔 · ¥${Money.formatGrouped(today.saleCents)}',
          style: const TextStyle(height: 1.7, fontSize: 15),
        ),
        Text(
          '送货 ${today.deliveryCount} 笔 · '
          '¥${Money.formatGrouped(today.deliveryCents)}'
          '${transitCount > 0 ? '（未签收 $transitCount 张）' : ''}',
          style: const TextStyle(height: 1.7, fontSize: 15),
        ),
        // 裁定④：镜像可能滞后 —— 诚实口径（不假装算得出来，只报条数）
        if (widget.mobileShell && unsynced > 0)
          Text(
            '仅已同步 · 有 $unsynced 条未同步',
            style: const TextStyle(
              height: 1.6,
              fontSize: 12,
              color: _noticeColor,
            ),
          ),
      ],
    );

    final Widget careCard = _bizCard(
      theme,
      key: 'overview-card-care',
      title: '要留心',
      lines: <Widget>[
        if (receivables.totalCents > 0) ...<Widget>[
          Text(
            '应收合计 ¥${Money.formatGrouped(receivables.totalCents)}'
            '（${receivables.partyCount} 家未结）',
            style: const TextStyle(height: 1.7, fontSize: 15),
          ),
          if (receivables.topName != null)
            Text(
              // 裁定⑨：停用的也显示（OBS-05「账未结清要能查到」），标注状态
              '其中 ${receivables.topName} ¥${Money.formatGrouped(receivables.topCents)}'
              '${receivables.topActive ? '' : '（已停用）'}',
              style: TextStyle(
                height: 1.6,
                fontSize: 13,
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
        ],
        if (negativeStock > 0)
          Text(
            '负库存 $negativeStock 种 —— 可能是没录期初或超卖，点「库存」看看',
            style: const TextStyle(
              height: 1.7,
              fontSize: 15,
              color: Colors.red,
            ),
          ),
        if (receivables.totalCents <= 0 && negativeStock == 0)
          const Text('目前没有要留心的事。', style: TextStyle(height: 1.7)),
      ],
    );


    if (widget.mobileShell) {
      // 手机：竖排紧凑（裁定⑥）
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          todayCard,
          const SizedBox(height: 10),
          careCard,
          if (widget.onNavigate != null) ...<Widget>[
            const SizedBox(height: 10),
            _entriesCard(theme),
          ],
        ],
      );
    }
    // 桌面：三卡横排（各 1/3）
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: todayCard),
        const SizedBox(width: 12),
        Expanded(child: careCard),
        const SizedBox(width: 12),
        Expanded(child: _entriesCard(theme)),
      ],
    );
  }

  Widget _bizCard(
    ThemeData theme, {
    required String key,
    required String title,
    required List<Widget> lines,
  }) => Card(
    key: Key(key),
    margin: EdgeInsets.zero,
    child: Padding(
      // 手机紧凑（裁定⑥）：14 vs 桌面 16
      padding: EdgeInsets.all(widget.mobileShell ? 14 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          ...lines,
        ],
      ),
    ),
  );

  /// 本地时间零点（裁定③：UI 层算；测试传固定值 ⇒ core 可复现）。
  /// 多时区同步是登记在案的将来待办（个体户单机单时区，暂不考虑）。
  static DateTime _dayStart() {
    final DateTime now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }
}
