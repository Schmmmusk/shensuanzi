/// 导出表格的**列定义与行映射**（纯 Dart，`dart test` 覆盖）。
///
/// ## 为什么映射不放 UI
///
/// 「哪个字段进哪一列、列叫什么、值怎么措辞」是**判断**，按项目铁律放纯 Dart
/// （`Agents.md`：判断放纯 Dart，Flutter 只摆放）。页面那边只剩一句
/// `exportService.write(商品表(...))`。
///
/// ## 列名与值都是业务语言（§AF AF-9）
///
/// 文件是**给人看的**，不是给机器看的 —— 列名不用 `total_amount`，
/// 值不用 `purchase`。金额走 `Money.format`（分 → 元的唯一实现），
/// 日期走 `format.dart`（本地时间、带时分）。
///
/// ### ⚠️ 金额**只能**用 `Money.format`，绝不能换成 `Money.formatGrouped`
///
/// | 函数 | 输出 | 进 CSV 之后 |
/// |---|---|---|
/// | `Money.format(cents)` | `1234.56` | ✅ 数字，Excel 能求和 |
/// | `Money.formatGrouped(cents)` | `1,234.56` | ❌ 含逗号 ⇒ `csvEscape` 整段加引号 ⇒ **文本**，求和跳过且看不出来 |
///
/// 千分位是**界面**用的（余额、金额标签）；**导出给人算**，一律不带千分位
/// （2026-09-28 裁定明确写进 `csv.dart` 的 `csvEscape` 文档）。
/// 两处镜像断言各有一条「金额列不含逗号」守着这条 —— 谁换成 `formatGrouped` 都会立刻红。
///
/// ## `code` 一律进列
///
/// 商品与库存都带 `编码`（`P0001`）：会计对账要唯一标识，用户自己也要 ——
/// 而且两份文件**能按编码对上**（同款不同批次是常态，光靠名字分不开）。
library;

import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'export.dart';
import 'format.dart';

/// 商品导出（AF-2：**全部**商品，含停用；不看页面搜索框）
ExportTable productExportTable(List<Product> products) => ExportTable(
  label: '商品',
  header: const <String>[
    '编码',
    '商品名称',
    '条码',
    '单位',
    '售价',
    '进价',
    '安全库存',
    '状态',
  ],
  rows: <List<String>>[
    for (final Product product in products)
      <String>[
        product.code,
        product.name,
        product.barcode ?? '',
        product.unit,
        Money.format(product.sellPrice),
        Money.format(product.costPrice),
        '${product.safetyStock}',
        activeLabel(product.isActive),
      ],
  ],
);

/// 库存导出（AF-12：**有流水或有库存**的行 —— 与库存页同口径，即
/// 账面 ≠ 0 或 在途 ≠ 0；净零（进 5 出 5）的不出，那是库存页
/// 「有意义的数字」的原话）。
///
/// ⚠️ 与库存页的**两处不同**（都是 §AF 的要求）：
/// - 商品集合是**含停用**的（`products` 由调用方给全量）；停用但有库存的行
///   会进来，靠 `状态` 列说明
/// - 不看页面的搜索框（按钮文案是「导出库存」，导的是全量库存）
ExportTable stockExportTable({
  required List<Product> products,
  required Map<String, int> book,
  required Map<String, int> inTransit,
  required Map<String, int> cost,
}) => ExportTable(
  label: '库存',
  header: const <String>[
    '编码',
    '商品',
    '条码',
    '单位',
    '库存数量',
    '在途',
    '在店可售',
    '库存成本',
    '状态',
  ],
  rows: <List<String>>[
    for (final Product product in products)
      if ((book[product.id] ?? 0) != 0 || (inTransit[product.id] ?? 0) != 0)
        <String>[
          product.code,
          product.name,
          product.barcode ?? '',
          product.unit,
          '${book[product.id] ?? 0}',
          '${inTransit[product.id] ?? 0}',
          '${(book[product.id] ?? 0) - (inTransit[product.id] ?? 0)}',
          // AF-9：列名说清是**总值**（不是单位成本）
          Money.format(cost[product.id] ?? 0),
          activeLabel(product.isActive),
        ],
  ],
);

/// 往来方导出（含停用 —— 停用但还欠钱的客户必须在里面，否则会计对不上账）
///
/// AF-9：余额**不用负数**，拆成两列 `应收` / `应付`（各取绝对值，
/// 另一列写 `0.00`）—— 会计看的是「谁欠我、我欠谁」，负号是程序视角。
ExportTable partyExportTable({
  required List<Party> parties,
  required Map<String, int> balances,
}) => ExportTable(
  label: '往来方',
  header: const <String>['往来方', '角色', '电话', '地址', '应收', '应付', '状态'],
  rows: <List<String>>[
    for (final Party party in parties) _partyRow(party, balances[party.id] ?? 0),
  ],
);

List<String> _partyRow(Party party, int balance) => <String>[
  party.name,
  partyRolesLabel(party.roles),
  party.phone ?? '',
  party.address ?? '',
  // AF-9：拆两列、不用负数 —— 「谁欠我、我欠谁」比一个带符号的数好读
  Money.format(balance > 0 ? balance : 0),
  Money.format(balance < 0 ? -balance : 0),
  activeLabel(party.isActive),
];

/// 单据导出（跟随页面的时间 / 类型筛选，但**没有 200 上限**，AF-5）
ExportTable documentExportTable(List<DocumentSummary> summaries) => ExportTable(
  label: '单据',
  header: const <String>[
    '单号',
    '单据类型',
    '对方',
    '金额',
    '已收付',
    '状态',
    '日期',
  ],
  rows: <List<String>>[
    for (final DocumentSummary summary in summaries)
      <String>[
        summary.document.docNo,
        summary.document.docType.label,
        // AF-9：没有对方时写「散客」/「散采」，不留空白
        documentPartyLabel(summary.partyName, summary.document.docType),
        Money.format(summary.document.totalAmount),
        Money.format(summary.document.paidAmount),
        docStatusLabel(summary.document.status),
        // §BG 方案甲顺带检查：`occurred_at` 是业务日期（开单页只让选到日），
        // 套带时分的格式会让整列印出「00:00」。往来流水（下方）是真实时刻，
        // 保持 `formatDateTime` —— 那才是 §AF 遗漏 6「带时分排序稳」的适用面。
        formatDate(summary.document.occurredAt),
      ],
  ],
);

/// 往来流水导出（某一方的**全部**流水；文件名带往来方名，AF-7）
///
/// `金额` 保持 `party_ledger` 原口径：**正 = 对方欠我增加**（不是「收了多少」）。
/// 一张收款单是负数。列名不写方向，是因为「收/付」要结合单号看，
/// 而这条口径在帮助页与流水页是同一句话。
ExportTable partyFlowExportTable({
  required List<PartyFlowEntry> flow,
}) => ExportTable(
  label: '往来流水',
  header: const <String>['单号', '单据类型', '金额', '日期'],
  rows: <List<String>>[
    for (final PartyFlowEntry entry in flow)
      <String>[
        entry.docNo,
        entry.docType.label,
        Money.format(entry.amount),
        formatDateTime(entry.occurredAt),
      ],
  ],
);
