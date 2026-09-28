// 期初录入（§AD / RULE-009），对应 `docs/testing.md` 与 `tool/selfcheck_stocktake.dart`
// （**两套并行镜像：改一边必须改另一边**）。
//
// 覆盖：草稿校验（空行忽略 / 实际数量语义 / 同商品不重复 / 至少一行）/
// 服务提交（首次录入、重复录入无变化、混合变化、盘点单形状、
// 不碰钱账往来账）/ §AD 遗漏 1/2 的查询口径（待校准 / 入口文案判断）。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`；Windows 需要可用的 SQLite 原生库。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);
  setUp(resetClock);

  // ============================================================ 草稿校验（纯函数）
  group('StocktakeDraft 校验', () {
    test('全空 → topError「至少要填一行」', () {
      final StocktakeValidation v = const StocktakeDraft().validate();
      expect(v.isValid, isFalse);
      expect(v.topError, contains('至少要填一行'));
    });

    test('只有空行（空行忽略后一行都不剩）→ 同样拦下', () {
      final StocktakeValidation v = const StocktakeDraft(lines: <StocktakeLineDraft>[
        StocktakeLineDraft(),
        StocktakeLineDraft(),
      ]).validate();
      expect(v.isValid, isFalse);
      expect(v.topError, contains('至少要填一行'));
      expect(v.lineErrors, isEmpty, reason: '空行不占错误位');
    });

    test('选了商品没填数量 → 行级「请填数量」', () {
      const StocktakeDraft draft = StocktakeDraft(lines: <StocktakeLineDraft>[
        StocktakeLineDraft(productId: 'p1', productName: '可乐'),
      ]);
      final StocktakeValidation v = draft.validate();
      expect(v.topError, isNull);
      expect(v.lineErrors[0], contains('请填数量'));
    });

    test('填了数量没选商品 → 行级「请选一个商品」', () {
      const StocktakeDraft draft = StocktakeDraft(lines: <StocktakeLineDraft>[
        StocktakeLineDraft(quantity: '10'),
      ]);
      expect(draft.validate().lineErrors[0], contains('请选一个商品'));
    });

    test('数量 0 / 负数 / 非数字 → 「正整数」', () {
      for (final String bad in const <String>['0', '-3', 'abc', '1.5']) {
        final StocktakeValidation v = StocktakeDraft(
          lines: <StocktakeLineDraft>[
            StocktakeLineDraft(productId: 'p1', quantity: bad),
          ],
        ).validate();
        expect(v.lineErrors[0], contains('正整数'), reason: '原文 "$bad"');
      }
    });

    test('同商品两行 → 第二行报「已经在上面」（AD-3）', () {
      final StocktakeValidation v = const StocktakeDraft(
        lines: <StocktakeLineDraft>[
          StocktakeLineDraft(productId: 'p1', productName: '可乐', quantity: '10'),
          StocktakeLineDraft(productId: 'p1', productName: '可乐', quantity: '20'),
        ],
      ).validate();
      expect(v.lineErrors.containsKey(0), isFalse, reason: '第一行无辜');
      expect(v.lineErrors[1], contains('已经在上面'));
    });

    test('空行 + 一实行 → 通过；filledCount 只数实行的', () {
      final StocktakeDraft draft = StocktakeDraft(lines: <StocktakeLineDraft>[
        StocktakeLineDraft(),
        const StocktakeLineDraft(productId: 'p1', productName: '可乐', quantity: '10'),
      ]);
      expect(draft.validate().isValid, isTrue);
      expect(draft.filledCount, 1);
    });

    test('toActualQuantities：只含填了的行，空行跳过', () {
      final StocktakeDraft draft = StocktakeDraft(lines: <StocktakeLineDraft>[
        StocktakeLineDraft(),
        const StocktakeLineDraft(productId: 'p1', quantity: '10'),
        const StocktakeLineDraft(productId: 'p2', quantity: '5'),
      ]);
      expect(draft.toActualQuantities(), <String, int>{'p1': 10, 'p2': 5});
    });
  });

  // ============================================================ 服务提交
  group('StocktakeService.create', () {
    late Db db;
    late QueryDao queries;
    late StocktakeService service;
    final int t = 1700000000000;

    setUp(() {
      db = newMemoryDb();
      queries = QueryDao(db);
      service = StocktakeService(
        engine: RuleEngine(db),
        queries: queries,
      );
      // 两件商品：p1「可乐」p2「薯片」
      db.raw.execute(
        "INSERT INTO products (id, code, name, cost_price, created_at, updated_at) "
        "VALUES ('p1', 'P0001', '可乐', 0, $t, $t)",
      );
      db.raw.execute(
        "INSERT INTO products (id, code, name, cost_price, created_at, updated_at) "
        "VALUES ('p2', 'P0002', '薯片', 0, $t, $t)",
      );
    });

    tearDown(() => db.close());

    StocktakeDraft draftOf(Map<String, String> qtyByProduct) => StocktakeDraft(
      lines: <StocktakeLineDraft>[
        for (final MapEntry<String, String> e in qtyByProduct.entries)
          StocktakeLineDraft(
            productId: e.key,
            productName: e.key == 'p1' ? '可乐' : '薯片',
            quantity: e.value,
          ),
      ],
    );

    test('首次录入两件 → changedCount=2；库存 = 实际数量；单号 PD 前缀', () {
      final StocktakeResult r = service.create(
        draftOf(<String, String>{'p1': '10', 'p2': '5'}),
        now: t,
      );
      expect(r.docNo, startsWith('PD'));
      expect(r.changedCount, 2);
      expect(r.unchangedCount, 0);
      expect(queries.stockByProduct(), <String, int>{'p1': 10, 'p2': 5});
    });

    test('期初成本按 0 记（AB-2）：cost 余值为 0，但商品「进过货」', () {
      service.create(draftOf(<String, String>{'p1': '10'}), now: t);
      expect(queries.costByProduct()['p1'], 0, reason: '无历史 → surplusCost = 0');
      expect(queries.inboundProductIds(), contains('p1'),
          reason: '§AD 遗漏 1：成本列据此显示「待校准」而不是「未进货」');
    });

    test('原样再录一遍 → 全部「无变化」；库存不动；新单照记', () {
      service.create(draftOf(<String, String>{'p1': '10', 'p2': '5'}), now: t);
      final int docsBefore = _docCount(db);

      final StocktakeResult r = service.create(
        draftOf(<String, String>{'p1': '10', 'p2': '5'}),
        now: t + 1,
      );
      expect(r.changedCount, 0, reason: '建议 2：诚实反馈「都无变化」');
      expect(r.unchangedCount, 2);
      expect(queries.stockByProduct(), <String, int>{'p1': 10, 'p2': 5},
          reason: '实际数量语义：不是累加');
      expect(_docCount(db), docsBefore + 1, reason: '盘点单照常入账（可追溯）');
    });

    test('混合：一件改数量一件没动 → changed=1 unchanged=1', () {
      service.create(draftOf(<String, String>{'p1': '10', 'p2': '5'}), now: t);
      final StocktakeResult r = service.create(
        draftOf(<String, String>{'p1': '10', 'p2': '8'}),
        now: t + 1,
      );
      expect(r.changedCount, 1);
      expect(r.unchangedCount, 1);
      expect(queries.stockByProduct(), <String, int>{'p1': 10, 'p2': 8});
    });

    test('盘点单形状：doc_type=stocktake、total_amount=0、不碰钱账往来账', () {
      final StocktakeResult r = service.create(
        draftOf(<String, String>{'p1': '10'}),
        now: t,
      );

      final Map<String, Object?> doc = db.raw
          .select("SELECT doc_type, total_amount, status, remark FROM documents "
              "WHERE id = '${r.documentId}'")
          .first;
      expect(doc['doc_type'], 'stocktake');
      expect(doc['total_amount'], 0, reason: 'RULE-009 硬约束');
      expect(doc['status'], 'confirmed');

      expect(_count(db, 'money_ledger'), 0, reason: '期初录入没有真实交易');
      expect(_count(db, 'party_ledger'), 0);
    });

    test('校验不通过 → StocktakeDraftInvalid，库无新单', () {
      expect(
        () => service.create(const StocktakeDraft(), now: t),
        throwsA(isA<StocktakeDraftInvalid>()),
      );
      expect(_docCount(db), 0);
    });

    test('行数 > 0 但全是空行 → 同样拦下（空行不算「填了一行」）', () {
      expect(
        () => service.create(
          const StocktakeDraft(lines: <StocktakeLineDraft>[StocktakeLineDraft()]),
          now: t,
        ),
        throwsA(isA<StocktakeDraftInvalid>()),
      );
    });

    test('§AD 遗漏 2：hasAnyStockLedger false → true（入口文案判断）', () {
      expect(queries.hasAnyStockLedger(), isFalse, reason: '首次：录入现有货物');
      service.create(draftOf(<String, String>{'p1': '10'}), now: t);
      expect(queries.hasAnyStockLedger(), isTrue, reason: '再次：重新清点');
    });
  });
}

int _docCount(Db db) => _count(db, 'documents');

int _count(Db db, String table) =>
    db.raw.select('SELECT COUNT(*) AS c FROM $table').first['c']! as int;
