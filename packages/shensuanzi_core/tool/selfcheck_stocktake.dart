/// 期初录入的降级门禁（对应 `test/stocktake_service_test.dart`）。
///
/// ⚠️ **改一边必须改另一边** —— `test/**` 是正式门禁，本脚本是
/// 「跑不了 `dart test` 时的降级门禁」（`docs/testing.md` §零）。
///
/// 运行：`dart run tool/selfcheck_stocktake.dart`
library;

import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

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

void main() {
  useLocalSqlite();

  final Db db = Db.openInMemory();
  final QueryDao queries = QueryDao(db);
  final StocktakeService service = StocktakeService(
    engine: RuleEngine(db),
    queries: queries,
  );
  const int t = 1700000000000;

  for (final String p in const <String>['p1', 'p2']) {
    db.raw.execute(
      'INSERT INTO products (id, code, name, cost_price, created_at, updated_at) '
      "VALUES ('$p', 'P-$p', '商品-$p', 0, $t, $t)",
    );
  }

  StocktakeDraft draftOf(Map<String, String> qtyByProduct) => StocktakeDraft(
    lines: <StocktakeLineDraft>[
      for (final MapEntry<String, String> e in qtyByProduct.entries)
        StocktakeLineDraft(
          productId: e.key,
          productName: '商品-${e.key}',
          quantity: e.value,
        ),
    ],
  );

  int count(String table) =>
      db.raw.select('SELECT COUNT(*) AS c FROM $table').first['c']! as int;

  // ============================================================ 草稿校验
  section('StocktakeDraft 校验');
  {
    check('全空 → topError「至少要填一行」', () {
      final StocktakeValidation v = const StocktakeDraft().validate();
      return !v.isValid && v.topError!.contains('至少要填一行');
    }());

    check('只有空行 → 拦下且空行不占错误位', () {
      final StocktakeValidation v = const StocktakeDraft(
        lines: <StocktakeLineDraft>[StocktakeLineDraft(), StocktakeLineDraft()],
      ).validate();
      return !v.isValid && v.topError!.contains('至少要填一行') && v.lineErrors.isEmpty;
    }());

    check('选商品没填数量 → 行级「请填数量」', () {
      final StocktakeValidation v = const StocktakeDraft(
        lines: <StocktakeLineDraft>[StocktakeLineDraft(productId: 'p1', productName: '可乐')],
      ).validate();
      return v.lineErrors[0]!.contains('请填数量');
    }());

    check('填数量没选商品 → 行级「请选一个商品」', () {
      final StocktakeValidation v = const StocktakeDraft(
        lines: <StocktakeLineDraft>[StocktakeLineDraft(quantity: '10')],
      ).validate();
      return v.lineErrors[0]!.contains('请选一个商品');
    }());

    check('数量 0 / 负数 / 非数字 / 小数 → 「正整数」', () {
      for (final String bad in const <String>['0', '-3', 'abc', '1.5']) {
        final StocktakeValidation v = StocktakeDraft(
          lines: <StocktakeLineDraft>[
            StocktakeLineDraft(productId: 'p1', quantity: bad),
          ],
        ).validate();
        if (!v.lineErrors[0]!.contains('正整数')) return false;
      }
      return true;
    }());

    check('同商品两行 → 第二行报「已经在上面」（AD-3）', () {
      final StocktakeValidation v = const StocktakeDraft(
        lines: <StocktakeLineDraft>[
          StocktakeLineDraft(productId: 'p1', productName: '可乐', quantity: '10'),
          StocktakeLineDraft(productId: 'p1', productName: '可乐', quantity: '20'),
        ],
      ).validate();
      return !v.lineErrors.containsKey(0) && v.lineErrors[1]!.contains('已经在上面');
    }());

    check('空行 + 一实行 → 通过；filledCount 只数实行的', () {
      final StocktakeDraft d = StocktakeDraft(lines: <StocktakeLineDraft>[
        StocktakeLineDraft(),
        const StocktakeLineDraft(productId: 'p1', productName: '可乐', quantity: '10'),
      ]);
      return d.validate().isValid && d.filledCount == 1;
    }());

    check('toActualQuantities：只含填了的行', () {
      final StocktakeDraft d = StocktakeDraft(lines: <StocktakeLineDraft>[
        StocktakeLineDraft(),
        const StocktakeLineDraft(productId: 'p1', quantity: '10'),
        const StocktakeLineDraft(productId: 'p2', quantity: '5'),
      ]);
      final Map<String, int> actual = d.toActualQuantities();
      return actual.length == 2 && actual['p1'] == 10 && actual['p2'] == 5;
    }());
  }

  // ============================================================ 服务提交
  section('StocktakeService.create');
  {
    check('首次录入两件 → changed=2 / 库存=实际数 / 单号 PD 前缀', () {
      final StocktakeResult r = service.create(
        draftOf(<String, String>{'p1': '10', 'p2': '5'}),
        now: t,
      );
      return r.docNo.startsWith('PD') &&
          r.changedCount == 2 &&
          r.unchangedCount == 0 &&
          queries.stockByProduct()['p1'] == 10 &&
          queries.stockByProduct()['p2'] == 5;
    }());

    check('期初成本按 0 记（AB-2）但商品「进过货」（§AD 遗漏 1 口径）', () {
      return (queries.costByProduct()['p1'] ?? -1) == 0 &&
          queries.inboundProductIds().contains('p1');
    }());

    check('原样再录一遍 → 全部无变化 / 库存不动 / 新单照记（建议 2）', () {
      final int docsBefore = count('documents');
      final StocktakeResult r = service.create(
        draftOf(<String, String>{'p1': '10', 'p2': '5'}),
        now: t + 1,
      );
      return r.changedCount == 0 &&
          r.unchangedCount == 2 &&
          queries.stockByProduct()['p1'] == 10 &&
          count('documents') == docsBefore + 1;
    }());

    check('混合：一件改数量一件没动 → changed=1 unchanged=1', () {
      final StocktakeResult r = service.create(
        draftOf(<String, String>{'p1': '10', 'p2': '8'}),
        now: t + 2,
      );
      return r.changedCount == 1 &&
          r.unchangedCount == 1 &&
          queries.stockByProduct()['p2'] == 8;
    }());

    check('盘点单形状：stocktake / total_amount=0 / 不碰钱账往来账', () {
      final Map<String, Object?> doc = db.raw
          .select('SELECT doc_type, total_amount FROM documents '
              "WHERE doc_type = 'stocktake' LIMIT 1")
          .first;
      return doc['doc_type'] == 'stocktake' &&
          doc['total_amount'] == 0 &&
          count('money_ledger') == 0 &&
          count('party_ledger') == 0;
    }());

    check('校验不通过 → StocktakeDraftInvalid', () {
      try {
        service.create(const StocktakeDraft(), now: t + 3);
        return false;
      } on StocktakeDraftInvalid {
        return true;
      }
    }());

    check('§AD 遗漏 2：hasAnyStockLedger false → true（入口文案判断）', () {
      // 本段前面已经录入过 → 此刻必然 true；再验一次查询本身有行为
      return queries.hasAnyStockLedger();
    }());
  }

  // ============================================================ 汇总
  stdout.writeln(
    '\n自检完成：$_pass 过，$_fail 挂'
    '${_failures.isEmpty ? '' : '  →  ${_failures.join('；')}'}',
  );
  if (_fail > 0) exit(1);
}
