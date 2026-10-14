// #42 甲 · 读路径坏数据兜底（L1/L2/L4，2026-10-14 裁定）。
//
// ⚠️ **本文件与 `tool/selfcheck.dart` 的「#42 读路径坏数据兜底」段是镜像**
// （本仓纪律：`test/**` 与 `tool/selfcheck*` 改一边必须改另一边，断言用的 API 名也要一致）。
//
// ## 起因（真实缺陷，不是假想）
//
// `parties.roles` 里一个库外值（S9 验收用 `tool/seed_test_data.py --inject` 注入
// `"  　\t  "`）⇒ 原来 `PartyRole.fromWire` 直接抛 ⇒ 抛穿页面 `build` ⇒
// `ErrorWidget`（release = 灰块）⇒ **整页不可用**。
//
// ## 本文件钉住的四件事
//
// 1. **不再抛穿**：坏行列被跳过 / 兜底，页面拿得到数据；
// 2. **兜底政策**：`AccountType` ⇒ `other`（保行，钱不能少报）· `DocStatus` ⇒ `confirmed`
//    （**不是 `draft`** —— 那是「未提交」，会让真单看起来像没保存）· `DocType` 未知 ⇒ **跳过**
//    （类型决定一切，猜错比看不见更坏）· 队列枚举未知 ⇒ **跳过**（**不伪装成 `failed`**）；
// 3. **不静默**：每一条都进 `ReadFailureLog`（带**列名 + 原值**）；
// 4. **计数语义**：按 `表 + 行 + 列`**去重**（N 不随重绘长大）；`clear()` = 「已告知」，
//    同一批坏行不再重复提醒，但**新的**坏行照常提醒。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

/// 用**裸 SQL** 写入库外值 —— 模型层写不出这种值，能写出来的只有
/// 外部注入 / 手工改库 / 恢复旧备份（与 `seed_test_data.py --inject` 同源）。
void insertBadParty(Db db, String id, String roles) {
  db.raw.execute(
    'INSERT INTO ${Schema.parties} (id, name, roles, credit_limit, is_active, '
    'created_at, updated_at, sync_version) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    <Object?>[id, '王老板', roles, 0, 1, 1, 1, 0],
  );
}

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  setUp(() => db = Db.openInMemory());
  tearDown(() => db.close());

  group('#42 甲 · 读路径坏数据兜底', () {
    test('wire 校验仍严格（畸形值要拒绝），读库才降级', () {
      expect(() => PartyRole.fromWire('  　\t  '), throwsArgumentError);
      expect(PartyRole.fromWireOrNull('  　\t  '), isNull);
      expect(PartyRole.fromWireOrNull('supplier'), PartyRole.supplier);
    });

    test('往来方：坏角色不再抛穿，认得出的保留、认不出的丢弃', () {
      insertBadParty(db, 'pa-bad', '["supplier","  　\t  "]');

      final List<Party> parties = PartyDao(db).findAll();

      expect(parties, hasLength(1), reason: '整行仍然查得到 —— 这一条原来会让整页变灰');
      expect(parties.first.roles, <PartyRole>[PartyRole.supplier]);
      expect(db.readFailures.count, 1);
      expect(db.readFailures.items.first.column, 'roles');
      expect(
        db.readFailures.items.first.value,
        '  　\t  ',
        reason: '记**原值**才能区分「用户数据坏了」与「我们自己枚举拼错了」（裁定 §二·④）',
      );
      expect(
        db.readFailures.items.first.logLine,
        isNot(contains('王老板')),
        reason: '日志纪律：绝不记经营数据',
      );
    });

    test('整列不是数组：也不抛，只是角色表为空', () {
      insertBadParty(db, 'pa-bad', 'not-json-at-all');

      expect(PartyDao(db).findAll(), hasLength(1));
      expect(PartyDao(db).findAll().first.roles, isEmpty);
      expect(db.readFailures.count, 1);
    });

    test('账户：类型认不出 ⇒ 兜底 other，**行保留**（钱不能少报）', () {
      db.raw.execute(
        'INSERT INTO ${Schema.accounts} (id, name, type, initial_balance, '
        'is_active, created_at, updated_at, sync_version) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>['ac-bad', '怪账户', 'weird_type', 12345, 1, 1, 1, 0],
      );

      final List<Account> accounts = AccountDao(db).findAll();

      expect(accounts, hasLength(1));
      expect(accounts.first.type, AccountType.other);
      expect(accounts.first.initialBalance, 12345, reason: '余额必须看得见');
      expect(db.readFailures.count, 1);
    });

    test('单据：状态认不出 ⇒ 兜底 confirmed（**不是 draft**）；类型认不出 ⇒ 跳过该行', () {
      void insertDoc(String id, String type, String status) => db.raw.execute(
        'INSERT INTO ${Schema.documents} (id, doc_no, doc_type, status, '
        'total_amount, paid_amount, occurred_at, time_estimated, created_at, '
        'updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[id, 'NO-$id', type, status, 5000, 0, 1, 0, 1, 1],
      );
      insertDoc('doc-ok', 'sale', 'weird_status');
      insertDoc('doc-worse', 'weird_type', 'confirmed');

      final List<DocumentSummary> docs = DocumentDao(db).listDocuments();

      expect(docs, hasLength(1), reason: '类型认不出的那条跳过（不猜类型）');
      expect(docs.first.document.id, 'doc-ok');
      expect(
        docs.first.document.status,
        DocStatus.confirmed,
        reason: '`draft` 在项目语义里是「未提交」—— 兜底成它会让真单看起来像没保存',
      );
      expect(db.readFailures.count, 2);
    });

    test('队列：枚举认不出 ⇒ 跳过该行（**不伪装成 failed**）', () {
      db.raw.execute(
        'INSERT INTO ${Schema.syncQueue} (id, entity, entity_id, operation, '
        'payload, status, retry_count, created_at, next_retry_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          'q-bad',
          Schema.documents,
          'd-1',
          'createDocument',
          '{}',
          'weird_status',
          0,
          1,
          0,
        ],
      );

      expect(SyncQueueDao(db).all(), isEmpty);
      expect(db.readFailures.count, 1);
      expect(
        db.readFailures.items.first.value,
        'weird_status',
        reason: '`failed` 的语义是「死信等人工处理」—— 拿来装兼容性问题会误导用户',
      );
    });

    test('计数：按「表 + 行 + 列」去重，不随重复读长大；clear() = 已告知', () {
      insertBadParty(db, 'pa-bad', '["  　\t  "]');

      PartyDao(db).findAll();
      final int first = db.readFailures.count;
      PartyDao(db).findAll(); // 再读一遍同一批坏行
      expect(db.readFailures.count, first, reason: '否则 N 会随页面重绘不断变大');

      db.readFailures.clear();
      expect(db.readFailures.count, 0);
      PartyDao(db).findAll();
      expect(db.readFailures.count, 0, reason: '「知道了」之后同一批坏行不再重复提醒');

      insertBadParty(db, 'pa-bad2', '["  　\t  "]'); // 另一条 id
      PartyDao(db).findAll();
      expect(db.readFailures.count, 1, reason: '**新**坏行仍然要提醒');
    });

    test('变化**主动通知**订阅者（UI 提示条就靠它刷新）', () {
      // ⚠️ 2026-10-14 被 `widget_test` 抓到的教训：提示条第一版只在**自己 build 时**
      // 读一次计数 ⇒ `record()` 不让任何人重建 ⇒ 界面上的提示条**永远不出现**。
      // 所以「变化通知」是 UI 能工作的**前提**，必须在 core 这侧钉住。
      int notified = 0;
      void listener() => notified++;
      db.readFailures.addListener(listener);
      addTearDown(() => db.readFailures.removeListener(listener));

      insertBadParty(db, 'pa-1', '["  　\t  "]');
      PartyDao(db).findAll();
      expect(notified, 1, reason: '新增坏行 ⇒ 通知一次');

      PartyDao(db).findAll(); // 同一批坏行（去重后计数不变）
      expect(notified, 1, reason: '计数没变就不该惊动 UI');

      db.readFailures.clear();
      expect(notified, 2, reason: 'clear ⇒ 再通知一次（提示条才会消失）');
    });

    test('用户可见文案：带 N、给动作、无开发术语', () {
      expect(readFailureNotice(3), '有 3 条记录暂时显示不全。');
      expect(readFailureNotice(3), isNot(contains('异常')));
      expect(readFailureNotice(3), isNot(contains('SQL')));
      expect(readFailureAdvice, contains('备份与恢复'));
      expect(readFailureCause, contains('旧备份'));
    });
  });
}
