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

void insertProduct(Database db, String id, {String? code, int? costPrice}) {
  final int t = now();
  db.execute(
    'INSERT INTO products (id, code, name, cost_price, created_at, updated_at) '
    'VALUES (?,?,?,?,?,?)',
    <Object?>[id, code ?? id, '商品-$id', costPrice ?? 0, t, t],
  );
}

void insertParty(Database db, String id) {
  final int t = now();
  db.execute(
    'INSERT INTO parties (id, name, created_at, updated_at) VALUES (?,?,?,?)',
    <Object?>[id, '往来方-$id', t, t],
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
}) {
  final int t = now();
  db.execute(
    'INSERT INTO documents '
    '(id, doc_no, doc_type, status, total_amount, occurred_at, created_at, updated_at) '
    'VALUES (?,?,?,?,?,?,?,?)',
    <Object?>[id, docNo, docType, status, totalAmount, t, t, t],
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

/// 与 `SeqCounter` 同口径：`MAX(seq_no) + 1`（每表独立）
int nextSeq(Database db, String table) =>
    db.select('SELECT COALESCE(MAX(seq_no), 0) + 1 AS n FROM $table').first['n']!
        as int;

/// 最小可用夹具集：商品 + 账户 + 单据
void seedMinimal(Db db) {
  insertProduct(db.raw, productId);
  insertAccount(db.raw, accountId);
  insertDocument(db.raw, documentId);
}
