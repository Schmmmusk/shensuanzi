/// 神算子核心数据层。
///
/// 设计约束见仓库根目录的 `Agents.md`；实体与不变量见 `docs/data_model.md`；
/// 业务规则见 `docs/rules.md`；同步语义见 `docs/sync_protocol.md`。
///
/// ## 包边界（2026-09-25 裁定）
///
/// 本包是**纯 Dart 的数据层 + 同步协议层**，**不含 HTTP**：
///
/// - 模型 / DAO / 规则引擎 / 查询
/// - 同步**协议**：DTO（`SyncOperation` / `SyncPushRequest` / `SyncPullResult` …）
///   与白名单（`SyncWhitelist`）
/// - 同步**服务端实现**在 `shensuanzi_host`（该包依赖 `shelf`）
/// - 同步**客户端**（离线队列）也将落在本包，供 Android 端使用
///
/// `sqlite_local.dart` 是本包的公开辅助（纯 Dart 环境加载原生库），
/// 但**不在此 re-export** —— 需要时显式
/// `import 'package:shensuanzi_core/sqlite_local.dart';`。
///
/// ## 原生库
///
/// 使用方（Flutter 应用）**必须**自行提供 SQLite 原生库：
/// 在根 `pubspec.yaml` 依赖 `sqlite3_flutter_libs`。本包是纯 Dart 包，
/// 只包含 `sqlite3` 绑定，不含原生库。
library;

// 连接与 schema
export 'src/db/database.dart' show Db;
export 'src/db/schema.dart'
    show Schema, MissingMigrationException, SchemaTooNewException;
export 'src/db/storage_error.dart'
    show StorageFailureKind, classifyStorageFailure, storageFailureNote;

// 工具
export 'src/util/ids.dart' show newId;
export 'src/util/money.dart' show Money;

// 用户可见文本的规范（**项目级**：core / host / app 三层共用 —— §CV·十三 归类修正）
export 'src/user_text.dart' show forbiddenDevTermsInUserText;

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
export 'src/models/settlement.dart' show Settlement, SettlementView;
export 'src/models/stock_ledger.dart' show StockLedger;
export 'src/models/sync_queue_entry.dart' show SyncQueueEntry, SyncQueueStatus;

// DAO
export 'src/dao/account_dao.dart' show AccountDao;
export 'src/dao/document_dao.dart'
    show DocumentDao, DocumentStatusView, DocumentSummary;
export 'src/dao/ledger_dao.dart'
    show
        MoneyLedgerDao,
        PartyFlowEntry,
        PartyLedgerDao,
        StockCostSnapshot,
        StockLedgerDao;
export 'src/dao/party_dao.dart' show PartyDao;
export 'src/dao/product_dao.dart' show ProductDao;
export 'src/dao/query_dao.dart' show QueryDao;
export 'src/dao/settlement_dao.dart' show SettlementDao;
export 'src/dao/sync_dao.dart'
    show ClockOffsetDao, SyncCursorDao, SyncQueueDao, SyncQueueTriage;

// 规则
export 'src/rules/cost_policy.dart' show CostPolicy;
export 'src/rules/doc_no_generator.dart' show DocNoGenerator;
export 'src/rules/payment_entry.dart' show Allocation, PaymentEntry;
export 'src/rules/product_code_generator.dart' show ProductCodeGenerator;
export 'src/rules/rule_engine.dart' show RuleEngine, RuleOutcome, RuleStatus;
export 'src/rules/seq_counter.dart' show SeqCounter;

// 主数据建档（商品 / 账户 / 往来方最小建档）
export 'src/master_data/account_draft.dart' show AccountDraft, AccountField;
export 'src/master_data/account_service.dart'
    show AccountDraftInvalid, AccountService;
export 'src/master_data/party_service.dart'
    show PartyMutation, PartyMutationAction, PartyService;
export 'src/master_data/product_draft.dart' show ProductDraft, ProductField;
export 'src/master_data/product_service.dart'
    show ProductDraftInvalid, ProductService;
export 'src/master_data/master_data_sink.dart'
    show
        MasterDataSink,
        MasterDataSubmitResult,
        QueueMasterSink,
        ServiceMasterSink,
        masterDataCreatePayload,
        masterDataUpdatePayload;

// 单据建档（采购 / 店内销售；送货 / 退货的草稿将来同放 documents/）
export 'src/documents/purchase_draft.dart'
    show
        PurchaseDraft,
        PurchaseField,
        PurchaseLineDraft,
        PurchaseLineField,
        PurchasePaymentDraft,
        PurchasePaymentField;
export 'src/documents/delivery_draft.dart'
    show DeliveryDraft, DeliveryField, DeliveryLineDraft, DeliveryLineField;
export 'src/documents/delivery_service.dart'
    show DeliveryDraftInvalid, DeliverySaved, DeliveryService, DeliverySigned;
export 'src/documents/discount_spread.dart' show spreadDiscount;
export 'src/documents/overpay.dart' show Overpay;
export 'src/documents/quantity_conversion.dart'
    show
        ConversionFailed,
        ConversionFailureReason,
        ConversionSuccess,
        QuantityConversion,
        conversionFailureMessage,
        convertEntryPriceCents,
        entryPriceKeptHint,
        packageEntryHint,
        toBaseQuantity;
export 'src/documents/purchase_service.dart'
    show PurchaseDraftInvalid, PurchaseSaved, PurchaseService;
export 'src/documents/sale_draft.dart'
    show
        SaleDraft,
        SaleField,
        SaleLineDraft,
        SaleLineField,
        SalePaymentDraft,
        SalePaymentField;
export 'src/documents/sale_service.dart'
    show SaleDraftInvalid, SaleSaved, SaleService;
export 'src/documents/return_draft.dart'
    show
        ReturnDraft,
        ReturnField,
        ReturnLineDraft,
        ReturnLineField,
        ReturnRefundDraft,
        ReturnRefundField;
export 'src/documents/return_service.dart'
    show ReturnDraftInvalid, ReturnQuota, ReturnSaved, ReturnService;
export 'src/documents/settlement_service.dart'
    show SettlementInvalid, SettlementSaved, SettlementService;
export 'src/documents/stocktake_draft.dart'
    show StocktakeDraft, StocktakeLineDraft, StocktakeValidation;
export 'src/documents/stocktake_service.dart'
    show StocktakeDraftInvalid, StocktakeResult, StocktakeService;

// B3a：提交出口（`DocumentSink` 两实现 + 统一返回）与「草稿 → 实体」纯构造
export 'src/documents/draft_invalid.dart' show DraftInvalidException;
export 'src/documents/document_build.dart'
    show DocumentBuild, buildDeliveryDocument, buildPurchaseDocument, buildSaleDocument;
export 'src/documents/document_sink.dart'
    show
        DocumentSink,
        DocumentSubmitResult,
        QueueSink,
        ServiceSink,
        documentCreatePayload;

// 同步（协议层：DTO + 白名单。**服务端实现在 `shensuanzi_host`**）
export 'src/sync/sync_operation.dart'
    show
        SyncOperation,
        SyncOpType,
        SyncPushRequest,
        SyncPushResponse,
        SyncResponse,
        SyncStatus;
export 'src/sync/sync_pull.dart'
    show SyncCursor, SyncCursorKeys, SyncPullResult;
export 'src/sync/whitelist.dart' show SyncValueCheck, SyncWhitelist;
export 'src/sync/sync_failure.dart'
    show
        ConstraintKind,
        constraintKindOf,
        malformedSyncRequestReason,
        ruleInternalErrorReason,
        storageRejectCode,
        syncFailureReason;

// 用户可见文本的规范（`RejectCode`：`RuleOutcome` 与 `SyncResponse` 共用的机读码）
export 'src/reject_code.dart' show RejectCode;

// 同步（客户端：离线队列 + 拉取应用。**不含传输实现**）
export 'src/sync/pairing_payload.dart' show PairingPayload;
export 'src/sync/sync_client.dart'
    show StockView, SyncClient, SyncPullReport, SyncPushReport;
export 'src/sync/stock_delta.dart' show StockDelta;
export 'src/sync/transport.dart'
    show SyncHttpException, Transport, TransportRequest, TransportResponse;
