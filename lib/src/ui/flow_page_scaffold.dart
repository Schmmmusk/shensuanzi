/// 三个流水页共用的骨架（往来方 / 账户 / 商品流水）。
///
/// ## 为什么导出按钮在 body 表头，不在 `AppBar.actions`
///
/// 5c-2（2026-11-04）要求「上次导出：文件名（今天 09:12）」**留在页面上**，
/// [ExportButton] 因此变成 `Column(按钮, 小字)`。而 `AppBar.actions` 的高度是
/// **硬约束** `0 <= h <= kToolbarHeight`（56 逻辑像素，缩放后更小）——
/// 一行小字塞不进去，实测 `RenderFlex overflowed by 8.0 pixels`
/// （复现 = `test/parties_page_test.dart` 的导出用例）。
///
/// 项目里另外 5 个 [ExportButton] 调用点（单据 / 商品 / 往来方 / 库存 / 概览）
/// 本来就放在 **body 表头的 `Wrap`** 里，那里有余量、且 `Wrap` 已为超大字号
/// 做过换行（§BH·六 B1c·补）。所以本骨架把三个流水页**统一到同一容器**：
///
/// | 方案 | 结论 |
/// |---|---|
/// | 硬塞进 56px | 字号 1.3 / 2.0 档必然再溢出（字号是用户选的，不是我们挑的） |
/// | AppBar 里不显示小字 | 违反 `docs/ui_principles.md` §1.1（悬浮提示 = 隐藏入口） |
/// | **移到 body 表头**（本方案） | 8 个调用点同构，一处修好八处好 |
///
/// ⚠️ 三个流水页**必须都走本骨架** —— 同构代码是漏改的高发区（纪律 18）。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

import 'export_button.dart';

/// 流水页骨架：标题栏（只放返回）+ body 表头（标题 + 导出）+ 列表 / 空态。
///
/// [headerTitle] 是 body 表头左侧的标题（**流水页不传** —— 标题已在 AppBar）；
/// [emptyText] 是无流水时的提示；
/// [footer] 挂在列表**末尾**（不是表头 —— 表头高度要留给按钮 + 小字）。
class FlowPageScaffold extends StatelessWidget {
  const FlowPageScaffold({
    super.key,
    required this.title,
    required this.emptyText,
    required this.itemCount,
    required this.itemBuilder,
    required this.narrow,
    this.headerTitle,
    this.exports,
    this.exportKey,
    this.exportLabel = '导出流水',
    this.exportExtra,
    this.buildExportTable,
    this.footer,
  });

  /// AppBar 标题（如「张三 的流水」）
  final String title;

  /// body 表头标题。`null` = 表头只放导出按钮（右对齐）。
  ///
  /// 流水页**传 null** —— 标题已在 AppBar，重复一遍是噪音（且会让
  /// `find.text` 命中两个）。另外 5 个导出页在主壳里没有 AppBar，
  /// 才需要表头标题。
  final String? headerTitle;

  /// 空态文案
  final String emptyText;

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// 窄屏判定（由页面用 `isNarrowOf(..., base: flowNarrowBase)` 算好传入）
  final bool narrow;

  /// 导出服务（`null` = 不显示导出按钮）
  final ExportSink? exports;

  /// 导出按钮的 Key（测试锚点）
  final Key? exportKey;

  /// 导出按钮文案（四字，C3·真机反馈 ③）
  final String exportLabel;

  /// AF-7：文件名里带的对象名 —— 否则导三个客户的文件名一模一样
  final String? exportExtra;

  /// 拼导出表（各页传自己的 `xxxFlowExportTable`）
  final ExportTable Function()? buildExportTable;

  /// 列表末尾的说明行（灰字，可点性说明）
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool hasExport = exports != null && buildExportTable != null;
    return Scaffold(
      // 导出按钮**不在这里**（见文件头表格）—— AppBar 只留返回箭头。
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            // 没导出服务也没表头标题 ⇒ 整条不渲染（省出一行高度给列表）
            if (hasExport || headerTitle != null)
              Padding(
                // 与列表同款左内边距 16，表头与行左对齐
                padding: EdgeInsets.fromLTRB(narrow ? 12 : 16, 10, 12, 2),
                // Wrap：超大字号下标题与按钮自动换行，不挤成竖排（§BH·六 B1c·补）
                child: Wrap(
                  alignment: headerTitle == null
                      ? WrapAlignment.end
                      : WrapAlignment.spaceBetween,
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    // 与另外 5 个导出页表头同款：Text 直接进 Wrap（`Flexible`
                    // 是 Flex 的 ParentDataWidget，放进 Wrap 会报
                    // Incorrect use of ParentDataWidget）。Wrap 会给子件
                    // 松约束，长标题自己折行，不会挤爆。
                    if (headerTitle != null)
                      Text(headerTitle!, style: theme.textTheme.titleLarge),
                    if (hasExport)
                      ExportButton(
                        key: exportKey,
                        label: exportLabel,
                        export: () => exports!.write(
                          buildExportTable!(),
                          extra: exportExtra,
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: itemCount == 0
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          emptyText,
                          style: TextStyle(
                            height: 1.8,
                            color: theme.hintColor,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      itemCount: footer == null ? itemCount : itemCount + 1,
                      itemBuilder: (BuildContext context, int index) {
                        if (footer != null && index == itemCount) {
                          return footer;
                        }
                        return itemBuilder(context, index);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
