// 打印**当前进程**的完整性级别 —— 联调 #1 的排障工具（2026-11-01）。
//
// 用法：`dart run tool/probe_integrity.dart`
//   level=medium ⇒ 正常
//   level=low    ⇒ 这个进程什么都写不进去（exe 带了 Low 标签）
//
// 注意：`dart run` 由正常终端启动时是 Medium，**证不了一个 Low 的 exe**；
// 要验 Low 分支，就在那台出问题的机器上双击 exe 看界面提示。
import 'dart:io';

import 'package:shensuanzi/src/integrity.dart';

void main() {
  final IntegrityLevel level = detectIntegrityLevel();
  stdout.writeln('RESULT level=${level.name}');
  stdout.writeln(
    'RESULT notice=${lowIntegrityNotice(level) == null ? '（不提示）' : '（会提示）'}',
  );
}
