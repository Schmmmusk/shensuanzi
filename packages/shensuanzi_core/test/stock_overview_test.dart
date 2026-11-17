// `QueryDao.stockOverview()` —— **一次扫描喂两榜**（2026-11-14 用户裁定「甲-a」）。
//
// ## 为什么要单独钉
//
// 概览页同时要压货榜（`stockTop`）与缺货榜（`stockAggregates` 的 `hasInbound`）。
// 从前两条各把 `stock_ledger` 全表扫一遍（498.9 MB 实测 84 + 98 = 183 ms），
// 合并后 99.7 ms。合并的代价是**口径必须与两条老方法逐字一致** —— 差一点就是
// 「库存页说这个商品有货、缺货榜说没有」这种用户能看见的分裂。
//
// 所以本文件做两件事：
//   ① 用**独立构造**的数据钉住口径（尤其是 LEFT JOIN 引入的两个陷阱：
//      零流水商品不能进 `agg`、也不能被算成「待校准」）；
//   ② 与两条**老方法**逐个对比（它们的 SQL 是独立写的，不是同一条 ⇒ 交叉验证）。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late QueryDao query;

  /// 五个商品覆盖全部形态：
  /// | id | 流水 | 期望 |
  /// |---|---|---|
  /// | 甲 | +10 / 成本 1000 | 进榜（金额最大）|
  /// | 乙 | +5 / 成本 0 | 进「待校准」计数，不进行金额榜 |
  /// | 丙 | +3 / 成本 −300 | 进「负成本」计数（`stockTop` 的 `qty > 0` 才统计它）|
  /// | 己 | −3 / 成本 −300（只有出库）| `hasInbound = false`；`q < 0` ⇒ **不计数** |
  /// | 丁 | 无任何流水 | **不进 agg**、**不进任何计数**（洞 1 的陷阱）|
  /// | 戊 | +2 / 成本 200 | 进榜，第二 |
  // ⚠️ **不能写 `late final`**：它们在 `setUp` 里赋值，而 `setUp` 每条用例都跑一次
  // ⇒ `late final` 的第二次赋值抛 `LateInitializationError`，本文件第 2 条起全红
  // （2026-11-17 本机复跑发现。`flutter analyze` 抓不到，只有真跑才暴露）。
  late String never;
  late String uncalibrated;
  late String negative;
  late String onlyOut;
  late String noLedger;
  late String second;

  setUp(() {
    resetClock();
    db = newMemoryDb();
    query = QueryDao(db);

    never = 'p-never';
    uncalibrated = 'p-uncalibrated';
    negative = 'p-negative';
    onlyOut = 'p-only-out';
    noLedger = 'p-noledger';
    second = 'p-second';

    for (final String id in <String>[
      never,
      uncalibrated,
      negative,
      onlyOut,
      noLedger,
      second,
    ]) {
      insertProduct(db.raw, id, name: '名称-$id');
    }
    insertDocument(db.raw, 'd-overview');
    insertStock(
      db.raw,
      's1',
      product: never,
      document: 'd-overview',
      quantity: 10,
      unitCost: 100,
      totalCost: 1000,
    );
    insertStock(
      db.raw,
      's2',
      product: uncalibrated,
      document: 'd-overview',
      quantity: 5,
      unitCost: 0,
      totalCost: 0,
    );
    insertStock(
      db.raw,
      's3',
      product: negative,
      document: 'd-overview',
      quantity: 3,
      unitCost: -100,
      totalCost: -300,
    );
    insertStock(
      db.raw,
      's5',
      product: onlyOut,
      document: 'd-overview',
      quantity: -3,
      unitCost: 100,
      totalCost: -300,
    );
    insertStock(
      db.raw,
      's4',
      product: second,
      document: 'd-overview',
      quantity: 2,
      unitCost: 100,
      totalCost: 200,
    );
  });

  tearDown(() => db.close());

  group('stockOverview：一次扫描给两榜', () {
    test('agg 只收「有流水」的商品；零流水商品不进来', () {
      // 改坏点：去掉 `has_ledger` 过滤（把 LEFT JOIN 的零行也收进 agg）
      // ⇒ 库存页的 `_hasAnyLedger = agg.isNotEmpty` 会在「建了商品还没进货」时变真，
      // 首次开账的引导态就没了。
      final StockOverview so = query.stockOverview();
      expect(so.agg.keys.toSet(), <String>{
        never,
        uncalibrated,
        negative,
        onlyOut,
        second,
      });
      expect(so.agg.containsKey(noLedger), isFalse);
    });

    test('agg 的三列与单查方法一致（账面 / 成本 / 是否进过货）', () {
      final StockOverview so = query.stockOverview();
      expect(so.agg[never]!.quantity, 10);
      expect(so.agg[never]!.cost, 1000);
      expect(so.agg[never]!.hasInbound, isTrue);
      expect(
        so.agg[onlyOut]!.hasInbound,
        isFalse,
        reason: '只有负数量流水 = 从没进过货（洞 1 的判据是 hasInbound，不是「有流水」）',
      );
      expect(
        so.agg[negative]!.hasInbound,
        isTrue,
        reason: '正数量流水 ⇒ 进过货（哪怕成本是负的）',
      );
    });

    test('压货榜只取 q>0 且 cost>0，按金额降序', () {
      final StockOverview so = query.stockOverview();
      expect(
        so.top.rows.map((StockValueRow r) => r.productId).toList(),
        <String>[never, second],
      );
      expect(so.top.rows.first.valueCents, 1000);
      expect(so.top.rows.first.quantity, 10);
    });

    test('待校准 / 负成本各自计数，且**不含**零流水商品', () {
      // 改坏点：不加 `q > 0` / `has_ledger` 就开始计数 ⇒ 待校准从 1 变成 2（丁 也算进来），
      // 真机上那个数会从 3 变 297（提案 61 §三 洞 1 记的就是这个）。
      final StockOverview so = query.stockOverview();
      expect(so.top.uncalibratedCount, 1);
      expect(so.top.negativeCostCount, 1);
    });

    test('limit 只截行：limit=1 时计数仍准确；limit=0 时行与计数都空', () {
      final StockOverview one = query.stockOverview(limit: 1);
      expect(one.top.rows, hasLength(1));
      expect(one.top.uncalibratedCount, 1);
      expect(one.top.negativeCostCount, 1);
      expect(one.agg.length, 5, reason: 'agg 不受 limit 影响');

      final StockOverview zero = query.stockOverview(limit: 0);
      expect(zero.top.rows, isEmpty);
      expect(zero.top.uncalibratedCount, 0);
      expect(zero.top.negativeCostCount, 0);
      expect(zero.agg.length, 5);
    });

    test('与两条老方法交叉相等（它们的 SQL 是独立写的）', () {
      // 这条是**回归护栏**：将来谁改了其中一边的口径，这里立刻红。
      final StockOverview so = query.stockOverview();
      final StockTopSummary old = query.stockTop();
      expect(
        so.top.rows.map((StockValueRow r) => r.productId).toList(),
        old.rows.map((StockValueRow r) => r.productId).toList(),
      );
      expect(so.top.uncalibratedCount, old.uncalibratedCount);
      expect(so.top.negativeCostCount, old.negativeCostCount);

      final Map<String, StockAgg> agg = query.stockAggregates();
      expect(so.agg.keys.toSet(), agg.keys.toSet());
      for (final String id in agg.keys) {
        expect(so.agg[id]!.quantity, agg[id]!.quantity, reason: '账面 $id');
        expect(so.agg[id]!.cost, agg[id]!.cost, reason: '成本 $id');
        expect(so.agg[id]!.hasInbound, agg[id]!.hasInbound, reason: '入库 $id');
      }
    });

    test('金额并列 ⇒ 按名称升序（与 stockTop 的 ORDER BY 同口径）', () {
      // 两个同金额商品，名称 A / B ⇒ A 在前（码位序，与 SQL 的 `p.name ASC` 同）
      insertProduct(db.raw, 'p-b', name: 'B-同名金额');
      insertProduct(db.raw, 'p-a', name: 'A-同名金额');
      insertStock(
        db.raw,
        's9',
        product: 'p-b',
        document: 'd-overview',
        quantity: 1,
        unitCost: 500,
        totalCost: 500,
      );
      insertStock(
        db.raw,
        's10',
        product: 'p-a',
        document: 'd-overview',
        quantity: 1,
        unitCost: 500,
        totalCost: 500,
      );

      final List<String> ids = query
          .stockOverview()
          .top
          .rows
          .map((StockValueRow r) => r.productId)
          .toList();
      expect(ids.indexOf('p-a'), lessThan(ids.indexOf('p-b')));
      expect(
        ids,
        query.stockTop().rows.map((StockValueRow r) => r.productId).toList(),
        reason: '并列时的顺序必须与老方法一致，否则两张榜会「同一批商品顺序不同」',
      );
    });
  });
}
