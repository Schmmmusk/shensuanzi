// 导出（`ExportService` / 文件名 / 表格映射 / 结果文案）的测试（§AF）。
//
// 覆盖：文件名规则与非法字符清洗（AF-7）/ 空结果不生成文件（遗漏 4）/
// 目录自动创建（AF-3）/ 目录不可写说「怎么办」（遗漏 9）/ 同名并发单飞
// （遗漏 2，不同表不串味）/ 结果文案三分支（遗漏 5）/ 五张表的列与值（AF-9）。
//
// ⚠️ 导出**不碰数据库**（表格由调用方喂进来），所以本文件不需要 SQLite。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

void main() {
  final DateTime base = DateTime(2026, 9, 28, 15, 30);
  final int t = DateTime(2026, 9, 28, 10).millisecondsSinceEpoch;

  Product product({
    String id = 'p1',
    String code = 'P0001',
    String name = '可乐',
    String? barcode = '6901234567890',
    String unit = '瓶',
    int sellPrice = 300,
    int costPrice = 200,
    int safetyStock = 5,
    bool isActive = true,
  }) => Product(
    id: id,
    code: code,
    name: name,
    barcode: barcode,
    unit: unit,
    sellPrice: sellPrice,
    costPrice: costPrice,
    safetyStock: safetyStock,
    isActive: isActive,
    createdAt: t,
    updatedAt: t,
  );

  Party party({
    String id = 'y1',
    String name = '王老板',
    String? phone = '13800000000',
    String? address = '城南菜市场 3 号',
    List<PartyRole> roles = const <PartyRole>[PartyRole.customer],
    bool isActive = true,
  }) => Party(
    id: id,
    name: name,
    phone: phone,
    address: address,
    roles: roles,
    isActive: isActive,
    createdAt: t,
    updatedAt: t,
  );

  Document document({
    String id = 'd1',
    String docNo = 'CG20260928-001',
    DocType type = DocType.purchase,
    DocStatus status = DocStatus.confirmed,
    int totalAmount = 1250,
    int paidAmount = 500,
  }) => Document(
    id: id,
    docNo: docNo,
    docType: type,
    status: status,
    totalAmount: totalAmount,
    paidAmount: paidAmount,
    occurredAt: t,
    createdAt: t,
    updatedAt: t,
  );

  // ============================================================ 文件名

  group('ExportFileName（AF-7）', () {
    test('商品：神算子-商品-20260928.csv（中文、无空格）', () {
      expect(
        ExportFileName(label: '商品', date: base).fileName,
        '神算子-商品-20260928.csv',
      );
    });

    test('单据带时间范围段', () {
      expect(
        ExportFileName(
          label: '单据',
          date: base,
          from: DateTime(2026, 6, 1),
        ).fileName,
        '神算子-单据-20260928-20260601至20260928.csv',
      );
    });

    test('往来流水带往来方名 —— 否则导三个客户文件名全一样', () {
      expect(
        ExportFileName(label: '往来流水', date: base, extra: '王老板').fileName,
        '神算子-往来流水-王老板-20260928.csv',
      );
    });

    test('往来方名里的非法字符被清洗（用户输入什么都可能有）', () {
      expect(ExportFileName.sanitize('王老板/李老板'), '王老板_李老板');
      expect(ExportFileName.sanitize(r'甲:乙|丙?丁*戊"己"'), '甲_乙_丙_丁_戊_己_');
      expect(ExportFileName.sanitize('结尾带点..'), '结尾带点');
      expect(ExportFileName.sanitize('   '), '未命名');
      expect(ExportFileName.sanitize(''), '未命名');
      expect(
        ExportFileName.sanitize('长' * 60).length,
        40,
        reason: '压长度防 Windows 路径过长',
      );
      expect(
        ExportFileName(label: '往来流水', date: base, extra: 'A/B').fileName,
        '神算子-往来流水-A_B-20260928.csv',
      );
    });
  });

  // ============================================================ 服务

  group('ExportService（真实目录）', () {
    late Directory box;
    late String exportDir;
    late ExportService service;

    setUp(() {
      box = Directory.systemTemp.createTempSync('shensuanzi_export_');
      exportDir = p.join(box.path, '神算子导出');
      service = ExportService(exportDirectory: exportDir, now: () => base);
    });

    tearDown(() {
      try {
        box.deleteSync(recursive: true);
      } catch (_) {
        // 删不掉不影响结论
      }
    });

    ExportTable table({int rows = 1}) => ExportTable(
      label: '商品',
      header: const <String>['编码', '商品名称'],
      rows: <List<String>>[
        for (int i = 0; i < rows; i++) <String>['P000$i', '可乐$i'],
      ],
    );

    test('写成功：目录自动创建 + BOM + 表头 + 行数（AF-3）', () async {
      expect(Directory(exportDir).existsSync(), isFalse, reason: '第一次导出时还不存在');

      final ExportOutcome outcome = await service.write(table(rows: 3));

      final ExportSuccess success = outcome as ExportSuccess;
      expect(success.rowCount, 3);
      expect(
        p.basename(success.path),
        '神算子-商品-20260928.csv',
      );
      expect(File(success.path).existsSync(), isTrue);

      final Uint8List bytes = File(success.path).readAsBytesSync();
      expect(bytes.sublist(0, 3), csvBom);
      // ⚠️ 必须用 `utf8.decode`，不能用 `String.fromCharCodes` ——
      // 后者按 Latin-1 逐字节取值，中文会解成 `ç¼ç ` 这种乱码，
      // 断言必然失败（且失败信息里看不出是**解码**错了）。
      expect(
        utf8.decode(bytes.sublist(3)),
        contains('编码,商品名称'),
      );
    });

    test('0 行 → ExportEmpty，**连目录都不建**（遗漏 4）', () async {
      final ExportOutcome outcome = await service.write(table(rows: 0));

      expect(outcome, isA<ExportEmpty>());
      expect(exportOutcomeMessage(outcome), contains('没有数据'));
      // ⚠️ 不能用 `listSync()` 去证明「目录是空的」——空结果时目录**根本不存在**，
      // `listSync` 会抛 `PathNotFoundException`（本用例首轮就是这么红的）。
      // 空结果在可写探测之前就返回了，所以更强的断言是「目录都没被创建」。
      expect(
        Directory(exportDir).existsSync(),
        isFalse,
        reason: '只写表头的 CSV 会让用户以为「导出坏了」；空结果连目录都不必建',
      );
    });

    test('目录不可写 → ExportFailed 且说「怎么办」（遗漏 9）', () async {
      // 路径上蹲一个同名文件（真实场景：U 盘拔了、被改名占位）
      File(exportDir).writeAsStringSync('占位');
      final ExportService blocked = ExportService(
        exportDirectory: exportDir,
        now: () => base,
      );

      final ExportOutcome outcome = await blocked.write(table());
      final ExportFailed failed = outcome as ExportFailed;
      expect(failed.reason, contains('导出文件夹'));
      expect(
        exportOutcomeMessage(outcome),
        startsWith('导出失败：'),
        reason: 'SnackBar 要能直接展示',
      );
    });

    test('同名并发 → 同一个 Future（遗漏 2）；不同表不串味', () async {
      final ExportTable a = table();
      final ExportTable b = ExportTable(
        label: '库存',
        header: const <String>['编码'],
        rows: const <List<String>>[
          <String>['P0001'],
        ],
      );

      final Future<ExportOutcome> first = service.write(a);
      final Future<ExportOutcome> second = service.write(a);
      final Future<ExportOutcome> other = service.write(b);

      expect(identical(first, second), isTrue, reason: '狂点两次只写一份');
      expect(identical(first, other), isFalse, reason: '不同表不能复用结果');

      expect(await first, isA<ExportSuccess>());
      final ExportSuccess different = await other as ExportSuccess;
      expect(p.basename(different.path), '神算子-库存-20260928.csv');
    });

    test('结果文案三分支（遗漏 5：成功带完整路径）', () async {
      final ExportOutcome ok = await service.write(table(rows: 2));
      expect(exportOutcomeMessage(ok), contains('已导出 2 条到'));
      expect(exportOutcomeMessage(ok), contains(exportDir));
      expect(
        exportOutcomeMessage(const ExportEmpty()),
        contains('没有数据'),
      );
      expect(
        exportOutcomeMessage(const ExportFailed('磁盘满了')),
        '导出失败：磁盘满了',
      );
    });
  });

  // ============================================================ 表格映射

  group('导出表格（AF-9：列名与值都是业务语言）', () {
    test('商品：含编码与状态；条码为空写空串；金额是元', () {
      final ExportTable export = productExportTable(<Product>[
        product(),
        product(id: 'p2', code: 'P0002', name: '停用货', barcode: null, isActive: false),
      ]);

      expect(export.label, '商品');
      expect(export.header, <String>[
        '编码',
        '商品名称',
        '条码',
        '单位',
        '售价',
        '进价',
        '安全库存',
        '状态',
      ]);
      expect(export.rows.first, <String>[
        'P0001',
        '可乐',
        '6901234567890',
        '瓶',
        '3.00',
        '2.00',
        '5',
        '启用',
      ]);
      expect(export.rows[1][2], '', reason: '空条码不留 null 字面量');
      expect(export.rows[1].last, '停用', reason: 'AF-12：含停用，要有状态列');
    });

    test('库存：只出账面或在途不为 0 的行；在店可售 = 账面 − 在途', () {
      final List<Product> products = <Product>[
        product(),
        product(id: 'p2', code: 'P0002', name: '卖光了'),
        product(id: 'p3', code: 'P0003', name: '停用但有货', isActive: false),
        product(id: 'p4', code: 'P0004', name: '净零'),
      ];
      final ExportTable export = stockExportTable(
        products: products,
        book: <String, int>{'p1': 10, 'p3': 4, 'p4': 0},
        inTransit: <String, int>{'p1': 3},
        cost: <String, int>{'p1': 800, 'p3': 400},
      );

      expect(export.header[7], '库存成本', reason: 'AF-9：说清是总值');
      expect(
        export.rows.map((List<String> r) => r[1]).toList(),
        <String>['可乐', '停用但有货'],
        reason: '「卖光了」（无流水无在途）与「净零」都不出 —— 与库存页同口径',
      );
      expect(export.rows.first[4], '10');
      expect(export.rows.first[5], '3');
      expect(export.rows.first[6], '7');
      expect(export.rows.first[7], '8.00');
      expect(export.rows[1].last, '停用');
    });

    test('往来方：应收 / 应付分两列、不用负数（AF-9）', () {
      final ExportTable export = partyExportTable(
        parties: <Party>[
          party(),
          party(id: 'y2', name: '供应商甲', roles: const <PartyRole>[PartyRole.supplier]),
          party(id: 'y3', name: '两清'),
        ],
        balances: <String, int>{'y1': 12345, 'y2': -6789, 'y3': 0},
      );

      expect(export.header, <String>['往来方', '角色', '电话', '地址', '应收', '应付', '状态']);
      expect(export.rows[0].sublist(4), <String>['123.45', '0.00', '启用']);
      expect(export.rows[1].sublist(4), <String>['0.00', '67.89', '启用']);
      expect(export.rows[1][1], '供应商');
      expect(export.rows[2].sublist(4), <String>['0.00', '0.00', '启用']);
    });

    test('单据：类型 / 状态中文、对方散客、日期带时分（AF-9 + 遗漏 6）', () {
      final ExportTable export = documentExportTable(<DocumentSummary>[
        DocumentSummary(
          document: document(status: DocStatus.settled),
          partyName: '王老板',
        ),
        DocumentSummary(
          document: document(
            id: 'd2',
            docNo: 'XS20260928-002',
            type: DocType.sale,
            status: DocStatus.confirmed,
          ),
          partyName: null,
        ),
      ]);

      expect(export.header, <String>[
        '单号',
        '单据类型',
        '对方',
        '金额',
        '已收付',
        '状态',
        '日期',
      ]);
      expect(export.rows.first, <String>[
        'CG20260928-001',
        '采购入库',
        '王老板',
        '12.50',
        '5.00',
        '已结清',
        '2026-09-28 10:00',
      ]);
      expect(export.rows[1][2], '散客', reason: '不留空白（AF-9）');
      expect(export.rows[1][1], '店内销售');
    });

    test('往来流水：保留金额符号（正 = 对方欠我增加）', () {
      final ExportTable export = partyFlowExportTable(
        flow: <PartyFlowEntry>[
          PartyFlowEntry(
            seqNo: 1,
            documentId: 'd1',
            docNo: 'XS20260928-001',
            docType: DocType.sale,
            amount: 20000,
            occurredAt: t,
            timeEstimated: false,
          ),
          PartyFlowEntry(
            seqNo: 2,
            documentId: 'd2',
            docNo: 'SK20260928-001',
            docType: DocType.receipt,
            amount: -20000,
            occurredAt: t,
            timeEstimated: false,
          ),
        ],
      );

      expect(export.header, <String>['单号', '单据类型', '金额', '日期']);
      expect(export.rows[0].sublist(1), <String>['店内销售', '200.00', formatDateTime(t)]);
      expect(
        export.rows[1][2],
        '-200.00',
        reason: '收款单是负数 —— 口径是「对方欠我减少」，不是「收了多少」',
      );
    });
  });
}
