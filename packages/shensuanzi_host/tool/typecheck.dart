// 编译期守卫：`dart run tool/typecheck.dart`
//
// **为什么需要它**：本机 `dart analyze` 因无法创建子进程（analysis_server 启动失败，
// `ProcessException: 所有的管道范例都在使用中`）而时好时坏，无法作为可靠门禁。
// 本脚本 import 全部入口但**不调用它们的 `main()`** —— 只借用编译器做类型检查。
//
// ⚠️ **必须同时 import `test/` 与 `tool/`**：`dart test` 只跑 `test/`，
// 自检脚本自身的编译错误不会被任何门禁发现（2026-09-25 在 core 里真实漏过一次）。
// 加入口时同时改 import 与 `entries`。另见 `docs/testing.md` §零。

// ignore: unused_import
import '../test/auth_test.dart' as auth_test;
// ignore: unused_import
import '../test/client_server_test.dart' as client_server_test;
// ignore: unused_import
import '../test/http_server_test.dart' as http_server_test;
// ignore: unused_import
import '../test/pairing_test.dart' as pairing_test;
// ignore: unused_import
import '../test/service_controller_test.dart' as service_controller_test;
import '../test/sync_server_test.dart' as sync_server_test;

// ignore: unused_import
import 'selfcheck_client_server.dart' as selfcheck_client_server;
// ignore: unused_import
import 'selfcheck_host.dart' as selfcheck_host;
// ignore: unused_import
import 'selfcheck_service.dart' as selfcheck_service;
import 'selfcheck_queue_sink.dart' as selfcheck_queue_sink;
import 'selfcheck_sync.dart' as selfcheck_sync;

void main() {
  final List<void Function()> entries = <void Function()>[
    // test/
    auth_test.main,
    client_server_test.main,
    http_server_test.main,
    pairing_test.main,
    service_controller_test.main,
    sync_server_test.main,
    // tool/
    selfcheck_client_server.main,
    selfcheck_host.main,
    selfcheck_service.main,
    selfcheck_queue_sink.main,
    selfcheck_sync.main,
  ];
  print(
    '编译通过：6 个测试文件 + 4 个自检脚本已通过类型检查（未执行）。'
    '（共 ${entries.length} 个入口）',
  );
}
