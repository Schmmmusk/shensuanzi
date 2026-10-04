/// 建表语句与索引 —— `docs/data_model.md` 的可执行版本。
///
/// **本文件是 schema 的单一来源。** 改动这里必须同步 `docs/data_model.md`。
///
/// 约定（见 `docs/data_model.md` §一）：
/// - 主键 UUIDv7（`TEXT`）
/// - 时间 UTC 毫秒（`INTEGER`）
/// - 金额整数分（`INTEGER`）
/// - 布尔用 `INTEGER` 0/1
/// - 软删除 `is_active`、乐观锁 `sync_version` **仅主数据有**
///
/// ## 版本与迁移（`docs/reply_review.md` §AK·二 / reply.md Schema 篇）
///
/// - **[version] 是唯一权威**，`PRAGMA user_version` 是迁移的判定依据；
///   标记文件的 `schema_version` 只是「目录身份证」，**不参与迁移判定**
/// - **迁移链逐版本、不允许跳跃**：[migrationStep] 一段管一版，
///   执行器逐版跑（见 `database.dart` 的 `_migrate`）
/// - **字段只增不删、语义变更视作新字段**（至少保留一个发布周期）——
///   目的是让**旧客户端**还能读新库（个体工商户不会同时更新所有设备）
class Schema {
  Schema._();

  /// schema 版本。**递增时必须在 [migrationStep] 补一段**（漏写会被
  /// [MissingMigrationException] 拦在启动时）。
  ///
  /// v2（2026-09-29，§AJ·AI-5）：`products` 加 `package_note`（包装说明，
  /// 纯备注）。
  ///
  /// v3（2026-10-03，§BD）：**5 列一次到齐**（包装换算 + 让价 + 录入原文）——
  /// `products` 加 `package_unit` / `package_size`；`document_lines` 加
  /// `discount_amount` / `entry_quantity` / `entry_unit`。
  /// **五列的交互关系（7 条）见 `docs/reply_review.md` §BD·三**（那里是权威）。
  ///
  /// ⚠️ **本步（段 1a）只动 schema 与迁移**：`document_lines.quantity` 仍
  /// **永远是最小单位**、`amount` 仍是这一行**实际发生金额的真相**；
  /// 引擎 / 草稿 / UI 的口径改动分别在 2a / 2b / 3 段。
  static const int version = 3;

  // ---------------------------------------------------------------- 表名

  static const String products = 'products';
  static const String parties = 'parties';
  static const String accounts = 'accounts';
  static const String documents = 'documents';
  static const String documentLines = 'document_lines';
  static const String stockLedger = 'stock_ledger';
  static const String moneyLedger = 'money_ledger';
  static const String partyLedger = 'party_ledger';
  static const String settlements = 'settlements';
  static const String syncQueue = 'sync_queue';
  static const String clockOffset = 'clock_offset';
  static const String syncCursor = 'sync_cursor';

  /// **主机与客户端共用**的表（业务 + 主数据）
  static const List<String> serverTables = <String>[
    products,
    parties,
    accounts,
    documents,
    documentLines,
    stockLedger,
    moneyLedger,
    partyLedger,
    settlements,
  ];

  /// **仅客户端**的表（同步状态）。
  ///
  /// 主机**不应**创建这三张表 —— `SyncServer` 的运行不依赖它们。
  /// （R-14 裁定时提出的 P2-3：在 `schema.dart` 里显式区分，
  /// 让「主机不该碰同步状态」这件事有据可查，而不是靠记忆。
  /// 当前只是**常量分组**；用类型把 `SyncServer` 的 `Db` 排除掉属后续工作。）
  static const List<String> clientTables = <String>[
    syncQueue,
    clockOffset,
    syncCursor,
  ];

  /// 全部表（供自检与白名单校验使用）
  static const List<String> allTables = <String>[
    products,
    parties,
    accounts,
    documents,
    documentLines,
    stockLedger,
    moneyLedger,
    partyLedger,
    settlements,
    syncQueue,
    clockOffset,
    syncCursor,
  ];

  /// **主数据**：允许 UPDATE，受 `sync_version` 乐观锁保护。
  static const List<String> masterDataTables = <String>[
    products,
    parties,
    accounts,
  ];

  /// **业务数据**：只插入，不更新，不删除（见 `Agents.md` 纪律 2）。
  static const List<String> businessTables = <String>[
    documents,
    documentLines,
    stockLedger,
    moneyLedger,
    partyLedger,
    settlements,
  ];

  /// 流水表：`seq_no` **每表独立单调递增**，由主机在事务内分配。
  static const List<String> ledgerTables = <String>[
    stockLedger,
    moneyLedger,
    partyLedger,
  ];

  // ---------------------------------------------------------------- 执行顺序

  /// 建表与建索引语句。顺序即执行顺序（被引用的表必须先建）。
  static const List<String> createStatements = <String>[
    // ============================ 主数据 ============================
    '''
    CREATE TABLE $products (
      id            TEXT PRIMARY KEY,
      code          TEXT NOT NULL UNIQUE,
      name          TEXT NOT NULL,
      barcode       TEXT,
      unit          TEXT NOT NULL DEFAULT '件',
      cost_price    INTEGER NOT NULL DEFAULT 0,
      sell_price    INTEGER NOT NULL DEFAULT 0,
      safety_stock  INTEGER NOT NULL DEFAULT 0,
      category      TEXT,
      is_active     INTEGER NOT NULL DEFAULT 1,
      remark        TEXT,
      package_note  TEXT,
      -- v3（§BD）：包装换算。**两列同时有值**才启用；任一为空 ⇒ 行为与现在完全一致。
      package_unit  TEXT,
      package_size  INTEGER,
      created_at    INTEGER NOT NULL,
      updated_at    INTEGER NOT NULL,
      sync_version  INTEGER NOT NULL DEFAULT 0
    )
    ''',
    'CREATE INDEX idx_products_barcode ON $products(barcode)',
    // 同步拉取游标：主数据用 (updated_at, id) 复合（R-13 方案 A）。
    // 与 documents 的 (created_at, id) 同构 —— 时间戳不唯一，必须带 id 兜底。
    'CREATE INDEX idx_products_updated ON $products(updated_at, id)',

    '''
    CREATE TABLE $parties (
      id            TEXT PRIMARY KEY,
      name          TEXT NOT NULL,
      phone         TEXT,
      address       TEXT,
      roles         TEXT NOT NULL DEFAULT '[]',
      credit_limit  INTEGER NOT NULL DEFAULT 0,
      is_active     INTEGER NOT NULL DEFAULT 1,
      remark        TEXT,
      created_at    INTEGER NOT NULL,
      updated_at    INTEGER NOT NULL,
      sync_version  INTEGER NOT NULL DEFAULT 0
    )
    ''',
    'CREATE INDEX idx_parties_phone ON $parties(phone)',
    'CREATE INDEX idx_parties_updated ON $parties(updated_at, id)',

    '''
    CREATE TABLE $accounts (
      id              TEXT PRIMARY KEY,
      name            TEXT NOT NULL,
      type            TEXT NOT NULL,
      initial_balance INTEGER NOT NULL DEFAULT 0,
      is_active       INTEGER NOT NULL DEFAULT 1,
      created_at      INTEGER NOT NULL,
      updated_at      INTEGER NOT NULL,
      sync_version    INTEGER NOT NULL DEFAULT 0
    )
    ''',
    'CREATE INDEX idx_accounts_updated ON $accounts(updated_at, id)',

    // ============================ 单据 ============================
    '''
    CREATE TABLE $documents (
      id              TEXT PRIMARY KEY,
      doc_no          TEXT NOT NULL UNIQUE,
      doc_type        TEXT NOT NULL,
      status          TEXT NOT NULL,
      party_id        TEXT,
      account_id      TEXT,
      total_amount    INTEGER NOT NULL DEFAULT 0,
      paid_amount     INTEGER NOT NULL DEFAULT 0,
      ref_doc_id      TEXT,
      occurred_at     INTEGER NOT NULL,
      time_estimated  INTEGER NOT NULL DEFAULT 0,
      created_at      INTEGER NOT NULL,
      updated_at      INTEGER NOT NULL,
      remark          TEXT
    )
    ''',
    'CREATE INDEX idx_documents_type_status ON $documents(doc_type, status)',
    'CREATE INDEX idx_documents_party       ON $documents(party_id)',
    'CREATE INDEX idx_documents_occurred    ON $documents(occurred_at)',
    'CREATE INDEX idx_documents_ref         ON $documents(ref_doc_id)',
    // 同步拉取游标：`documents` 没有 seq_no，用 (created_at, id) 复合游标
    // （见 docs/sync_protocol.md §8.2 / R-4 处置）
    'CREATE INDEX idx_documents_created     ON $documents(created_at, id)',

    // v3（§BD）：`discount_amount` = 这一行的**让价**（分、正数、默认 0）；
    // `entry_quantity` / `entry_unit` = **录入原文**（用户当时输的数字与单位）——
    // **纯记录、不参与任何计算**，也**不因商品档案变化而重解释**（§BD·三 第 7 条）。
    // ⚠️ `quantity` 不变：**永远是最小单位数量**；`unit_price` 是派生展示值。
    '''
    CREATE TABLE $documentLines (
      id           TEXT PRIMARY KEY,
      document_id  TEXT NOT NULL,
      product_id   TEXT NOT NULL,
      quantity     INTEGER NOT NULL,
      unit_price   INTEGER NOT NULL,
      amount       INTEGER NOT NULL,
      -- v3（§BD）：让价（分、正数、默认 0）+ 录入原文（可空 = 用户没切单位）
      discount_amount INTEGER NOT NULL DEFAULT 0,
      entry_quantity  INTEGER,
      entry_unit      TEXT,
      remark       TEXT,
      FOREIGN KEY (document_id) REFERENCES $documents(id),
      FOREIGN KEY (product_id)  REFERENCES $products(id)
    )
    ''',
    'CREATE INDEX idx_lines_document ON $documentLines(document_id)',
    'CREATE INDEX idx_lines_product  ON $documentLines(product_id)',

    // ============================ 四张流水 ============================
    // ⚠️ 业务数据不可变：不提供 UPDATE。total_cost 是成本真相，unit_cost 只是派生展示值。
    '''
    CREATE TABLE $stockLedger (
      id              TEXT PRIMARY KEY,
      product_id      TEXT NOT NULL,
      document_id     TEXT NOT NULL,
      quantity        INTEGER NOT NULL,
      unit_cost       INTEGER NOT NULL DEFAULT 0,
      total_cost      INTEGER NOT NULL DEFAULT 0,
      seq_no          INTEGER NOT NULL,
      occurred_at     INTEGER NOT NULL,
      time_estimated  INTEGER NOT NULL DEFAULT 0,
      created_at      INTEGER NOT NULL,
      FOREIGN KEY (product_id)  REFERENCES $products(id),
      FOREIGN KEY (document_id) REFERENCES $documents(id)
    )
    ''',
    'CREATE INDEX idx_stock_product_seq ON $stockLedger(product_id, seq_no)',
    'CREATE INDEX idx_stock_document    ON $stockLedger(document_id)',
    'CREATE UNIQUE INDEX idx_stock_seq  ON $stockLedger(seq_no)',

    '''
    CREATE TABLE $moneyLedger (
      id              TEXT PRIMARY KEY,
      account_id      TEXT NOT NULL,
      document_id     TEXT NOT NULL,
      amount          INTEGER NOT NULL,
      seq_no          INTEGER NOT NULL,
      occurred_at     INTEGER NOT NULL,
      time_estimated  INTEGER NOT NULL DEFAULT 0,
      external_ref    TEXT,
      created_at      INTEGER NOT NULL,
      FOREIGN KEY (account_id)  REFERENCES $accounts(id),
      FOREIGN KEY (document_id) REFERENCES $documents(id)
    )
    ''',
    'CREATE INDEX idx_money_account_seq ON $moneyLedger(account_id, seq_no)',
    'CREATE INDEX idx_money_document    ON $moneyLedger(document_id)',
    'CREATE UNIQUE INDEX idx_money_seq  ON $moneyLedger(seq_no)',

    '''
    CREATE TABLE $partyLedger (
      id              TEXT PRIMARY KEY,
      party_id        TEXT NOT NULL,
      document_id     TEXT NOT NULL,
      amount          INTEGER NOT NULL,
      seq_no          INTEGER NOT NULL,
      occurred_at     INTEGER NOT NULL,
      time_estimated  INTEGER NOT NULL DEFAULT 0,
      created_at      INTEGER NOT NULL,
      FOREIGN KEY (party_id)    REFERENCES $parties(id),
      FOREIGN KEY (document_id) REFERENCES $documents(id)
    )
    ''',
    'CREATE INDEX idx_party_ledger_party_seq ON $partyLedger(party_id, seq_no)',
    'CREATE INDEX idx_party_ledger_document  ON $partyLedger(document_id)',
    'CREATE UNIQUE INDEX idx_party_ledger_seq ON $partyLedger(seq_no)',

    // 核销关系。target_doc_id = NULL 表示预收/预付。
    // 分配（allocations）随同步 payload 传入，由 RuleEngine 在 RULE-004/005 内消费
    // —— 见 docs/sync_protocol.md §8.1（R-1 裁定）。
    '''
    CREATE TABLE $settlements (
      id              TEXT PRIMARY KEY,
      receipt_doc_id  TEXT NOT NULL,
      target_doc_id   TEXT,
      amount          INTEGER NOT NULL,
      seq_no          INTEGER NOT NULL,
      time_estimated  INTEGER NOT NULL DEFAULT 0,
      created_at      INTEGER NOT NULL,
      FOREIGN KEY (receipt_doc_id) REFERENCES $documents(id),
      FOREIGN KEY (target_doc_id)  REFERENCES $documents(id)
    )
    ''',
    'CREATE INDEX idx_settle_receipt ON $settlements(receipt_doc_id)',
    'CREATE INDEX idx_settle_target  ON $settlements(target_doc_id)',
    'CREATE UNIQUE INDEX idx_settle_seq ON $settlements(seq_no)',

    // ============================ 同步（仅客户端使用） ============================
    '''
    CREATE TABLE $syncQueue (
      id             TEXT PRIMARY KEY,
      entity         TEXT NOT NULL,
      entity_id      TEXT NOT NULL,
      operation      TEXT NOT NULL,
      base_version   INTEGER,
      payload        TEXT NOT NULL,
      status         TEXT NOT NULL DEFAULT 'pending',
      retry_count    INTEGER NOT NULL DEFAULT 0,
      last_error     TEXT,
      created_at     INTEGER NOT NULL,
      next_retry_at  INTEGER NOT NULL DEFAULT 0
    )
    ''',
    'CREATE INDEX idx_sync_status ON $syncQueue(status, next_retry_at)',
    'CREATE INDEX idx_sync_entity ON $syncQueue(entity_id, operation)',

    // ============================ 时钟偏移（仅客户端使用） ============================
    '''
    CREATE TABLE $clockOffset (
      id          INTEGER PRIMARY KEY CHECK (id = 1),
      offset_ms   INTEGER NOT NULL DEFAULT 0,
      updated_at  INTEGER NOT NULL
    )
    ''',

    // ============================ 拉取游标（仅客户端使用） ============================
    // R-14 方案 A。**游标是「服务器已交付到哪里」的凭证，不是「本地有什么」的推导**：
    // 客户端只**原样保存**主机返回的 `next_cursors` 值，从不解析、从不从镜像水位推算。
    //
    // 为什么不从 `MAX(本地镜像)` 推算：写入路径有三条 —— pull、push 的回程、
    // 本地离线写。后两条会让本地镜像**越过**服务器已交付的水位，
    // 于是推算出的游标会跳过后一段服务器数据，且**静默丢数据**（不报错、不自愈）。
    '''
    CREATE TABLE $syncCursor (
      entity      TEXT PRIMARY KEY,
      cursor      TEXT NOT NULL,
      updated_at  INTEGER NOT NULL
    )
    ''',
  ];

  /// 从 [from] 升到 [from + 1] 的迁移步骤 —— **逐版本精确匹配**。
  ///
  /// ⚠️ **迁移链逐版本、不允许跳跃**：`migrationStep(2)` 假定库已在 v2 上。
  /// 执行器按 `for (v = current + 1; v <= version; v++)` 一版一版跑，**每版一个
  /// 事务**（失败只影响那一版，重试从断点继续）。
  ///
  /// **别写成累积判断**（`if (from < N)`）：那种写法在**只有一步**时看着对，
  /// 两步以上就错 —— from = 1、to = 3 时会跑 v1→v2 的步骤却**跳过 v2→v3**。
  /// 「哪一步做什么」要在这一眼可见（switch 就是版本清单）。
  ///
  /// 缺失的版本 → [MissingMigrationException]：改 `version` 却忘写迁移，
  /// **启动即拦**，不让用户的数据先踩坑。
  ///
  /// ## v1 → v2（2026-09-29，§AJ·AI-5）
  ///
  /// `products` 加 `package_note TEXT NULL`（包装说明，纯备注、不参与计算）。
  /// `ALTER TABLE ADD COLUMN` 对已有行自动取 NULL，不需要回填，不锁旧数据。
  ///
  /// ## v2 → v3（2026-10-03，§BD）
  ///
  /// **5 列一次到齐**，全部是 `ALTER TABLE ADD COLUMN`（纪律 14 / 15）：
  ///
  /// | 表 | 列 | 语义 |
  /// |---|---|---|
  /// | `products` | `package_unit TEXT NULL` | 包装单位名（如「箱」） |
  /// | `products` | `package_size INTEGER NULL` | 1 个包装 = 多少个**最小单位**（正整数） |
  /// | `document_lines` | `discount_amount INTEGER NOT NULL DEFAULT 0` | 这一行的**让价**（**分**、正数） |
  /// | `document_lines` | `entry_quantity INTEGER NULL` | **录入原文数量**（用户当时输的那个数字） |
  /// | `document_lines` | `entry_unit TEXT NULL` | **录入原文单位**（`unit` / `package_unit`，可为 null） |
  ///
  /// - `package_*` **两列同时有值**才启用换算；任一为空 ⇒ 行为与现在**完全一致**
  /// - `entry_*` **不参与任何计算**，也**不因商品档案变化而重解释**（历史不可变）
  /// - 一个**带默认**（`discount_amount` 默认 0）、四个**可空** ⇒ 旧行不需要回填，
  ///   也不锁旧数据（`ALTER TABLE ADD COLUMN` 的语义）
  ///
  /// ⚠️ **本步（段 1a）只加列，不改口径**：`quantity` 仍**永远是最小单位**，
  /// `amount` 仍是这一行**实际发生金额的真相**（§AY·一 已解除严格等式）。
  /// 引擎 / 草稿 / 白名单 / UI 分别在 2a / 2b / 2c / 3 段改。
  static List<String> migrationStep(int from) => switch (from) {
    1 => <String>['ALTER TABLE $products ADD COLUMN package_note TEXT NULL'],
    2 => <String>[
      'ALTER TABLE $products ADD COLUMN package_unit TEXT NULL',
      'ALTER TABLE $products ADD COLUMN package_size INTEGER NULL',
      'ALTER TABLE $documentLines ADD COLUMN discount_amount INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE $documentLines ADD COLUMN entry_quantity INTEGER NULL',
      'ALTER TABLE $documentLines ADD COLUMN entry_unit TEXT NULL',
    ],
    _ => throw MissingMigrationException(from),
  };
}

/// 迁移链缺一步（`Schema.migrationStep` 没有 `from` 那一段）。
///
/// 说明**改了 `Schema.version` 却忘了写迁移** —— 启动即拦。
class MissingMigrationException implements Exception {
  const MissingMigrationException(this.from);

  /// 缺的是「从 [from] 到 [from] + 1」这一步
  final int from;

  @override
  String toString() =>
      '缺少 v$from → v${from + 1} 的迁移步骤（检查 Schema.migrationStep）';
}

/// 库的版本**高于**本程序支持的版本（用户装回了旧版软件）。
///
/// 旧代码读新结构会静默错误或崩溃 —— **拒绝比崩溃好**：
/// 拒绝能明确告诉用户怎么办，崩溃只会让用户以为软件坏了。
class SchemaTooNewException implements Exception {
  const SchemaTooNewException({required this.dbVersion, required this.appVersion});

  /// 库文件的实际版本（`PRAGMA user_version`）
  final int dbVersion;

  /// 本程序支持的版本（`Schema.version`）
  final int appVersion;

  @override
  String toString() =>
      '数据库 schema 版本 $dbVersion 高于本程序支持的 $appVersion，请升级程序后再打开';
}
