// 单据列表的排序口径（**#26①** / 台账 §CV·六十二 Q1 甲）。
//
// ## 为什么有这个文件
//
// 用户 2026-10-18 给出 5 张单的实证：列表自上而下是
// `SK-006(18:06) → SK-003(16:53) → XT-002(16:50) → XT-001(16:48) → XS-008(21:11)`，
// 而 **21:11 那张主单排在最后一行**。根因不是排序写错，是 **`occurred_at` 一列两套口径**：
//
// - 主单：`occurred_at` = **当天 00:00**（开单页只能选到日，§BG 方案甲，`sale_draft.dart:493`）
// - 退货 / 手记收付款：`occurred_at` = **精确时刻**（`return_service.dart:252` / `settlement_service.dart:343`）
//
// ⇒ `ORDER BY occurred_at DESC, created_at DESC` 里 `created_at` 那段**永不生效**，
// 同一天的派生单全压在主单上面。列表页自己的文案却承诺「同一天按**录入时间**倒序」
// （`documents_page.dart:254-255`）—— **文案对、实现偏**，按纪律 17 改实现。
//
// 修法：**按「日」分桶，日内按 `created_at` 倒序**。
//
// ⚠️ 纯 Dart 测试：`dart test`（Windows 需要可用的 SQLite 原生库，见 `lib/sqlite_local.dart`）。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late DocumentDao documents;

  setUp(() {
    resetClock();
    db = newMemoryDb();
    documents = DocumentDao(db);
  });

  tearDown(() => db.close());

  /// 本地时区的某一刻（与 `sale_draft` / `return_service` 的取法一致）
  int at(int year, int month, int day, [int hour = 0, int minute = 0]) =>
      DateTime(year, month, day, hour, minute).millisecondsSinceEpoch;

  List<String> docNosOf(List<DocumentSummary> rows) =>
      rows.map((DocumentSummary e) => e.document.docNo).toList();

  group('单据列表排序（#26①）', () {
    test('同一天：主单按「录入时刻」参与排序，不再被派生单压在下面', () {
      // ⚠️ 这 5 张单就是用户实证的复刻（单号、时刻、类型全一致）。
      // 主单 occurred_at 是当天 00:00，created_at 是 21:11 —— 这是关键：
      // 旧实现下 00:00 < 16:48 ⇒ 主单永远排最后。
      final int midnight = at(2026, 10, 12);
      insertDocument(
        db.raw,
        'd-sale',
        docNo: 'XS20261012-008',
        docType: 'sale',
        totalAmount: 500,
        occurredAt: midnight,
        createdAt: at(2026, 10, 12, 21, 11),
      );
      insertDocument(
        db.raw,
        'd-rcv-003',
        docNo: 'SK20261012-003',
        docType: 'receipt',
        totalAmount: 100,
        refDocId: 'd-sale',
        occurredAt: at(2026, 10, 12, 16, 53),
      );
      insertDocument(
        db.raw,
        'd-rcv-006',
        docNo: 'SK20261012-006',
        docType: 'receipt',
        totalAmount: 100,
        refDocId: 'd-sale',
        occurredAt: at(2026, 10, 12, 18, 6),
      );
      insertDocument(
        db.raw,
        'd-ret-001',
        docNo: 'XT20261012-001',
        docType: 'sale_return',
        totalAmount: 12000,
        refDocId: 'd-sale',
        occurredAt: at(2026, 10, 12, 16, 48),
      );
      insertDocument(
        db.raw,
        'd-ret-002',
        docNo: 'XT20261012-002',
        docType: 'sale_return',
        totalAmount: 12000,
        refDocId: 'd-sale',
        occurredAt: at(2026, 10, 12, 16, 50),
      );

      // `includeDerived: true` = 用户筛了「收款 / 销售退货」时的形状（实证截图就是它）
      final List<String> order = docNosOf(
        documents.listDocuments(includeDerived: true),
      );

      expect(
        order,
        <String>[
          'XS20261012-008', // 21:11 —— 最新，必须在第一行
          'SK20261012-006', // 18:06
          'SK20261012-003', // 16:53
          'XT20261012-002', // 16:50
          'XT20261012-001', // 16:48
        ],
        reason:
            '同一天里必须按录入时刻倒序；主单的 occurred_at 是 00:00，'
            '不能因此被排到当天所有派生单的后面（#26①）',
      );
    });

    test('跨天仍按「单据日期」倒序（分桶没有把日期顺序搞反）', () {
      insertDocument(
        db.raw,
        'd-old',
        docNo: 'XS20261011-001',
        docType: 'sale',
        occurredAt: at(2026, 10, 11),
        createdAt: at(2026, 10, 11, 23, 30),
      );
      insertDocument(
        db.raw,
        'd-new',
        docNo: 'XS20261013-001',
        docType: 'sale',
        occurredAt: at(2026, 10, 13),
        createdAt: at(2026, 10, 13, 8, 0),
      );
      insertDocument(
        db.raw,
        'd-mid',
        docNo: 'XS20261012-001',
        docType: 'sale',
        occurredAt: at(2026, 10, 12),
        createdAt: at(2026, 10, 12, 9, 0),
      );

      expect(docNosOf(documents.listDocuments()), <String>[
        'XS20261013-001',
        'XS20261012-001',
        'XS20261011-001',
      ]);
    });

    test('补录：日期早、今天才录的单，进它自己那一天（不抢今天的头）', () {
      insertDocument(
        db.raw,
        'd-today',
        docNo: 'XS20261012-001',
        docType: 'sale',
        occurredAt: at(2026, 10, 12),
        createdAt: at(2026, 10, 12, 10, 0),
      );
      // 业务日期 10-01，录入时刻 10-12 22:00 —— 用户昨晚忘了录、今天补的
      insertDocument(
        db.raw,
        'd-backfill',
        docNo: 'XS20261001-001',
        docType: 'sale',
        occurredAt: at(2026, 10, 1),
        createdAt: at(2026, 10, 12, 22, 0),
      );

      expect(
        docNosOf(documents.listDocuments()),
        <String>['XS20261012-001', 'XS20261001-001'],
        reason: '补录的单按**业务日期**归位（10-01），不能因为录入晚就跑到 10-12 上面',
      );
    });

    // 3a（2026-10-24，业务审查 §3.7 P2 #1）：**未结清筛选以流水为准** ——
    // 从前用 `d.paid_amount` 缓存，注释却写「与 unsettledCentsOf 同一口径」
    // （那个口径读 settlements）。两者一旦漂移，列表说「未结清」而详情说
    // 「已收满」，用户看到的是两个互相打脸的数字。
    test('3a：#1 未结清以 settlements 为准（paid_amount 缓存脏了也不影响）', () {
      insertParty(db.raw, 'y-1', name: '王老板');
      insertDocument(
        db.raw,
        'd-1',
        docNo: 'XS20261012-001',
        docType: 'sale',
        partyId: 'y-1',
        totalAmount: 100,
      );
      // 缓存脏：paid_amount = 0，但流水里有一条 100 的核销
      db.raw.execute("UPDATE documents SET paid_amount = 0 WHERE id = 'd-1'");
      insertDocument(
        db.raw,
        'r-1',
        docNo: 'SK20261012-001',
        docType: 'receipt',
        totalAmount: 100,
      );
      db.raw.execute(
        "INSERT INTO settlements "
        "(id, receipt_doc_id, target_doc_id, amount, seq_no, created_at) "
        "VALUES ('s-1', 'r-1', 'd-1', 100, 1, 0)",
      );

      expect(
        docNosOf(
          documents.listDocuments(
            statusViews: <DocumentStatusView>{DocumentStatusView.unsettled},
          ),
        ),
        isNot(contains('XS20261012-001')),
        reason: '3a：流水说已收满 ⇒ 不该出现在未结清里（缓存 paid_amount=0 不算数）',
      );
      final DocumentSummary row = documents.listDocuments().firstWhere(
        (DocumentSummary e) => e.document.id == 'd-1',
      );
      expect(
        row.document.paidAmount,
        100,
        reason: '3a：列表行显示的「已收」也走流水 —— 否则行显示 0、筛掉它，自相矛盾',
      );
    });

    // P2 #14（2026-10-24，业务审查 §3.7）：默认只看根 —— 退货单不进默认
    // 列表；`includeDerived: true` 才进；导出恒全量（AF-12）。
    // 从前 DAO 默认 `rootsOnly: false`、UI 显式传 `true`，两套默认值。
    test('P2 #14：默认只看根（退货单不进）；includeDerived 才进；导出恒全量', () {
      insertDocument(
        db.raw,
        'd-sale',
        docNo: 'XS20261012-008',
        docType: 'sale',
        occurredAt: at(2026, 10, 12),
        createdAt: at(2026, 10, 12, 21, 11),
      );
      insertDocument(
        db.raw,
        'd-ret',
        docNo: 'XT20261012-001',
        docType: 'sale_return',
        totalAmount: 100,
        refDocId: 'd-sale',
        occurredAt: at(2026, 10, 12, 16, 48),
      );

      expect(
        docNosOf(documents.listDocuments()),
        <String>['XS20261012-008'],
        reason: 'P2 #14：默认视图只看根 —— 退货单从原单详情进，不混在列表里',
      );
      expect(
        docNosOf(documents.listDocuments(includeDerived: true)),
        contains('XT20261012-001'),
        reason: '显式要派生单才进',
      );
      expect(
        docNosOf(documents.listDocumentsForExport()),
        contains('XT20261012-001'),
        reason: '导出必须全量（AF-12：把数据带走，不许偷偷少东西）',
      );
      expect(documents.countDocuments(), 1, reason: '计数与列表同一口径');
    });

    test('导出与列表同一口径（共用 `_summaries`，顺序也必须一致）', () {
      insertDocument(
        db.raw,
        'd-sale',
        docNo: 'XS20261012-008',
        docType: 'sale',
        occurredAt: at(2026, 10, 12),
        createdAt: at(2026, 10, 12, 21, 11),
      );
      insertDocument(
        db.raw,
        'd-rcv',
        docNo: 'SK20261012-006',
        docType: 'receipt',
        refDocId: 'd-sale',
        occurredAt: at(2026, 10, 12, 18, 6),
      );

      expect(
        docNosOf(documents.listDocumentsForExport(includeDerived: true)),
        docNosOf(documents.listDocuments(includeDerived: true)),
      );
    });
  });

  // ---------------------------------------------------------------- 搜索（#26 批 2）
  //
  // 四路匹配：本单号 / 对方名 / **子单号** / **明细里的商品名**。
  // 后两路是「聚合后仍能找到那笔生意」的关键：用户手里可能只有退货单的号，
  // 或只记得「退过苹果」。
  group('单据搜索（#26 批 2）', () {
    /// 一张销售 + 一张挂它的退货单（退货明细里是**另一个**商品）+ 一张对照组
    ///
    /// ⚠️ `createdAt` 必须显式给：同一天的单靠它排序，不写就是赌 SQLite 的行序。
    void seedSearchFixture() {
      final int day = at(2026, 10, 12);
      insertProduct(db.raw, 'p-apple', code: 'P001', name: '红富士苹果');
      insertProduct(db.raw, 'p-pear', code: 'P002', name: '雪梨');
      insertParty(db.raw, 'y-wang', name: '王老板');
      insertParty(db.raw, 'y-li', name: '李姐');
      insertDocument(
        db.raw,
        'd-sale',
        docNo: 'XS20261012-008',
        docType: 'sale',
        partyId: 'y-wang',
        totalAmount: 500,
        occurredAt: day,
        createdAt: at(2026, 10, 12, 9, 0),
      );
      insertDocumentLine(
        db.raw,
        'l-sale',
        document: 'd-sale',
        product: 'p-apple',
        quantity: 1,
        unitPrice: 500,
      );
      // 退货单：单号不同、明细里是「雪梨」。⚠️ **部分退货单默认是显示的**
      //（2026-10-05 裁定：它是独立交易）—— 折叠要等批 3 的聚合。
      insertDocument(
        db.raw,
        'd-ret',
        docNo: 'XT20261012-002',
        docType: 'sale_return',
        partyId: 'y-wang',
        refDocId: 'd-sale',
        totalAmount: 500,
        occurredAt: at(2026, 10, 12, 16, 50),
      );
      insertDocumentLine(
        db.raw,
        'l-ret',
        document: 'd-ret',
        product: 'p-pear',
        quantity: 1,
        unitPrice: 500,
      );
      // 另一张不相关的单（对照组）
      insertDocument(
        db.raw,
        'd-other',
        docNo: 'XS20261012-009',
        docType: 'sale',
        partyId: 'y-li',
        totalAmount: 800,
        occurredAt: day,
        createdAt: at(2026, 10, 12, 10, 0),
      );
      insertDocumentLine(
        db.raw,
        'l-other',
        document: 'd-other',
        product: 'p-apple',
        quantity: 2,
        unitPrice: 400,
      );
    }

    test('按单号搜（含部分匹配）', () {
      seedSearchFixture();
      expect(
        docNosOf(documents.listDocuments(query: 'XS20261012-008')),
        <String>['XS20261012-008'],
      );
      expect(
        docNosOf(documents.listDocuments(query: 'XS20261012')),
        <String>['XS20261012-009', 'XS20261012-008'],
        reason: '部分匹配命中两张（同日按录入时刻倒序：10:00 在 09:00 前）',
      );
    });

    test('按对方名搜（默认只看根：退货单不进；显式 includeDerived 才进）', () {
      seedSearchFixture();
      // P2 #14（2026-10-24）：默认只看根。⚠️ 2026-10-05「部分退货单独立
      // 显示」已被 2026-10-18 甲案**废止**（`docs/reply.md`，§CV·六十三~六十七），
      // 本用例旧断言按过时裁定写，已改。
      expect(
        docNosOf(documents.listDocuments(query: '王老板')),
        <String>['XS20261012-008'],
        reason: 'P2 #14：默认视图只看根 —— 退货单从原单详情进',
      );
      expect(
        docNosOf(documents.listDocuments(query: '王老板', includeDerived: true)),
        <String>['XT20261012-002', 'XS20261012-008'],
        reason: '显式要派生单时照常出现（退货单仍是独立交易）',
      );
      expect(
        documents.listDocuments(query: '李姐').single.document.docNo,
        'XS20261012-009',
      );
      expect(documents.listDocuments(query: '不存在的名字'), isEmpty);
    });

    test('按**子单号**搜 ⇒ 主单也被命中（聚合后仍找得到那笔生意）', () {
      seedSearchFixture();
      // 只留销售类 ⇒ 命中的主单只能是「按子单号」这一路来的
      //（主单自己没有这个号，退货单又被类型筛掉了）
      expect(
        docNosOf(
          documents.listDocuments(
            query: 'XT20261012-002',
            types: <DocType>{DocType.sale},
          ),
        ),
        <String>['XS20261012-008'],
        reason: '用户手里只有退货单号，也要能找到那笔生意',
      );
    });

    test('按**商品名**搜 ⇒ 子单明细里的商品也能把主单揪出来', () {
      seedSearchFixture();
      // 苹果：两张销售单自己的明细里都有
      expect(docNosOf(documents.listDocuments(query: '苹果')), <String>[
        'XS20261012-009',
        'XS20261012-008',
      ]);
      // 雪梨：**主单自己的明细里没有**，只在退货单（子单）的明细里 ⇒
      // 只查 `l.document_id = d.id` 会漏掉（审查盲点 ②）
      expect(
        docNosOf(
          documents.listDocuments(query: '雪梨', types: <DocType>{DocType.sale}),
        ),
        <String>['XS20261012-008'],
        reason: '审查盲点 ②：子单明细里的商品必须能命中主单',
      );
    });

    test('通配符必须被转义：搜「50%」不能变成全表、搜「_」不能命中所有单', () {
      final int day = at(2026, 10, 12);
      insertParty(db.raw, 'y-pct', name: '50%折扣店');
      insertParty(db.raw, 'y-plain', name: '张三');
      insertDocument(
        db.raw,
        'd-pct',
        docNo: 'XS20261012-001',
        docType: 'sale',
        partyId: 'y-pct',
        occurredAt: day,
      );
      insertDocument(
        db.raw,
        'd-plain',
        docNo: 'XS20261012-002',
        docType: 'sale',
        partyId: 'y-plain',
        occurredAt: day,
      );

      expect(
        docNosOf(documents.listDocuments(query: '50%')),
        <String>['XS20261012-001'],
        reason: '不转义的话 `%` 是通配符 ⇒ 两张单都会命中',
      );
      expect(
        documents.listDocuments(query: '_'),
        isEmpty,
        reason: '不转义的话 `_` = 任意一个字符 ⇒ 全部命中',
      );
    });

    test('搜索与类型 / 状态筛选取交集，导出同口径', () {
      seedSearchFixture();
      expect(
        docNosOf(
          documents.listDocuments(
            query: '王老板',
            types: <DocType>{DocType.saleReturn},
            includeDerived: true,
          ),
        ),
        <String>['XT20261012-002'],
        reason: '明确筛退货类目 + 搜索 ⇒ 只留退货单本身',
      );

      // P2 #14：列表默认只看根、导出恒全量 —— AF-5 的「同口径」指
      // **同一份筛选条件**（搜索词/类型/状态/时间），不是同一份可见集合；
      // 比较时列表要显式 `includeDerived: true`（AF-12：导出把数据带走）。
      final List<String> list = docNosOf(
        documents.listDocuments(query: '王老板', includeDerived: true),
      );
      final List<String> export = docNosOf(
        documents.listDocumentsForExport(query: '王老板'),
      );
      expect(export, list, reason: 'AF-5：导出 = 列表（显式含派生）的同一份筛选（含搜索词）');
      expect(
        docNosOf(documents.listDocuments(query: '王老板')),
        isNot(contains('XT20261012-002')),
        reason: 'P2 #14：默认列表不含派生单',
      );
    });
  });

  // ------------------------------------------------- 生命周期聚合（#26 批 3 甲案）
  //
  // 根 = `ref_doc_id IS NULL`（主单 + 手记收付款），子 = 自动收付款 / 退货。
  // ⚠️ 这**推翻了 2026-10-05 裁定**「正常部分退货单必须独立占行」
  //（`docs/reply.md` 2026-10-18：甲案 + 强制补偿）。
  group('生命周期聚合（#26 批 3）', () {
    /// 一张销售 + 2 张退货 + 2 张自动收款 + 1 张手记收款
    void seedLifecycle() {
      final int day = at(2026, 10, 12);
      insertParty(db.raw, 'y-wang', name: '王老板');
      insertDocument(
        db.raw,
        'd-sale',
        docNo: 'XS20261012-008',
        docType: 'sale',
        partyId: 'y-wang',
        totalAmount: 24000,
        occurredAt: day,
        createdAt: at(2026, 10, 12, 9, 0),
      );
      insertDocument(
        db.raw,
        'd-ret-1',
        docNo: 'XT20261012-001',
        docType: 'sale_return',
        partyId: 'y-wang',
        refDocId: 'd-sale',
        totalAmount: 12000,
        occurredAt: at(2026, 10, 12, 16, 48),
      );
      insertDocument(
        db.raw,
        'd-ret-2',
        docNo: 'XT20261012-002',
        docType: 'sale_return',
        partyId: 'y-wang',
        refDocId: 'd-sale',
        totalAmount: 12000,
        occurredAt: at(2026, 10, 12, 16, 50),
      );
      insertDocument(
        db.raw,
        'd-rcv-1',
        docNo: 'SK20261012-003',
        docType: 'receipt',
        partyId: 'y-wang',
        refDocId: 'd-sale',
        totalAmount: 100,
        occurredAt: day,
        createdAt: at(2026, 10, 12, 16, 53),
      );
      insertDocument(
        db.raw,
        'd-rcv-2',
        docNo: 'SK20261012-006',
        docType: 'receipt',
        partyId: 'y-wang',
        refDocId: 'd-sale',
        totalAmount: 100,
        occurredAt: day,
        createdAt: at(2026, 10, 12, 18, 6),
      );
      // 手记收款（`ref_doc_id IS NULL`）= 自己就是根
      insertDocument(
        db.raw,
        'd-manual',
        docNo: 'SK20261012-009',
        docType: 'receipt',
        partyId: 'y-wang',
        totalAmount: 500,
        occurredAt: at(2026, 10, 12, 10, 30),
      );
      insertSettlement(
        db.raw,
        's-1',
        receiptDoc: 'd-rcv-1',
        targetDoc: 'd-sale',
        amount: 100,
      );
      insertSettlement(
        db.raw,
        's-2',
        receiptDoc: 'd-rcv-2',
        targetDoc: 'd-sale',
        amount: 100,
      );
    }

    test('只列根：一笔生意一行，退货 / 自动收款被折叠', () {
      seedLifecycle();
      expect(
        docNosOf(documents.listDocuments(rootsOnly: true)),
        <String>['SK20261012-009', 'XS20261012-008'],
        reason: '根 = 销售 + 手记收款；退货与自动收款都是子单',
      );
    });

    test('行内摘要的两个数：退货次数 + 金额、核销笔数', () {
      seedLifecycle();
      final DocumentSummary sale = documents
          .listDocuments(rootsOnly: true)
          .firstWhere((DocumentSummary e) => e.document.id == 'd-sale');

      expect(sale.returnedCount, 2, reason: '退过 2 次');
      expect(sale.returnedCents, 24000, reason: '两次各 ¥120');
      expect(sale.settlementCount, 2, reason: '被 2 张收款核销过');
    });

    test('明确筛子类型 ⇒ 平铺（否则「收款」会一片空白）', () {
      seedLifecycle();
      // 聚合模式下筛「收款」⇒ 只剩**手记**那张（自动收款是子单，被折进主单）
      expect(
        docNosOf(
          documents.listDocuments(
            rootsOnly: true,
            types: <DocType>{DocType.receipt},
          ),
        ),
        <String>['SK20261012-009'],
        reason:
            '手记收款自己就是根；自动收款是子单 ⇒ '
            '所以 UI 一旦筛了子类目就必须切平铺，否则用户以为收款单没了',
      );
      // 平铺模式下三张收款都在
      expect(
        docNosOf(
          documents.listDocuments(
            types: <DocType>{DocType.receipt},
            includeDerived: true,
          ),
        ),
        <String>['SK20261012-006', 'SK20261012-003', 'SK20261012-009'],
      );
    });

    test('聚合后搜索仍能找到那笔生意（子单号 / 子单商品名）', () {
      seedLifecycle();
      expect(
        docNosOf(
          documents.listDocuments(rootsOnly: true, query: 'XT20261012-002'),
        ),
        <String>['XS20261012-008'],
        reason: '退货单被折叠了，但按它的单号仍要能搜到主单',
      );
    });

    test('**手记收款**（核销一张单）也必须折进那张单 —— 用户复跑抓出的缺口', () {
      // 复现真实路径：赊账销售 → 详情页点 [收款] ⇒ `SettlementService.settle`
      // 生成的收款单 **`ref_doc_id` 是 NULL**（关联只存在 `settlements` 里），
      // 所以「根 = ref_doc_id IS NULL」会把它当成独立的根 ⇒ 列表里仍然是两行，
      // 用户还得自己找「这张单的收款单」。
      final int day = at(2026, 10, 12);
      insertParty(db.raw, 'y-li', name: '李姐');
      insertDocument(
        db.raw,
        'd-sale',
        docNo: 'XS20261012-001',
        docType: 'sale',
        partyId: 'y-li',
        totalAmount: 10000,
        occurredAt: day,
        createdAt: at(2026, 10, 12, 9, 0),
      );
      insertDocument(
        db.raw,
        'd-rcv',
        docNo: 'SK20261012-003',
        docType: 'receipt',
        partyId: 'y-li',
        totalAmount: 10000,
        occurredAt: at(2026, 10, 12, 16, 53),
      );
      insertSettlement(
        db.raw,
        's-1',
        receiptDoc: 'd-rcv',
        targetDoc: 'd-sale',
        amount: 10000,
      );

      final List<DocumentSummary> rows = documents.listDocuments(
        rootsOnly: true,
      );
      expect(docNosOf(rows), <String>[
        'XS20261012-001',
      ], reason: '核销了一张单的收款单 = 那笔生意的「已收」，不能再占一行');
      expect(rows.single.settlementCount, 1);
    });

    test('无核销的收款单 / 一张收款核销多张单 ⇒ 仍是独立的根（不能硬塞）', () {
      final int day = at(2026, 10, 12);
      // ① 客户直接给钱、没对应单据（0 个核销目标）
      insertDocument(
        db.raw,
        'd-cash',
        docNo: 'SK20261012-001',
        docType: 'receipt',
        totalAmount: 500,
        occurredAt: at(2026, 10, 12, 8, 0),
      );
      // ② 一张收款同时结清两张单（多目标 ⇒ 归不到任何一笔生意）
      insertDocument(
        db.raw,
        'd-a',
        docNo: 'XS20261012-002',
        docType: 'sale',
        totalAmount: 1000,
        occurredAt: day,
      );
      insertDocument(
        db.raw,
        'd-b',
        docNo: 'XS20261012-003',
        docType: 'sale',
        totalAmount: 1000,
        occurredAt: day,
      );
      insertDocument(
        db.raw,
        'd-split',
        docNo: 'SK20261012-004',
        docType: 'receipt',
        totalAmount: 2000,
        occurredAt: at(2026, 10, 12, 17, 0),
      );
      insertSettlement(
        db.raw,
        's-a',
        receiptDoc: 'd-split',
        targetDoc: 'd-a',
        amount: 1000,
      );
      insertSettlement(
        db.raw,
        's-b',
        receiptDoc: 'd-split',
        targetDoc: 'd-b',
        amount: 1000,
      );

      final List<String> nos = docNosOf(
        documents.listDocuments(rootsOnly: true),
      );
      expect(nos, contains('SK20261012-001'), reason: '没核销目标的收款是独立交易');
      expect(nos, contains('SK20261012-004'), reason: '一收多单归不到哪一笔，必须留着');
      expect(nos, contains('XS20261012-002'));
      expect(nos, contains('XS20261012-003'));
    });

    test('严禁 N+1：列表路径**不许**调逐行查询（200 行 = 200 次 SQL）', () {
      // 造 60 张根单，每张 1 次退货 + 1 笔核销
      for (int i = 0; i < 60; i++) {
        final String id = 'd-$i';
        insertDocument(
          db.raw,
          id,
          docNo: 'XS20261012-${i.toString().padLeft(3, '0')}',
          docType: 'sale',
          totalAmount: 1000,
          occurredAt: at(2026, 10, 12),
          createdAt: at(2026, 10, 12, 9, 0) + i,
        );
        insertDocument(
          db.raw,
          'r-$i',
          docNo: 'XT20261012-${i.toString().padLeft(3, '0')}',
          docType: 'sale_return',
          refDocId: id,
          totalAmount: 100,
          occurredAt: at(2026, 10, 12, 16, 0) + i,
        );
        insertSettlement(
          db.raw,
          'st-$i',
          receiptDoc: id,
          targetDoc: id,
          amount: 100,
        );
      }

      // 子类把「逐行查」的入口全部改成抛错 —— 列表只要走一次就炸
      final _NoNPlusOneDao guarded = _NoNPlusOneDao(db);
      final List<DocumentSummary> rows = guarded.listDocuments(rootsOnly: true);

      expect(rows.length, 60);
      expect(rows.every((DocumentSummary e) => e.returnedCount == 1), isTrue);
      expect(rows.every((DocumentSummary e) => e.settlementCount == 1), isTrue);
    });
  });

  // 批 3 第 16 条（用户裁定 ①）：`countDocuments` 与 `listDocuments`
  // **必须逐字一致** —— 它俩共用一个 `_docFilter` / `_docFrom`，这个测试
  // 就是那条共用的机械保证：任何一边改了条件而另一边没跟上，这里立刻红。
  // 4c（2026-10-24，§CV·九十九）：列表页从「一条大 SQL」拆成**两段**
  // （先取 200 个 id → 只对这 200 个 id 聚合），456 → 143 ms（3.1×）。
  //
  // 拆两段引入两个**只有测试能抓**的风险：
  //  ① `WHERE id IN (…)` 的返回顺序 SQLite **不保证** ⇒ 必须按第一段的 id
  //     顺序在内存重排。下面第一条用例故意造「期望顺序 ≠ rowid 顺序」。
  //  ② 第二段的派生表（已退 / 已收）若漏了 `IN (ids)` 限制或漏 JOIN，
  //     聚合值会变成 0 —— 第二条用例钉住三个聚合列。
  group('两段查询（4c）', () {
    test('截断后顺序仍按「日桶 + 录入时刻」—— 不是 rowid 顺序', () {
      // 插入顺序（= rowid 顺序）：A 最旧 → B 最新 → C 居中
      // 期望顺序：[B, C, A] —— 与 rowid 顺序**完全不同**，
      // 第二段若直接按返回顺序拼装，这条必红。
      insertDocument(
        db.raw,
        'a',
        docNo: 'XS-A',
        docType: 'sale',
        occurredAt: at(2026, 10, 10),
        createdAt: at(2026, 10, 10, 9),
      );
      insertDocument(
        db.raw,
        'b',
        docNo: 'XS-B',
        docType: 'sale',
        occurredAt: at(2026, 10, 12),
        createdAt: at(2026, 10, 12, 9),
      );
      insertDocument(
        db.raw,
        'c',
        docNo: 'XS-C',
        docType: 'sale',
        occurredAt: at(2026, 10, 11),
        createdAt: at(2026, 10, 11, 9),
      );

      expect(
        docNosOf(documents.listDocuments(limit: 3)),
        <String>['XS-B', 'XS-C', 'XS-A'],
        reason: '4c：第二段必须按第一段的 id 顺序重排',
      );
      expect(docNosOf(documents.listDocuments(limit: 2)), <String>[
        'XS-B',
        'XS-C',
      ]);
      expect(docNosOf(documents.listDocuments(limit: 1)), <String>['XS-B']);
    });

    test('三个聚合列（已退 / 已收 / 核销笔数）在两段路径下不漏', () {
      insertParty(db.raw, 'y-1', name: '王老板');
      insertDocument(
        db.raw,
        'd-1',
        docNo: 'XS-1',
        docType: 'sale',
        partyId: 'y-1',
        totalAmount: 1000,
        occurredAt: at(2026, 10, 12),
      );
      // 部分退货 300（派生单，默认不进列表，但列表行要显示「已退 ¥3.00」）
      insertDocument(
        db.raw,
        'd-ret',
        docNo: 'XT-1',
        docType: 'sale_return',
        refDocId: 'd-1',
        totalAmount: 300,
        occurredAt: at(2026, 10, 12, 10),
      );
      // 收款核销 400
      insertDocument(
        db.raw,
        'd-rec',
        docNo: 'SK-1',
        docType: 'receipt',
        totalAmount: 400,
        occurredAt: at(2026, 10, 12, 11),
      );
      db.raw.execute(
        'INSERT INTO settlements '
        '(id, receipt_doc_id, target_doc_id, amount, seq_no, created_at) '
        "VALUES ('s-1', 'd-rec', 'd-1', 400, 1, 0)",
      );

      final DocumentSummary row = documents.listDocuments().firstWhere(
        (DocumentSummary e) => e.document.id == 'd-1',
      );
      expect(row.returnedCents, 300, reason: '已退额来自派生表 r');
      expect(row.returnedCount, 1);
      expect(row.document.paidAmount, 400, reason: '已收来自派生表 s（流水口径）');
      expect(row.settlementCount, 1, reason: '核销笔数不能因为拆两段而丢');
    });

    test('limit 大于命中数 ⇒ 全返回，不因 IN 列表少元素而丢行', () {
      for (int i = 0; i < 5; i++) {
        insertDocument(
          db.raw,
          'x$i',
          docNo: 'XS-$i',
          docType: 'sale',
          occurredAt: at(2026, 10, 10 + i),
        );
      }
      expect(documents.listDocuments(limit: 200), hasLength(5));
    });
  });

  test('countDocuments 与 listDocuments 的过滤条件逐字一致', () {
    final int at = 1730412800000;
    insertDocument(
      db.raw,
      'd-a',
      docNo: 'XS-001',
      docType: 'sale',
      totalAmount: 100,
      occurredAt: at,
    );
    insertDocument(
      db.raw,
      'd-b',
      docNo: 'CG-001',
      docType: 'purchase',
      totalAmount: 200,
      occurredAt: at,
    );

    // 默认（派生单据不进列表）
    expect(documents.countDocuments(), 2);
    expect(documents.listDocuments().length, 2);

    // 按类型筛
    expect(documents.countDocuments(types: <DocType>{DocType.sale}), 1);
    expect(documents.listDocuments(types: <DocType>{DocType.sale}).length, 1);

    // 按内容搜
    expect(documents.countDocuments(query: 'XS'), 1);
    expect(documents.listDocuments(query: 'XS').length, 1);

    // 搜不到时也是 0，不是「查不出来」
    expect(documents.countDocuments(query: '查无此单'), 0);
    expect(documents.listDocuments(query: '查无此单').length, 0);

    // includeDerived
    expect(documents.countDocuments(includeDerived: true), 2);
    expect(documents.listDocuments(includeDerived: true).length, 2);
  });
}

/// 把「逐行查」的两个入口改成抛错：列表路径一旦退化成 N+1 就立刻失败。
///
/// 这是审查盲点 ④ 的机械保证 —— 不靠「我记得批量查了」，靠**跑一次就知道**。
class _NoNPlusOneDao extends DocumentDao {
  _NoNPlusOneDao(super.db);

  @override
  int returnedAgainst(String refDocId) =>
      throw StateError('N+1：列表里逐行查退货冲减（应该用 JOIN 批量带出）');

  @override
  int settledAmountOf(String targetDocId) =>
      throw StateError('N+1：列表里逐行查核销（应该用 settlementCountsMany）');
}
