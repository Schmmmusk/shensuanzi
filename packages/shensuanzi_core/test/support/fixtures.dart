// 测试夹具：固定 id + 单调时钟，保证失败可复现（无随机）。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:sqlite3/sqlite3.dart';

const String productId = 'p-00000000-0000-7000-8000-000000000001';
const String partyId = 'y-00000000-0000-7000-8000-000000000001';
const String accountId = 'a-00000000-0000-7000-8000-000000000001';
const String documentId = 'd-00000000-0000-7000-8000-000000000001';

int _clock = 1700000000000;

/// 单调递增的毫秒时间戳 —— 避免同毫秒导致的排序不确定性
int now() => _clock++;

void resetClock() => _clock = 1700000000000;

Db newMemoryDb({bool foreignKeys = true}) =>
    Db.openInMemory(foreignKeys: foreignKeys);

void insertProduct(
  Database db,
  String id, {
  String? code,
  String? name,
  int? costPrice,
}) {
  final int t = now();
  db.execute(
    'INSERT INTO products (id, code, name, cost_price, created_at, updated_at) '
    'VALUES (?,?,?,?,?,?)',
    <Object?>[id, code ?? id, name ?? '商品-$id', costPrice ?? 0, t, t],
  );
}

void insertParty(Database db, String id, {String? name}) {
  final int t = now();
  db.execute(
    'INSERT INTO parties (id, name, created_at, updated_at) VALUES (?,?,?,?)',
    <Object?>[id, name ?? '往来方-$id', t, t],
  );
}

/// 插一条明细行 —— 搜索「商品名」的用例要它（#26 搜索 ④）。
void insertDocumentLine(
  Database db,
  String id, {
  required String document,
  required String product,
  int quantity = 1,
  int unitPrice = 0,
  int? amount,
}) {
  db.execute(
    'INSERT INTO document_lines '
    '(id, document_id, product_id, quantity, unit_price, amount) '
    'VALUES (?,?,?,?,?,?)',
    <Object?>[
      id,
      document,
      product,
      quantity,
      unitPrice,
      amount ?? quantity * unitPrice,
    ],
  );
}

void insertAccount(Database db, String id) {
  final int t = now();
  db.execute(
    'INSERT INTO accounts (id, name, type, created_at, updated_at) VALUES (?,?,?,?,?)',
    <Object?>[id, '账户-$id', 'cash', t, t],
  );
}

void insertDocument(
  Database db,
  String id, {
  String docNo = 'CG20260925-001',
  String docType = 'purchase',
  String status = 'confirmed',
  int totalAmount = 0,
  String? refDocId,
  String? partyId,
  int? occurredAt,
  int? createdAt,
}) {
  final int t = now();
  // `occurred_at` / `created_at` 可显式给：排序口径的用例必须能分开摆
  // 「业务日期（主单 = 当天 00:00）」与「录入时刻」（#26① / §CV·六十二）。
  // 只给 `occurredAt` 时 `created_at` 跟它走 —— 退货 / 收付款单现实里就是
  // `occurred_at == created_at == 那一刻`（`return_service` / `settlement_service`）。
  final int occurred = occurredAt ?? t;
  final int created = createdAt ?? occurred;
  db.execute(
    'INSERT INTO documents '
    '(id, doc_no, doc_type, status, total_amount, ref_doc_id, party_id, '
    'occurred_at, created_at, updated_at) '
    'VALUES (?,?,?,?,?,?,?,?,?,?)',
    <Object?>[
      id,
      docNo,
      docType,
      status,
      totalAmount,
      refDocId,
      partyId,
      occurred,
      created,
      created,
    ],
  );
}

void insertStock(
  Database db,
  String id, {
  String product = productId,
  String document = documentId,
  int quantity = 1,
  int unitCost = 100,
  int totalCost = 100,
  int? seqNo,
}) {
  final int t = now();
  db.execute(
    'INSERT INTO stock_ledger '
    '(id, product_id, document_id, quantity, unit_cost, total_cost, seq_no, occurred_at, created_at) '
    'VALUES (?,?,?,?,?,?,?,?,?)',
    <Object?>[
      id,
      product,
      document,
      quantity,
      unitCost,
      totalCost,
      seqNo ?? nextSeq(db, 'stock_ledger'),
      t,
      t,
    ],
  );
}

void insertMoney(
  Database db,
  String id, {
  String account = accountId,
  String document = documentId,
  int amount = 100,
  int? seqNo,
}) {
  final int t = now();
  db.execute(
    'INSERT INTO money_ledger '
    '(id, account_id, document_id, amount, seq_no, occurred_at, created_at) '
    'VALUES (?,?,?,?,?,?,?)',
    <Object?>[
      id,
      account,
      document,
      amount,
      seqNo ?? nextSeq(db, 'money_ledger'),
      t,
      t,
    ],
  );
}

/// 插一条核销（`settlements`）—— 列表「已收 N 笔」的用例要它（#26 批 3）。
void insertSettlement(
  Database db,
  String id, {
  required String receiptDoc,
  required String targetDoc,
  int amount = 100,
  int? seqNo,
}) {
  final int t = now();
  db.execute(
    'INSERT INTO settlements '
    '(id, receipt_doc_id, target_doc_id, amount, seq_no, created_at) '
    'VALUES (?,?,?,?,?,?)',
    <Object?>[
      id,
      receiptDoc,
      targetDoc,
      amount,
      seqNo ?? nextSeq(db, 'settlements'),
      t,
    ],
  );
}

/// 与 `SeqCounter` 同口径：`MAX(seq_no) + 1`（每表独立）
int nextSeq(Database db, String table) =>
    db.select('SELECT COALESCE(MAX(seq_no), 0) + 1 AS n FROM $table').first['n']!
        as int;

/// 插一条 `party_ledger`（往来流水）—— 造「某往来方有余额」的场景。
///
/// §审查 OBS-05 后半的回归测试要用它：**余额是判断「能不能停用」的唯一依据**，
/// 而余额只从这张流水表算出来（没有余额列）。
void insertPartyLedger(
  Database db,
  String id, {
  String party = partyId,
  String document = documentId,
  int amount = 100,
  int? seqNo,
}) {
  final int t = now();
  db.execute(
    'INSERT INTO party_ledger '
    '(id, party_id, document_id, amount, seq_no, occurred_at, created_at) '
    'VALUES (?,?,?,?,?,?,?)',
    <Object?>[
      id,
      party,
      document,
      amount,
      seqNo ?? nextSeq(db, 'party_ledger'),
      t,
      t,
    ],
  );
}

/// 最小可用夹具集：商品 + 账户 + 单据
void seedMinimal(Db db) {
  insertProduct(db.raw, productId);
  insertAccount(db.raw, accountId);
  insertDocument(db.raw, documentId);
}
