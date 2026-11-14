// 缺货榜的计算（提案 61 §七 的 19 条用例）。
//
// 为什么在**纯 Dart 层**测、而不是只用 widget 测试：
// 这些是业务口径（超卖与安全库存解耦、缺口补到安全库存、参考进价、未同步），
// 每条都能被一行代码改坏，而 widget 测试里它们会被排版噪声盖住。
// 卡片本身（文案红线 / 引导卡）在 `low_stock_card_test.dart`；
// 「公式只有一份」的机械保证在 `in_store_single_source_test.dart`。
//
// ⚠️ 反向灵敏度：每条断言都对应一个能被刻意改坏的点（见每组的注释），
// 已实测 —— 改坏后对应断言变红（`docs/reply_review.md` §八十五 有记录）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/shortage.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

Product product(
  String id, {
  String? name,
  int safety = 0,
  int cost = 0,
  String unit = '件',
}) => Product(
  id: id,
  code: 'C-$id',
  name: name ?? '商品$id',
  unit: unit,
  costPrice: cost,
  safetyStock: safety,
  createdAt: 0,
  updatedAt: 0,
);

StockAgg stock(int quantity, {int cost = 0, bool inbound = true}) =>
    StockAgg(quantity: quantity, cost: cost, hasInbound: inbound);

ShortageSummary run(
  List<Product> products,
  Map<String, StockAgg> agg, {
  Map<String, int> inTransit = const <String, int>{},
  Map<String, int> unsynced = const <String, int>{},
  int limit = 10,
}) => computeShortage(
  products: products,
  agg: agg,
  inTransit: inTransit,
  unsynced: unsynced,
  limit: limit,
);

List<String> idsOf(List<ShortageRow> rows) =>
    rows.map((ShortageRow r) => r.id).toList();

void main() {
  group('边界：缺货判据是 ≤（在店可售 ≤ 安全库存）', () {
    test('#1 安全库存 5 / 在店可售 5 ⇒ 进榜，缺口 0', () {
      // 改坏点：把 `<=` 写成 `<` ⇒ 本组红
      final ShortageSummary s = run(
        <Product>[product('a', safety: 5)],
        <String, StockAgg>{'a': stock(5)},
      );
      expect(idsOf(s.restock), <String>['a']);
      expect(s.restock.single.gapQty, 0, reason: '刚好到安全库存 ⇒ 缺口 0（只提示不排序）');
    });

    test('#2 安全库存 5 / 在店可售 6 ⇒ 不进榜', () {
      final ShortageSummary s = run(
        <Product>[product('a', safety: 5)],
        <String, StockAgg>{'a': stock(6)},
      );
      expect(s.hasAny, isFalse);
    });

    test('#3 安全库存 0 / 在店可售 3 ⇒ 哪一段都不进', () {
      // 改坏点：把 `safety_stock = 0` 当成「永远缺货」⇒ 全店商品都进榜
      final ShortageSummary s = run(
        <Product>[product('a')],
        <String, StockAgg>{'a': stock(3)},
      );
      expect(s.hasAny, isFalse);
      expect(s.restock, isEmpty);
      expect(s.oversold, isEmpty);
    });

    test('#19 安全库存 0 / 在店可售 3 ⇒ 不进任何段（与 #3 同义的第二处断言）', () {
      final ShortageSummary s = run(
        <Product>[product('a')],
        <String, StockAgg>{'a': stock(3)},
      );
      expect(s.totalCount, 0);
    });
  });

  group('超卖与安全库存解耦（决策 2 的修正点）', () {
    test('#4 在店可售 −3 ⇒ 进超卖段，不进该补货段', () {
      final ShortageSummary s = run(
        <Product>[product('a', safety: 5)],
        <String, StockAgg>{'a': stock(-3)},
      );
      expect(idsOf(s.oversold), <String>['a']);
      expect(s.restock, isEmpty);
    });

    test('#18 安全库存 0 / 在店可售 −3 ⇒ **必须**进超卖段', () {
      // 改坏点：候选集重新加回 `safety_stock > 0` ⇒ 这条红（旧方案就漏这里）
      final ShortageSummary s = run(
        <Product>[product('a')],
        <String, StockAgg>{'a': stock(-3)},
      );
      expect(idsOf(s.oversold), <String>['a']);
      expect(s.oversold.single.gapQty, 3, reason: '没设安全库存 ⇒ 补回 0 即可');
    });

    test('#10 在途 100 / 账面 0 / 安全库存 50 ⇒ 在店可售 −100 ⇒ 超卖段', () {
      // 改坏点：用账面代替在店可售 ⇒ 这条红（库存页说超卖、榜里没有）
      final ShortageSummary s = run(
        <Product>[product('a', safety: 50, cost: 100)],
        <String, StockAgg>{'a': stock(0)},
        inTransit: <String, int>{'a': 100},
      );
      expect(idsOf(s.oversold), <String>['a']);
      expect(s.oversold.single.inStore, -100);
    });
  });

  group('排序（决策 1 乙：缺口金额降序 + 稳定次级键）', () {
    test('#5 金额大的在前', () {
      final ShortageSummary s = run(
        <Product>[
          product('small', safety: 10, cost: 100), // 缺口 5 × ¥1.00
          product('big', safety: 100, cost: 1000), // 缺口 50 × ¥10.00
        ],
        <String, StockAgg>{'small': stock(5), 'big': stock(50)},
      );
      expect(idsOf(s.restock), <String>['big', 'small']);
    });

    test('#5b 金额相同 ⇒ 按缺口、再按名称/ID，两次顺序一致', () {
      // 改坏点：去掉次级键（只比金额）⇒ 顺序依赖 sort 稳定性，`两次一致` 会脆
      final List<Product> products = <Product>[
        product('c', name: '丙丙', safety: 100, cost: 500), // 缺口 20 ⇒ ¥100.00
        product('a', name: '甲甲', safety: 100, cost: 500), // 缺口 20 ⇒ ¥100.00
        product('b', name: '乙乙', safety: 100, cost: 1000), // 缺口 10 ⇒ ¥100.00
      ];
      final Map<String, StockAgg> agg = <String, StockAgg>{
        'c': stock(80),
        'a': stock(80),
        'b': stock(90),
      };
      final List<String> first = idsOf(run(products, agg).restock);
      final List<String> second = idsOf(run(products, agg).restock);
      expect(second, first, reason: '同一份数据两次渲染顺序必须一致');
      // 缺口大的两个排在缺口小的前面
      expect(first.take(2).toSet(), <String>{'a', 'c'});
      // 金额与缺口都相同时按名称（**码位序**：丙 U+4E19 < 甲 U+7532，不是拼音序）
      expect(
        first.indexOf('c') < first.indexOf('a'),
        isTrue,
        reason: first.join(','),
      );
    });

    test('#5b ASCII 名称的次级键：AAA 在 BBB 前', () {
      final ShortageSummary s = run(
        <Product>[
          product('y', name: 'BBB', safety: 10, cost: 100),
          product('x', name: 'AAA', safety: 10, cost: 100),
        ],
        <String, StockAgg>{'x': stock(0), 'y': stock(0)},
      );
      expect(idsOf(s.restock), <String>['x', 'y']);
    });
  });

  group('「从没进过货」与「待校准」不是一回事（洞 1）', () {
    test('#6 无流水但设了安全库存 ⇒ 进榜，单独计数', () {
      // 改坏点：复用 stockTop 的 INNER JOIN ⇒ 这类商品整类消失（旧方案）
      final ShortageSummary s = run(<Product>[
        product('a', safety: 50, cost: 1000),
      ], <String, StockAgg>{});
      expect(idsOf(s.restock), <String>['a']);
      expect(s.restock.single.gapQty, 50);
      expect(s.neverInboundCount, 1);
      expect(s.priceUnsetCount, 0, reason: '填了参考进价 ⇒ 不算「单价未填」');
    });

    test('#7 有入库但成本为 0 ⇒ 与「没进过货」分开计数', () {
      final ShortageSummary s = run(
        <Product>[
          product('a', safety: 10, cost: 100),
          product('b', safety: 10, cost: 100),
        ],
        <String, StockAgg>{
          'a': stock(0, cost: 0, inbound: true), // 进过货、成本待校准
          'b': stock(-2, cost: -20, inbound: false), // 只有过出库
        },
      );
      expect(idsOf(s.restock), <String>['a']);
      expect(idsOf(s.oversold), <String>['b']);
      expect(s.neverInboundCount, 1);
    });

    test('#13 只有一笔负数量流水 ⇒ 算「没进过货」（判据是 hasInbound）', () {
      // 改坏点：判据改回 `hasLedger`（有任意流水）⇒ 这条红
      final ShortageSummary s = run(
        <Product>[product('a', safety: 10, cost: 100)],
        <String, StockAgg>{'a': stock(-5, cost: -50, inbound: false)},
      );
      expect(s.neverInboundCount, 1);
      expect(s.oversold.single.everInbound, isFalse);
    });
  });

  group('口径：未同步与在店可售', () {
    test('#8 手机上未同步 −4 让「不缺」变「缺」；桌面同数据不进榜', () {
      // 改坏点：`effectiveInStoreOf` 去掉 `+ unsynced` ⇒ 这条红
      final ShortageSummary mobile = run(
        <Product>[product('a', safety: 8, cost: 100)],
        <String, StockAgg>{'a': stock(10)},
        unsynced: <String, int>{'a': -4},
      );
      expect(idsOf(mobile.restock), <String>['a']);
      expect(mobile.restock.single.inStore, 6);

      final ShortageSummary desktop = run(
        <Product>[product('a', safety: 8, cost: 100)],
        <String, StockAgg>{'a': stock(10)},
      );
      expect(desktop.hasAny, isFalse, reason: '桌面 unsynced ≡ 0 ⇒ 在店可售 10');
    });
  });

  group('金额：参考进价与「不能假装」的两态', () {
    test('#9 cost_price = 0 ⇒ 只报件数、不参与金额排序', () {
      final ShortageSummary s = run(
        <Product>[
          product('noPrice', safety: 100),
          product('priced', safety: 100, cost: 100),
        ],
        <String, StockAgg>{'noPrice': stock(0), 'priced': stock(0)},
      );
      expect(s.priceUnsetCount, 1);
      final ShortageRow noPrice = s.restock.firstWhere(
        (ShortageRow r) => r.id == 'noPrice',
      );
      expect(noPrice.priceUnset, isTrue);
      expect(noPrice.gapCents, 0, reason: '不许算成 ¥0 的补货金额');
      expect(s.restock.first.id, 'priced', reason: '有金额的排前面');
    });

    test('#14 安全库存 5 / 在店可售 −3 ⇒ 缺口 8（不是 3），金额按 8 算', () {
      // 改坏点：`gapQty = max(0, −inStore)`（只补回 0）⇒ 这条红
      final ShortageSummary s = run(
        <Product>[product('a', safety: 5, cost: 1000)],
        <String, StockAgg>{'a': stock(-3)},
      );
      final ShortageRow row = s.oversold.single;
      expect(row.gapQty, 8, reason: '补 3 件只到 0，到不了安全库存 5');
      expect(row.gapCents, 8000, reason: '8 × ¥10.00');
      expect(row.inStore, -3, reason: '超卖段显示的仍是在店可售 −3，与 8 不混用');
    });
  });

  group('引导卡（决策 4 乙）与可见性', () {
    test('#11 全店都没设安全库存 ⇒ showGuide', () {
      final ShortageSummary s = run(
        <Product>[product('a'), product('b')],
        <String, StockAgg>{'a': stock(3), 'b': stock(0)},
      );
      expect(s.showGuide, isTrue);
    });

    test('#15 300 个商品只有 1 个设了且够货 ⇒ 不出引导卡（出「暂时都不缺」）', () {
      // 改坏点：从「筛选后的子集」推断全店没设 ⇒ 这条红
      final List<Product> products = <Product>[
        for (int i = 0; i < 300; i++) product('p$i', safety: i == 0 ? 5 : 0),
      ];
      final Map<String, StockAgg> agg = <String, StockAgg>{
        for (int i = 0; i < 300; i++) 'p$i': stock(i == 0 ? 100 : 0),
      };
      final ShortageSummary s = run(products, agg);
      expect(s.showGuide, isFalse);
      expect(s.hasAny, isFalse, reason: '设了但都还够 —— 这是好消息');
      expect(s.isVisible, isTrue, reason: '卡片仍然显示（出「没有要补的货」）');
    });
  });

  group('商品数量：不能被 200 条默认上限截断', () {
    test('#12 250 个商品里第 210 个缺货 ⇒ 必须进榜', () {
      // 改坏点：概览页改用 `findAll()`（默认 limit: 200）⇒ 这条红
      final List<Product> products = <Product>[
        for (int i = 0; i < 250; i++)
          product('p$i', safety: i == 209 ? 10 : 0, cost: 100),
      ];
      final Map<String, StockAgg> agg = <String, StockAgg>{
        for (int i = 0; i < 250; i++) 'p$i': stock(5),
      };
      final ShortageSummary s = run(products, agg);
      expect(idsOf(s.restock), <String>['p209']);
      expect(s.activeCount, 250);
    });
  });

  group('limit 只截行、不动计数', () {
    test('每段 10 行上限；limitTo(3) 只减少行数', () {
      final List<Product> products = <Product>[
        for (int i = 0; i < 15; i++) product('p$i', safety: 10, cost: 100),
      ];
      final Map<String, StockAgg> agg = <String, StockAgg>{
        for (int i = 0; i < 15; i++) 'p$i': stock(0),
      };
      final ShortageSummary s = run(products, agg, limit: 10);
      expect(s.restock.length, 10);
      expect(s.restockCount, 15);

      final ShortageSummary three = s.limitTo(3);
      expect(three.restock.length, 3);
      expect(three.restockCount, 15, reason: '「查看全部 15 个」要用真数');
      expect(three.activeCount, 15);
    });
  });
}
