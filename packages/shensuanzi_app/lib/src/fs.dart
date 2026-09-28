/// 文件系统小工具 —— **导出与备份共用**（§AF 建议 1）。
///
/// 为什么单独一个文件：备份（§AE）与导出（§AF）都需要「确认目录可写」这一步，
/// 而它的失败形态**不止一种**（目录被删 / 被设只读 / 磁盘满 / 路径上蹲着
/// 一个同名文件）。两处各写一遍 = 两处各自漏掉一两种，用户看到两套措辞。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 确保 [directory] 存在且**真的能写**。
///
/// 返回 `null` = 可以用；否则返回一句**给用户看**的失败文案（说「怎么办」，
/// 并把出问题的路径写出来 —— `docs/ui_principles.md` §二）。
///
/// [label] 是「哪个文件夹」的说法（`备份文件夹` / `导出文件夹`），
/// 因为同一段判断要用在两个功能上，措辞必须能变。
///
/// 三步：
/// 1. 目录不存在 → `createSync(recursive: true)`
/// 2. 建不出来（**被删 / 只读 / 路径上蹲着一个同名文件**）→ 返回失败
/// 3. 建得出来也不代表能写 → 写一个探针文件再删掉（**真写一次才算数**）
String? ensureWritableDirectory(String directory, {required String label}) {
  final Directory dir = Directory(directory);
  try {
    if (!dir.existsSync()) dir.createSync(recursive: true);
  } catch (_) {
    return '$label用不了（$directory）。'
        '请检查它是不是被删掉、被设成只读，或者磁盘满了';
  }

  final File probe = File(
    p.join(directory, '.probe-${DateTime.now().microsecondsSinceEpoch}'),
  );
  try {
    probe.writeAsStringSync('');
  } catch (_) {
    return '$label不可写（$directory）。'
        '请检查磁盘是否已满，或文件夹是否被设为只读';
  } finally {
    if (probe.existsSync()) probe.deleteSync();
  }
  return null;
}
