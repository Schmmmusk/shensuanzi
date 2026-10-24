// 未结金额（债权口径）—— 唯一来源（3a，2026-10-24，业务审查 §3.4 / P2 #1）。
//
// 这个文件钉住两件事：
// ① **各单据类型的行为**（销售/采购/送货算；退货/收付款/盘点/作废 = 0；负数不夹 0）；
// ② **SQL 片段与纯函数逐行相等**（20 组参数）—— 两者是两份代码，只有对拍能保证不漂。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  int owed(
    DocType type, {
    DocStatus status = DocStatus.confirmed,
    int total = 100,
    int paid = 50,
    int returned = 30,
  }) => outstandingCentsOf(
    docType: type,
    status: status,
    totalAmount: total,
    paidAmount: paid,
    returnedAmount: returned,
  );

  group('outstandingCentsOf（债权口径）', () {
    test('销售 / 采购 / 送货：总额 − 已核销 − 退货冲减', () {
      for (final DocType type in <DocType>[
        DocType.sale,
        DocType.purchase,
        DocType.delivery,
      ]) {
        expect(owed(type), 20, reason: '$type：100 − 50 − 30');
      }
    });

    test('退货 / 收付款 / 盘点 / 调拨 ⇒ 0（不产生债权债务）', () {
      for (final DocType type in <DocType>[
        DocType.saleReturn,
        DocType.purchaseReturn,
        DocType.receipt,
        DocType.payment,
        DocType.stocktake,
        DocType.transfer,
      ]) {
        expect(
          owed(type),
          0,
          reason: '$type：冲减方 / 流水本身，欠款由原单表达（用户 2026-10-24 明确）',
        );
      }
    });

    test('作废 ⇒ 0（作废单不算欠钱）', () {
      expect(owed(DocType.sale, status: DocStatus.cancelled), 0);
    });

    test('负数不夹 0（退 80 收 50 ⇒ −30 = 多收 30）', () {
      expect(owed(DocType.sale, paid: 50, returned: 80), -30);
    });
  });

  group('SQL 片段与纯函数对拍', () {
    test('20 组参数逐行相等', () {
      final Db db = newMemoryDb();
      addTearDown(db.close);
      db.raw.execute(
        'CREATE TEMP TABLE t ('
        'total_amount INTEGER, paid_amount INTEGER, rsum INTEGER)',
      );
      final List<List<int>> cases = <List<int>>[
        for (int i = 0; i < 20; i++) <int>[100 * (i + 1), 50 * i, 10 * i],
      ];
      for (final List<int> c in cases) {
        db.raw.execute(
          'INSERT INTO t (total_amount, paid_amount, rsum) VALUES (?,?,?)',
          c,
        );
      }
      final List<Map<String, Object?>> rows = db.raw.select(
        'SELECT total_amount AS ta, paid_amount AS pa, rsum AS r, '
        '${outstandingAmountSql(doc: 't', paid: 't.paid_amount', returned: 'COALESCE(t.rsum, 0)')} AS v '
        'FROM t',
      );
      expect(rows, hasLength(20));
      for (final Map<String, Object?> row in rows) {
        final int sqlValue = row['v']! as int;
        final int fnValue = outstandingCentsOf(
          docType: DocType.sale,
          status: DocStatus.confirmed,
          totalAmount: row['ta']! as int,
          paidAmount: row['pa']! as int,
          returnedAmount: row['r']! as int,
        );
        expect(
          sqlValue,
          fnValue,
          reason: 'SQL 与纯函数必须逐行相等（${row['ta']}/${row['pa']}/${row['r']}）',
        );
      }
    });
  });
}
