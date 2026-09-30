// 编译期守卫：`dart run tool/typecheck.dart`
//
// **为什么需要它**：本机 `dart analyze` 因无法创建子进程（analysis_server 启动失败，
// `ProcessException: 所有的管道范例都在使用中`）而时好时坏，无法作为可靠门禁。
// 本脚本 import 全部测试文件与自检脚本但**不调用它们的 main()** —— 只借用编译器做类型检查。
//
// `dart test` 不可用时，这是本机唯一能自动化的正确性门禁：
//   dart run tool/typecheck.dart   # 全包编译校验（含 tool/ 自身）
//   dart run tool/selfcheck*.dart  # 行为自检
// 在能正常创建子进程的环境（如你的 PowerShell）里，请直接跑 `dart test`。

// ignore: unused_import
import '../test/database_test.dart' as database_test;
// ignore: unused_import
import '../test/delivery_test.dart' as delivery_test;
// ignore: unused_import
import '../test/export_reads_test.dart' as export_reads_test;
// ignore: unused_import
import '../test/immediate_payment_test.dart' as immediate_payment_test;
// ignore: unused_import
import '../test/account_draft_test.dart' as account_draft_test;
// ignore: unused_import
import '../test/party_service_test.dart' as party_service_test;
// ignore: unused_import
import '../test/product_service_test.dart' as product_service_test;
// ignore: unused_import
import '../test/purchase_draft_test.dart' as purchase_draft_test;
// ignore: unused_import
import '../test/query_test.dart' as query_test;
// ignore: unused_import
import '../test/return_test.dart' as return_test;
// ignore: unused_import
import '../test/rule_engine_test.dart' as rule_engine_test;
// ignore: unused_import
import '../test/sale_draft_test.dart' as sale_draft_test;
// ignore: unused_import
import '../test/schema_test.dart' as schema_test;
// ignore: unused_import
import '../test/settlement_view_test.dart' as settlement_view_test;
// ignore: unused_import
import '../test/settlement_service_test.dart' as settlement_service_test;
// ignore: unused_import
import '../test/stocktake_service_test.dart' as stocktake_service_test;
// ignore: unused_import
import '../test/sync_client_test.dart' as sync_client_test;
// ignore: unused_import
import '../test/util_test.dart' as util_test;

// ⚠️ `tool/` 下的自检脚本也必须纳入 —— 它们**不被 `test/` 引用**，
// 曾经因此漏掉一个真实编译错误（`createParty(name:)` 参数不存在），
// 而 `dart test` 只跑 `test/`，不会暴露它。
// ignore: unused_import
import 'selfcheck.dart' as selfcheck;
// ignore: unused_import
import 'selfcheck_account.dart' as selfcheck_account;
// ignore: unused_import
import 'selfcheck_delivery.dart' as selfcheck_delivery;
// ignore: unused_import
import 'selfcheck_export_reads.dart' as selfcheck_export_reads;
// ignore: unused_import
import 'selfcheck_party.dart' as selfcheck_party;
// ignore: unused_import
import 'selfcheck_payments.dart' as selfcheck_payments;
// ignore: unused_import
import 'selfcheck_products.dart' as selfcheck_products;
// ignore: unused_import
import 'selfcheck_purchase.dart' as selfcheck_purchase;
// ignore: unused_import
import 'selfcheck_query.dart' as selfcheck_query;
// ignore: unused_import
import 'selfcheck_returns.dart' as selfcheck_returns;
// ignore: unused_import
import 'selfcheck_rules.dart' as selfcheck_rules;
// ignore: unused_import
import 'selfcheck_sale.dart' as selfcheck_sale;
// ignore: unused_import
import 'selfcheck_stocktake.dart' as selfcheck_stocktake;
// ignore: unused_import
import 'selfcheck_sync_client.dart' as selfcheck_sync_client;
// ignore: unused_import
import 'make_fixture.dart' as make_fixture;

void main() {
  // 只引用函数值，确保编译器保留（不调用）。
  // ⚠️ 用 `Function` 而不是 `void Function()`：`make_fixture.main` 带
  // `List<String> args`（生成化石脚本要 `--force` 开关），窄签名放不进去。
  final List<Function> entries = <Function>[
    // test/
    account_draft_test.main,
    database_test.main,
    delivery_test.main,
    export_reads_test.main,
    immediate_payment_test.main,
    party_service_test.main,
    product_service_test.main,
    purchase_draft_test.main,
    query_test.main,
    return_test.main,
    rule_engine_test.main,
    sale_draft_test.main,
    schema_test.main,
    settlement_view_test.main,
    settlement_service_test.main,
    stocktake_service_test.main,
    sync_client_test.main,
    util_test.main,
    // tool/
    selfcheck.main,
    selfcheck_account.main,
    selfcheck_delivery.main,
    selfcheck_export_reads.main,
    selfcheck_party.main,
    selfcheck_payments.main,
    selfcheck_products.main,
    selfcheck_purchase.main,
    selfcheck_query.main,
    selfcheck_returns.main,
    selfcheck_rules.main,
    selfcheck_sale.main,
    selfcheck_stocktake.main,
    selfcheck_sync_client.main,
    make_fixture.main,
  ];
  print(
    '编译通过：16 个测试文件 + 15 个 tool 入口已通过类型检查（未执行）。'
    '（共 ${entries.length} 个入口）',
  );
}
