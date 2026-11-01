// **跨进程**验证「重启后能画出同一个码」—— 提案 57 的总验收（2026-11-01）。
//
// 为什么必须跨进程：`HostIdentityStore` 的「重启」语义是**新进程读同一个文件**。
// 同一个进程里 new 一个 store 只能证明内存逻辑对，证明不了 DPAPI 密文在
// **另一个进程**里也能解开（用户主密钥的加载、用户上下文都在进程之外）。
//
// 用法（两步，必须分两个进程）：
//   dart run tool/probe_restart_token.dart create <dir>
//   dart run tool/probe_restart_token.dart load   <dir>
// 输出以 `RESULT` 开头，便于外部过滤。
import 'dart:io';

import 'package:shensuanzi_host/shensuanzi_host.dart';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('用法：dart run tool/probe_restart_token.dart <create|load> <dir>');
    exit(2);
  }
  final String mode = args[0];
  final File file = File(
    '${args[1]}${Platform.pathSeparator}host.json',
  );
  final HostIdentityStore store = HostIdentityStore(file);

  if (mode == 'create') {
    file.parent.createSync(recursive: true);
    final HostIdentity id = store.reset(now: 1000);
    stdout.writeln('RESULT host_id=${id.hostId}');
    stdout.writeln('RESULT token_hash=${id.tokenHash}');
    stdout.writeln('RESULT plaintext=${id.plaintextToken}');
    stdout.writeln('RESULT protect_problem=${store.lastProtectProblem ?? '（无）'}');
    final String raw = file.readAsStringSync();
    stdout.writeln('RESULT file_has_protected=${raw.contains('token_protected')}');
    stdout.writeln('RESULT file_has_plaintext=${raw.contains(id.plaintextToken!)}');
    exit(0);
  }

  if (mode == 'load') {
    final HostIdentity? loaded = store.load();
    stdout.writeln('RESULT restore_state=${store.lastRestoreState.name}');
    stdout.writeln('RESULT restore_problem=${store.lastRestoreProblem ?? '（无）'}');
    stdout.writeln('RESULT host_id=${loaded?.hostId}');
    stdout.writeln('RESULT token_hash=${loaded?.tokenHash}');
    stdout.writeln('RESULT plaintext=${loaded?.plaintextToken}');
    stdout.writeln('RESULT can_show_qr=${loaded?.canShowQr}');
    exit(0);
  }

  stderr.writeln('未知模式：$mode');
  exit(2);
}
