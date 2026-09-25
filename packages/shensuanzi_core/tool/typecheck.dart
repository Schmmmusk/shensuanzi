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
import '../test/immediate_payment_test.dart' as immediate_payment_test;
// ignore: unused_import
import '../test/query_test.dart' as query_test;
// ignore: unused_import
import '../test/return_test.dart' as return_test;
// ignore: unused_import
import '../test/rule_engine_test.dart' as rule_engine_test;
// ignore: unused_import
import '../test/schema_test.dart' as schema_test;
// ignore: unused_import
import '../test/util_test.dart' as util_test;

// ⚠️ `tool/` 下的自检脚本也必须纳入 —— 它们**不被 `test/` 引用**，
// 曾经因此漏掉一个真实编译错误（`createParty(name:)` 参数不存在），
// 而 `dart test` 只跑 `test/`，不会暴露它。
// ignore: unused_import
import 'selfcheck.dart' as selfcheck;
// ignore: unused_import
import 'selfcheck_delivery.dart' as selfcheck_delivery;
// ignore: unused_import
import 'selfcheck_payments.dart' as selfcheck_payments;
// ignore: unused_import
import 'selfcheck_query.dart' as selfcheck_query;
// ignore: unused_import
import 'selfcheck_returns.dart' as selfcheck_returns;
// ignore: unused_import
import 'selfcheck_rules.dart' as selfcheck_rules;

void main() {
  // 只引用函数值，确保编译器保留（不调用）。
  final List<void Function()> entries = <void Function()>[
    // test/
    database_test.main,
    delivery_test.main,
    immediate_payment_test.main,
    query_test.main,
    return_test.main,
    rule_engine_test.main,
    schema_test.main,
    util_test.main,
    // tool/
    selfcheck.main,
    selfcheck_delivery.main,
    selfcheck_payments.main,
    selfcheck_query.main,
    selfcheck_returns.main,
    selfcheck_rules.main,
  ];
  print(
    '编译通过：8 个测试文件 + 6 个自检脚本已通过类型检查（未执行）。'
    '（共 ${entries.length} 个入口）',
  );
}
