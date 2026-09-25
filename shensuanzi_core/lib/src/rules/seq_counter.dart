import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../db/schema.dart';

/// `seq_no` 分配器。
///
/// **每张流水表独立单调递增**（`Agents.md` 纪律 5）——
/// `stock_ledger` / `money_ledger` / `party_ledger` / `settlements` 各自从 1 开始，
/// 序号之间**不可比较**。跨表因果由 `document_id` 关联。
///
/// ⚠️ **必须在事务内调用**：分配与写入之间若被其它写入插入，就会撞号。
/// 该约束在运行期强制（[StateError]），不靠纪律。
class SeqCounter {
  SeqCounter(this.db);

  final Db db;

  int nextStock() => _next(Schema.stockLedger);

  int nextMoney() => _next(Schema.moneyLedger);

  int nextParty() => _next(Schema.partyLedger);

  int nextSettlement() => _next(Schema.settlements);

  int _next(String table) {
    if (!db.inTransaction) {
      throw StateError(
        'seq_no 必须在事务内分配（Agents.md 纪律 5）：表 $table。'
        '请把调用放进 RuleEngine / SyncServer 的事务里。',
      );
    }
    final Row row = db.raw
        .select('SELECT COALESCE(MAX(seq_no), 0) + 1 AS n FROM $table')
        .first;
    return row['n']! as int;
  }
}
