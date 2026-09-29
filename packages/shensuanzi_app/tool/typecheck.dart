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
import '../test/backup_test.dart' as backup_test;
import '../test/bootstrap_test.dart' as bootstrap_test;
import '../test/csv_test.dart' as csv_test;
import '../test/data_directory_service_test.dart' as data_directory_service_test;
import '../test/data_directory_test.dart' as data_directory_test;
import '../test/dialog_model_test.dart' as dialog_model_test;
import '../test/export_test.dart' as export_test;
import '../test/log_test.dart' as log_test;
import '../test/manual_test.dart' as manual_test;
import '../test/navigation_test.dart' as navigation_test;
import '../test/typography_test.dart' as typography_test;
import 'make_manual_html.dart' as make_manual_html;
import 'selfcheck_app.dart' as selfcheck_app;
import 'selfcheck_backup.dart' as selfcheck_backup;
import 'selfcheck_export.dart' as selfcheck_export;
import 'selfcheck_log.dart' as selfcheck_log;
import 'selfcheck_manual.dart' as selfcheck_manual;

void main() {
  // 只引用函数值，确保编译器保留（不调用）。
  final List<void Function()> entries = <void Function()>[
    // test/
    app_config_test.main,
    backup_test.main,
    bootstrap_test.main,
    csv_test.main,
    data_directory_service_test.main,
    data_directory_test.main,
    dialog_model_test.main,
    export_test.main,
    log_test.main,
    manual_test.main,
    navigation_test.main,
    typography_test.main,
    // tool/
    make_manual_html.main,
    selfcheck_app.main,
    selfcheck_backup.main,
    selfcheck_export.main,
    selfcheck_log.main,
    selfcheck_manual.main,
  ];
  print(
    '编译通过：12 个测试文件 + 5 个自检脚本 + 1 个生成脚本已通过类型检查（未执行）。'
    '（共 ${entries.length} 个入口）',
  );
}
