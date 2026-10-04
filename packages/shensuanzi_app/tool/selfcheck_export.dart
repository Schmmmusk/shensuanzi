/// 导出的降级门禁（对应 `test/csv_test.dart` + `test/export_test.dart`，§AF）。
///
/// ⚠️ **改一边必须改另一边** —— `test/**` 是正式门禁，本脚本是
/// 「跑不了 `dart test` 时的降级门禁」（`docs/testing.md` §零）。
///
/// 运行：`dart run tool/selfcheck_export.dart`
///
/// ⚠️ 导出**不碰数据库**（表格由调用方喂进来），所以本脚本不需要 SQLite。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

int _pass = 0;
int _fail = 0;
final List<String> _failures = <String>[];

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✓ $name');
  } else {
    _fail++;
    _failures.add(name);
    stdout.writeln('  ✗ $name${detail == null ? '' : '  →  $detail'}');
  }
}

void section(String title) => stdout.writeln('\n── $title ──');

/// `1234.56` / `-200.00` —— 不带千分位、不带货币符号的金额（`Money.format` 的产出）
final RegExp _plainAmount = RegExp(r'^[+-]?\d+\.\d{2}$');

/// `1,234.56` —— 千分位形态。**出现即说明有人用了 `Money.formatGrouped`。**
final RegExp _groupedAmount = RegExp(r'^[+-]?\d{1,3}(,\d{3})+(\.\d{2})?$');

/// 五张表里**所有**像千分位金额的单元格（`test/export_test.dart` 有同款镜像断言）。
///
/// 金额带逗号 ⇒ `csvEscape` 整段加引号 ⇒ Excel 当**文本**、求和跳过，用户看不出来。
/// 千分位（`Money.formatGrouped`）是**界面**用的，导出一律 `Money.format`。
/// 返回空 `grouped` 才正常；同时返一个 `plainCount`，用来证明断言没空转。
({List<String> grouped, int plainCount}) auditAmounts(List<ExportTable> tables) {
  final List<String> grouped = <String>[];
  int plain = 0;
  for (final ExportTable table in tables) {
    for (final List<String> row in table.rows) {
      for (final String cell in row) {
        if (_groupedAmount.hasMatch(cell)) grouped.add('${table.label}：$cell');
        if (_plainAmount.hasMatch(cell)) plain++;
      }
    }
  }
  return (grouped: grouped, plainCount: plain);
}

Future<void> main() async {
  final DateTime base = DateTime(2026, 9, 28, 15, 30);
  final int t = DateTime(2026, 9, 28, 10).millisecondsSinceEpoch;

  // ============================================================ 转义
  section('csvEscape（转义 + 注入防护）');
  {
    check('普通字段与中文原样',
        csvEscape('娃哈哈矿泉水') == '娃哈哈矿泉水' && csvEscape('') == '');
    check('含逗号 / 引号 / 换行 → 整段加引号、内部引号双写',
        csvEscape('娃哈哈,矿泉水') == '"娃哈哈,矿泉水"' &&
            csvEscape('他说"好"') == '"他说""好"""' &&
            csvEscape('两行\n地址') == '"两行\n地址"');
    check('= + - @ 开头 → 加前导单引号（遗漏 1）',
        csvEscape('=赠品') == "'=赠品" &&
            csvEscape('=SUM(A1:A9)') == "'=SUM(A1:A9)" &&
            csvEscape('+86 138') == "'+86 138" &&
            csvEscape('-5 折') == "'-5 折" &&
            csvEscape('@批发') == "'@批发");
    check('纯数字放行（负金额不能变文本，否则求和漏数）',
        csvEscape('-12.34') == '-12.34' &&
            csvEscape('0.00') == '0.00' &&
            csvEscape('-1234') == '-1234' &&
            csvEscape('+12.34') == '+12.34' &&
            csvEscape('-2+3') == "'-2+3" &&
            csvEscape('+86 138') == "'+86 138");
    check('千分位会被转义成文本（所以导出金额不带千分位）',
        csvEscape('1,234.56') == '"1,234.56"' &&
            csvEscape('1234.56') == '1234.56' &&
            Money.format(123456) == '1234.56' &&
            Money.formatGrouped(123456) == '1,234.56');
    check('注入 + 需要引号：两层都生效', csvEscape('=a,b') == '"\'=a,b"');
    check('csvLine 逗号连接（各字段独立转义）',
        csvLine(<String>['a', 'b,c', 'd']) == 'a,"b,c",d');
  }

  // ============================================================ 编码
  section('csvBytes（BOM + CRLF + UTF-8）');
  {
    final Uint8List bytes = csvBytes(
      <String>['商品名称', '金额'],
      <List<String>>[
        <String>['可乐', '12.50'],
      ],
    );
    check('开头三字节是 BOM（坑 1：没有它 Excel 用 GBK 解码）',
        bytes.sublist(0, 3).join(',') == '239,187,191');
    final String text = utf8.decode(bytes.sublist(3));
    check('CRLF 行尾 + 表头 + 行',
        text == '商品名称,金额\r\n可乐,12.50\r\n');
    check('中文按 UTF-8（3 字节 / 字）',
        csvBytes(<String>['名'], const <List<String>>[]).length == 3 + 3 + 2);
    check('空行集 → 只有表头',
        utf8.decode(csvBytes(<String>['a', 'b'], const <List<String>>[])
                .sublist(3)) ==
            'a,b\r\n');
  }

  // ============================================================ 措辞
  section('日期与措辞（给人看）');
  {
    check('formatDate / formatDateTime 本地时间、带时分（遗漏 6）',
        formatDate(t) == '2026-09-28' &&
            formatDateTime(t) == '2026-09-28 10:00' &&
            formatFileDate(base) == '20260928' &&
            formatDateTime(DateTime(2026, 1, 2, 3, 4).millisecondsSinceEpoch) ==
                '2026-01-02 03:04');
    check('单据状态中文（6 个）',
        docStatusLabel(DocStatus.draft) == '草稿' &&
            docStatusLabel(DocStatus.confirmed) == '已确认' &&
            docStatusLabel(DocStatus.inTransit) == '在途' &&
            docStatusLabel(DocStatus.delivered) == '已送达' &&
            docStatusLabel(DocStatus.settled) == '已结清' &&
            docStatusLabel(DocStatus.cancelled) == '已作废');
    check('角色中文 + 顿号连接 + 启用停用',
        partyRoleLabel(PartyRole.supplier) == '供应商' &&
            partyRoleLabel(PartyRole.customer) == '客户' &&
            partyRoleLabel(PartyRole.carrier) == '司机' &&
            partyRolesLabel(
                    const <PartyRole>[PartyRole.customer, PartyRole.supplier]) ==
                '客户、供应商' &&
            activeLabel(true) == '启用' &&
            activeLabel(false) == '停用');
    check('对方为空 → 散客 / 散采（AF-9）',
        documentPartyLabel('王老板', DocType.sale) == '王老板' &&
            documentPartyLabel(null, DocType.sale) == '散客' &&
            documentPartyLabel('', DocType.sale) == '散客' &&
            documentPartyLabel(null, DocType.purchase) == '散采' &&
            documentPartyLabel(null, DocType.stocktake) == '散采');
  }

  // ============================================================ 文件名
  section('ExportFileName（AF-7）');
  {
    check('商品 / 单据带范围 / 流水带往来方名',
        ExportFileName(label: '商品', date: base).fileName ==
                '神算子-商品-20260928.csv' &&
            ExportFileName(
                        label: '单据',
                        date: base,
                        from: DateTime(2026, 6, 1))
                    .fileName ==
                '神算子-单据-20260928-20260601至20260928.csv' &&
            ExportFileName(label: '往来流水', date: base, extra: '王老板')
                    .fileName ==
                '神算子-往来流水-王老板-20260928.csv');
    check('往来方名非法字符清洗 / 截断 / 空名兜底',
        ExportFileName.sanitize('王老板/李老板') == '王老板_李老板' &&
            ExportFileName.sanitize('结尾带点..') == '结尾带点' &&
            ExportFileName.sanitize('   ') == '未命名' &&
            ExportFileName.sanitize('') == '未命名' &&
            ExportFileName.sanitize('长' * 60).length == 40 &&
            ExportFileName(label: '往来流水', date: base, extra: 'A/B').fileName ==
                '神算子-往来流水-A_B-20260928.csv');
  }

  // ============================================================ 服务
  section('ExportService（真实目录）');
  {
    final Directory box = Directory.systemTemp.createTempSync('shensuanzi_exp_');
    final String exportDir = p.join(box.path, '神算子导出');
    final ExportService service = ExportService(
      exportDirectory: exportDir,
      now: () => base,
    );

    ExportTable table({int rows = 1, String label = '商品'}) => ExportTable(
      label: label,
      header: const <String>['编码', '商品名称'],
      rows: <List<String>>[
        for (int i = 0; i < rows; i++) <String>['P000$i', '可乐$i'],
      ],
    );

    // 0 行：不生成文件（遗漏 4）—— 目录都不该被建
    final ExportOutcome empty = await service.write(table(rows: 0));
    final Directory exportDirObj = Directory(exportDir);
    check('0 行 → ExportEmpty 且连目录都不建',
        empty is ExportEmpty &&
            !exportDirObj.existsSync() &&
            exportOutcomeMessage(empty).contains('没有数据'));

    // 写成功：目录自动创建 + BOM + 表头 + 行数（AF-3）
    final ExportOutcome ok = await service.write(table(rows: 3));
    final String okPath = ok is ExportSuccess ? ok.path : '';
    final Uint8List bytes = okPath.isEmpty
        ? Uint8List(0)
        : File(okPath).readAsBytesSync();
    check('写成功：目录自动建 + 行数 + 文件名 + BOM + 表头',
        ok is ExportSuccess &&
            ok.rowCount == 3 &&
            p.basename(okPath) == '神算子-商品-20260928.csv' &&
            bytes.length > 3 &&
            bytes.sublist(0, 3).join(',') == '239,187,191' &&
            utf8.decode(bytes.sublist(3)).contains('编码,商品名称'));
    check('结果文案：成功带完整路径（遗漏 5）',
        exportOutcomeMessage(ok).contains('已导出 3 条到') &&
            exportOutcomeMessage(ok).contains(exportDir));

    // 并发：同名复用同一 Future；不同表不串味（遗漏 2）
    final ExportTable a = table();
    final ExportTable b = table(label: '库存');
    final Future<ExportOutcome> f1 = service.write(a);
    final Future<ExportOutcome> f2 = service.write(a);
    final Future<ExportOutcome> other = service.write(b);
    final ExportOutcome otherOutcome = await other;
    check('同名并发复用同一 Future；不同表独立',
        identical(f1, f2) &&
            !identical(f1, other) &&
            otherOutcome is ExportSuccess &&
            p.basename(otherOutcome.path) == '神算子-库存-20260928.csv');
    await f1;

    // 目录不可写：路径上蹲一个同名文件（遗漏 9）
    final String blockedDir = p.join(box.path, 'not-a-dir');
    File(blockedDir).writeAsStringSync('占位');
    final ExportService blocked = ExportService(
      exportDirectory: blockedDir,
      now: () => base,
    );
    final ExportOutcome failedOutcome = await blocked.write(table());
    check('目录不可写 → ExportFailed 且说「导出文件夹」+ 文案前缀',
        failedOutcome is ExportFailed &&
            failedOutcome.reason.contains('导出文件夹') &&
            exportOutcomeMessage(failedOutcome).startsWith('导出失败：'));

    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  }

  // ============================================================ 表格映射
  section('导出表格（AF-9：业务语言）');
  {
    final Product p1 = Product(
      id: 'p1',
      code: 'P0001',
      name: '可乐',
      barcode: '6901234567890',
      unit: '瓶',
      sellPrice: 300,
      costPrice: 200,
      safetyStock: 5,
      createdAt: t,
      updatedAt: t,
    );
    final Product p2 = Product(
      id: 'p2',
      code: 'P0002',
      name: '停用但有货',
      isActive: false,
      createdAt: t,
      updatedAt: t,
    );
    final Product p3 = Product(
      id: 'p3',
      code: 'P0003',
      name: '卖光了',
      createdAt: t,
      updatedAt: t,
    );

    final ExportTable products = productExportTable(<Product>[p1, p2]);
    check('商品：8 列（含编码 / 状态）+ 金额是元 + 空条码写空串',
        products.label == '商品' &&
            products.header.join(',') == '编码,商品名称,条码,单位,售价,进价,安全库存,状态' &&
            products.rows[0].join('|') == 'P0001|可乐|6901234567890|瓶|3.00|2.00|5|启用' &&
            products.rows[1][2] == '' &&
            products.rows[1].last == '停用');

    final ExportTable stock = stockExportTable(
      products: <Product>[p1, p2, p3],
      book: <String, int>{'p1': 10, 'p2': 4},
      inTransit: <String, int>{'p1': 3},
      cost: <String, int>{'p1': 800},
    );
    check('库存：只出账面 / 在途不为 0 的行；在店可售 = 账面 − 在途；含停用行',
        stock.header.join(',') ==
                '编码,商品,条码,单位,库存数量,在途,在店可售,库存成本,状态' &&
            stock.rows.length == 2 &&
            stock.rows[0].sublist(4).join('|') == '10|3|7|8.00|启用' &&
            stock.rows[1][1] == '停用但有货' &&
            stock.rows[1].last == '停用');

    final Party y1 = Party(
      id: 'y1',
      name: '王老板',
      phone: '13800000000',
      address: '城南菜市场 3 号',
      roles: const <PartyRole>[PartyRole.customer],
      createdAt: t,
      updatedAt: t,
    );
    final ExportTable parties = partyExportTable(
      parties: <Party>[y1],
      balances: <String, int>{'y1': 12345},
    );
    check('往来方：应收 / 应付分两列、不用负数',
        parties.header.join(',') == '往来方,角色,电话,地址,应收,应付,状态' &&
            parties.rows[0].sublist(4).join('|') == '123.45|0.00|启用');

    final ExportTable docs = documentExportTable(<DocumentSummary>[
      DocumentSummary(
        document: Document(
          id: 'd1',
          docNo: 'XS20260928-002',
          docType: DocType.sale,
          status: DocStatus.settled,
          totalAmount: 1250,
          paidAmount: 1250,
          occurredAt: t,
          createdAt: t,
          updatedAt: t,
        ),
        partyName: null,
      ),
      // ⚠️ 大额行**必须有**：千分位只有 ≥ 1000 元才出现（`1,234.56`），
      // 全是 `12.50` 这种小额的夹具**抓不到**「有人换成了 formatGrouped」
      DocumentSummary(
        document: Document(
          id: 'd2',
          docNo: 'XS20260928-003',
          docType: DocType.sale,
          status: DocStatus.confirmed,
          totalAmount: 123456,
          paidAmount: 0,
          occurredAt: t,
          createdAt: t,
          updatedAt: t,
        ),
        partyName: '王老板',
      ),
    ]);
    check('单据：类型 / 状态中文 + 对方散客 + 日期只到日（§BG 方案甲）',
        docs.header.join(',') == '单号,单据类型,对方,金额,已收付,状态,日期' &&
            docs.rows[0].join('|') ==
                'XS20260928-002|店内销售|散客|12.50|12.50|已结清|2026-09-28');

    final ExportTable flow = partyFlowExportTable(
      flow: <PartyFlowEntry>[
        PartyFlowEntry(
          seqNo: 1,
          documentId: 'd1',
          docNo: 'SK20260928-001',
          docType: DocType.receipt,
          amount: -20000,
          occurredAt: t,
          timeEstimated: false,
        ),
      ],
    );
    check('往来流水：保留金额符号（收款单是负数）',
        flow.header.join(',') == '单号,单据类型,金额,日期' &&
            flow.rows[0][2] == '-200.00');

    // ⚠️ 金额不带千分位（2026-09-28 裁定）：谁把导出换成 `Money.formatGrouped`，
    // 这一条立刻红 —— 否则用户拿到的是「看着是钱、Excel 不认」的文本
    final List<ExportTable> all = <ExportTable>[
      products,
      stock,
      parties,
      docs,
      flow,
    ];
    final ({List<String> grouped, int plainCount}) audit = auditAmounts(all);
    check('五张表的金额都不带千分位（否则 Excel 当文本、求和漏数）',
        audit.grouped.isEmpty && audit.plainCount >= 5,
        audit.grouped.isEmpty
            ? '金额单元格只有 ${audit.plainCount} 个 → 断言可能空转'
            : audit.grouped.join('、'));
    check('大额行确实存在（1234.56 而非 1,234.56）—— 否则上面那条抓不到分组',
        docs.rows.any((List<String> r) => r.contains('1234.56')));

    // 哨兵：证明「检测器本身有效」。**没有这一条，上面两个 ✓ 可能是瞎的**
    // （首轮就栽在这里：夹具全是 12.50，把 formatGrouped 换进去照样全绿）
    const ExportTable trap = ExportTable(
      label: '哨兵',
      header: <String>['金额'],
      rows: <List<String>>[
        <String>['1,234.56'],
      ],
    );
    check('千分位检测器本身有效（哨兵能被抓到）',
        auditAmounts(<ExportTable>[trap]).grouped.isNotEmpty);
  }

  // ============================================================ 汇总
  stdout.writeln(
    '\n自检完成：$_pass 过，$_fail 挂'
    '${_failures.isEmpty ? '' : '  →  ${_failures.join('；')}'}',
  );
  if (_fail > 0) exit(1);
}
