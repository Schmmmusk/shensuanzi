// 开单页「无缝建档」（真实诉求批 ②，2026-10-25，§CV·一百零五）。
//
// 家人拿着进货单直接录，不知道要先建商品档案。所以允许在明细行**手打商品名**
// （`productId == ''` + `productName != ''`），保存时在**同一个事务内**：
//
// ```
// SaleService.create(draft)
//   └─ db.transaction(() {
//        ① 缺档行：先按名字精确匹配已有商品（TRIM 两侧）→ 命中就绑定
//        ② 没命中 ⇒ ProductService.create(...) 建出来（加入同一事务）
//        ③ 校验 → 构造 → RuleEngine.dispatch 落单
//      })
// ```
//
// 本文件钉住的是**四条不能错的性质**：
//
// | 性质 | 为什么致命 |
// |---|---|
// | 同名**不重复建档** | 否则商品列表两个「蒙牛纯牛奶」，库存被拆两半（④甲裁定的核心理由） |
// | 名字**两侧空格**也要匹配上 | 用户复制粘贴常带空格（reply §二-3） |
// | 校验失败**不留商品** | 否则一次打错数量就在主数据里留下垃圾商品 |
// | 校验语义**没被放宽** | 空名字 + 空商品仍要报「请选一个商品」 |
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  late Db db;
  late SaleService sales;
  late PurchaseService purchases;
  late DeliveryService deliveries;

  setUp(() {
    db = newMemoryDb();
    sales = SaleService(engine: RuleEngine(db), queries: QueryDao(db));
    purchases = PurchaseService(engine: RuleEngine(db), queries: QueryDao(db));
    deliveries = DeliveryService(engine: RuleEngine(db), queries: QueryDao(db));
    insertParty(db.raw, partyId, name: '客户甲');
    insertAccount(db.raw, accountId);
  });

  tearDown(() => db.close());

  /// 按名字数商品（**含停用**，`TRIM` 与匹配口径一致）
  List<Map<String, Object?>> productsNamed(String name) => db.raw.select(
    'SELECT * FROM products WHERE TRIM(name) = ?',
    <Object?>[name.trim()],
  );

  /// 一行「手打名字」的销售明细（`productId` 留空）
  SaleLineDraft typed(String name, {String qty = '3', String price = '5.00'}) =>
      SaleLineDraft(productName: name, quantity: qty, unitPrice: price);

  SaleDraft saleOf(List<SaleLineDraft> lines) => SaleDraft(
    partyId: partyId,
    partyName: '客户甲',
    date: '2026-10-25',
    lines: lines,
  );

  group('销售单：手打商品名', () {
    test('没有这个商品 ⇒ 保存时自动建档，且单照常落库', () {
      final SaleSaved saved = sales.create(
        saleOf(<SaleLineDraft>[typed('蒙牛纯牛奶')]),
      );

      final List<Map<String, Object?>> made = productsNamed('蒙牛纯牛奶');
      expect(made, hasLength(1), reason: '② 缺档行要在保存时建出来');
      expect(made.single['unit'], '件', reason: '② 默认单位「件」（ProductDraft 的默认值）');
      expect(
        made.single['sell_price'],
        500,
        reason: '② 销售单填的单价就是售价（5.00 元 = 500 分）',
      );
      expect(made.single['cost_price'], 0, reason: '② 销售单不知道进价 ⇒ 留空 = 0');

      final List<Map<String, Object?>> lines = db.raw.select(
        'SELECT product_id, quantity, amount FROM document_lines '
        'WHERE document_id = (SELECT id FROM documents WHERE doc_no = ?)',
        <Object?>[saved.docNo],
      );
      expect(lines, hasLength(1));
      expect(
        lines.single['product_id'],
        made.single['id'],
        reason: '② 明细必须指向新建的那个商品（否则库存挂到空 id 上）',
      );
      expect(lines.single['quantity'], 3);
    });

    test('同名商品已存在 ⇒ **绑定，不新建**（④甲：自动匹配是唯一的解）', () {
      insertProduct(db.raw, 'p-milk', name: '蒙牛纯牛奶');
      final int before = productsNamed('蒙牛纯牛奶').length;

      sales.create(saleOf(<SaleLineDraft>[typed('蒙牛纯牛奶')]));

      expect(
        productsNamed('蒙牛纯牛奶'),
        hasLength(before),
        reason: '② 一字不差就该绑定 —— 新建会让库存被拆成两半',
      );
      final List<Map<String, Object?>> lines = db.raw.select(
        'SELECT product_id FROM document_lines',
      );
      expect(lines.single['product_id'], 'p-milk');
    });

    test('名字两侧有空格 ⇒ 仍匹配已有商品（reply §二-3）', () {
      insertProduct(db.raw, 'p-milk', name: '蒙牛纯牛奶');

      sales.create(saleOf(<SaleLineDraft>[typed('  蒙牛纯牛奶 ')]));

      expect(
        productsNamed('蒙牛纯牛奶'),
        hasLength(1),
        reason: '② 查库前必须 trim，否则会多建一个「 蒙牛纯牛奶」',
      );
    });

    test('同一单两行同名缺档 ⇒ 只建一个，两行共用', () {
      sales.create(saleOf(<SaleLineDraft>[typed('新货'), typed('新货', qty: '2')]));

      expect(productsNamed('新货'), hasLength(1), reason: '② 第二行要查到第一行刚建的那个');
      final List<Map<String, Object?>> lines = db.raw.select(
        'SELECT product_id FROM document_lines',
      );
      expect(lines, hasLength(2));
      expect(
        lines.map((Map<String, Object?> r) => r['product_id']).toSet(),
        hasLength(1),
        reason: '② 两行必须指向同一个商品',
      );
    });

    test('校验失败 ⇒ 建出来的商品**一起回滚**（不留垃圾主数据）', () {
      expect(
        () => sales.create(saleOf(<SaleLineDraft>[typed('打错数量的货', qty: '0')])),
        throwsA(isA<SaleDraftInvalid>()),
        reason: '② 数量 0 仍然是校验错误',
      );
      expect(
        productsNamed('打错数量的货'),
        isEmpty,
        reason: '② 单没落成 ⇒ 商品也不能留（整段在一个事务里）',
      );
      expect(
        db.raw.select('SELECT COUNT(*) AS c FROM documents').single['c'],
        0,
        reason: '② 单据同样不能留',
      );
    });

    test('名字和商品都空 ⇒ 仍报「请选一个商品」（校验语义没被放宽）', () {
      SaleDraftInvalid? caught;
      try {
        sales.create(
          saleOf(<SaleLineDraft>[
            const SaleLineDraft(quantity: '3', unitPrice: '5.00'),
          ]),
        );
      } on SaleDraftInvalid catch (e) {
        caught = e;
      }
      expect(caught, isNotNull, reason: '② 缺档自动补全**不是**放宽校验');
      expect(caught!.lineErrors.first[SaleLineField.product], '请选一个商品');
      expect(
        db.raw.select('SELECT COUNT(*) AS c FROM products').single['c'],
        0,
        reason: '② 名字都没有，不可能建出商品',
      );
    });

    test('停用的同名商品 ⇒ 也绑定（名字一样就是同一个东西），不新建', () {
      insertProduct(db.raw, 'p-old', name: '停产汽水');
      db.raw.execute("UPDATE products SET is_active = 0 WHERE id = 'p-old'");

      sales.create(saleOf(<SaleLineDraft>[typed('停产汽水')]));

      expect(
        productsNamed('停产汽水'),
        hasLength(1),
        reason: '② 按名字认，不按启用状态认 —— 否则又出现两个同名',
      );
      expect(
        db.raw
            .select('SELECT product_id FROM document_lines')
            .single['product_id'],
        'p-old',
      );
    });
  });

  group('采购单 / 送货单同样支持', () {
    test('采购：单价进 `cost_price`，售价留空 = 0', () {
      purchases.create(
        PurchaseDraft(
          partyId: partyId,
          partyName: '供应商甲',
          date: '2026-10-25',
          lines: <PurchaseLineDraft>[
            const PurchaseLineDraft(
              productName: '面粉',
              quantity: '10',
              unitPrice: '12.50',
            ),
          ],
        ),
      );

      final Map<String, Object?> made = productsNamed('面粉').single;
      expect(made['cost_price'], 1250, reason: '② 采购单价 = 进价');
      expect(made['sell_price'], 0, reason: '② 采购不知道售价 ⇒ 留空');
      expect(made['unit'], '件');
    });

    test('送货：同样自动建档（送货单没有收付款）', () {
      deliveries.create(
        DeliveryDraft(
          partyId: partyId,
          partyName: '客户甲',
          date: '2026-10-25',
          lines: <DeliveryLineDraft>[
            const DeliveryLineDraft(
              productName: '整箱矿泉水',
              quantity: '2',
              unitPrice: '30.00',
            ),
          ],
        ),
      );

      final Map<String, Object?> made = productsNamed('整箱矿泉水').single;
      expect(made['sell_price'], 3000, reason: '② 送货单价也按售价记');
      expect(
        db.raw
            .select('SELECT product_id FROM document_lines')
            .single['product_id'],
        made['id'],
      );
    });
  });
}
