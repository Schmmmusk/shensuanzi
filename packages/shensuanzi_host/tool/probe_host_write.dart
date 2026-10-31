// 主机身份文件写入的**真机式探针**：`dart run tool/probe_host_write.dart <host.json>`
//
// 为什么单独留一个：`test/host_write_test.dart` 用假 IO 覆盖了九种故障，
// 但「L2 到底能不能在**真实文件系统**上绕过 rename 被拒」只能真跑一次才算数。
// 2026-10-31 实测（Windows 11）：
//
// | 占用方式 | 结果 |
// |---|---|
// | `FileShare.ReadWrite`（**禁 delete**） | L1 rename 失败 ⇒ **L2 原地重写成功**（level=inPlace） |
// | `FileShare.Read`（**禁 write + delete**） | L1 失败(errno 5) ⇒ L2 失败(errno 32) ⇒ L3，**旧内容原样保留** |
//
// 用法：外部先用 `[System.IO.File]::Open($f, "Open", "ReadWrite", "ReadWrite")`
// 夹住文件，再调本脚本 —— 只靠 Dart 自己的 `openSync` 夹不住（Dart 的句柄带
// FILE_SHARE_DELETE，rename 照样能过）。
//
// ⚠️ 输出用 `RESULT` 前缀，便于外部 `Select-String` 过滤。

import 'dart:io';

import 'package:shensuanzi_host/shensuanzi_host.dart';

/// 在**真实文件系统**上跑一次 `reset`，把结果打出来（供外部夹着句柄调用）。
///
/// 用法：`dart run tool/_l2_probe.dart <host.json 路径>`
void main(List<String> args) {
  final File target = File(args.single);
  final HostIdentityStore store = HostIdentityStore(target);
  final HostIdentity id = store.reset(now: 1000);
  stdout.writeln('RESULT failed=${store.lastWriteFailed}');
  stdout.writeln('RESULT level=${store.lastWriteLevel?.name}');
  stdout.writeln('RESULT diag=${store.lastWriteDiagnostics ?? '（无）'}');
  stdout.writeln('RESULT plaintext=${id.plaintextToken != null}');
  try {
    stdout.writeln(
      'RESULT file=${target.readAsStringSync().replaceAll('\n', ' ')}',
    );
  } catch (error) {
    stdout.writeln('RESULT file-unreadable=$error');
  }
}
