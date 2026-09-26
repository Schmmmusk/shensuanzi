// 编译守卫：`import` 全部入口但**不调用它们的 `main()`**。
//
// `dart run` 会编译被 import 的所有库，等于借用编译器做全包类型检查。
//
// ⚠️ **必须把 `tool/` 下的脚本也 import 进来**：`dart test` 只跑 `test/`，
// 自检脚本自身的编译错误不会被任何门禁发现（`docs/testing.md` §零）。
// 加入口时**同时改下面的 import 与 `entries` 列表**。
//
// 运行：`dart run tool/typecheck.dart`
// ignore_for_file: unused_import

import '../test/app_config_test.dart' as app_config_test;
import '../test/bootstrap_test.dart' as bootstrap_test;
import '../test/data_directory_service_test.dart' as data_directory_service_test;
import '../test/data_directory_test.dart' as data_directory_test;
import '../test/dialog_model_test.dart' as dialog_model_test;
import '../test/navigation_test.dart' as navigation_test;
import 'selfcheck_app.dart' as selfcheck_app;

void main() {
  // 只引用函数值，确保编译器保留（不调用）。
  final List<void Function()> entries = <void Function()>[
    // test/
    app_config_test.main,
    bootstrap_test.main,
    data_directory_service_test.main,
    data_directory_test.main,
    dialog_model_test.main,
    navigation_test.main,
    // tool/
    selfcheck_app.main,
  ];
  print(
    '编译通过：6 个测试文件 + 1 个自检脚本已通过类型检查（未执行）。'
    '（共 ${entries.length} 个入口）',
  );
}
