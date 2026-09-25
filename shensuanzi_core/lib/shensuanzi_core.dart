/// 神算子核心数据层。
///
/// 设计约束见仓库根目录的 `Agents.md`；实体与不变量见 `docs/data_model.md`；
/// 业务规则见 `docs/rules.md`；同步语义见 `docs/sync_protocol.md`。
///
/// 使用方（Flutter 应用）**必须**自行提供 SQLite 原生库：
/// 在根 `pubspec.yaml` 依赖 `sqlite3_flutter_libs`。本包是纯 Dart 包，
/// 只包含 `sqlite3` 绑定，不含原生库。
library;

// 连接与 schema
export 'src/db/database.dart' show Db;
export 'src/db/schema.dart' show Schema;

// 工具
export 'src/util/ids.dart' show newId;
export 'src/util/money.dart' show Money;

// 模型
export 'src/models/account.dart' show Account, AccountType;
export 'src/models/base.dart'
    show ImmutableEntity, MutableEntity, RowReader, boolToInt;
export 'src/models/document.dart' show DocStatus, DocType, Document;
export 'src/models/document_line.dart' show DocumentLine, linesAmountMatchesTotal;
export 'src/models/money_ledger.dart' show MoneyLedger;
export 'src/models/party.dart' show Party, PartyRole;
export 'src/models/party_ledger.dart' show PartyLedger;
export 'src/models/product.dart' show Product;
export 'src/models/settlement.dart' show Settlement;
export 'src/models/stock_ledger.dart' show StockLedger;

// DAO
export 'src/dao/account_dao.dart' show AccountDao;
export 'src/dao/document_dao.dart' show DocumentDao;
export 'src/dao/ledger_dao.dart'
    show MoneyLedgerDao, PartyLedgerDao, StockCostSnapshot, StockLedgerDao;
export 'src/dao/party_dao.dart' show PartyDao;
export 'src/dao/product_dao.dart' show ProductDao;
export 'src/dao/query_dao.dart' show QueryDao;
export 'src/dao/settlement_dao.dart' show SettlementDao;

// 规则
export 'src/rules/cost_policy.dart' show CostPolicy;
export 'src/rules/doc_no_generator.dart' show DocNoGenerator;
export 'src/rules/payment_entry.dart' show Allocation, PaymentEntry;
export 'src/rules/rule_engine.dart' show RuleEngine, RuleOutcome, RuleStatus;
export 'src/rules/seq_counter.dart' show SeqCounter;

// 同步（主机侧，纯 Dart、不含 HTTP）
export 'src/sync/sync_operation.dart'
    show SyncOperation, SyncOpType, SyncResponse, SyncStatus;
export 'src/sync/sync_server.dart'
    show SyncCursor, SyncPullResult, SyncServer;
export 'src/sync/whitelist.dart' show SyncValueCheck, SyncWhitelist;
