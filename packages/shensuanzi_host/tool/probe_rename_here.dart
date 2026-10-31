import 'dart:io';

/// 在**真实数据目录**上验一次「临时文件 + rename」和「原地重写」，
/// 内容写的是**原文件本身**（一个字节都不改），所以不动主机身份。
///
/// 用法：`dart run tool/probe_rename_here.dart "D:\神算子数据\host.json"`
void main(List<String> args) {
  final File target = File(args.single);
  if (!target.existsSync()) {
    stderr.writeln('没有这个文件：${target.path}');
    exit(2);
  }
  final List<int> original = target.readAsBytesSync();
  final File temp = File('${target.path}.probe-tmp');

  // ① L1：临时文件 + rename（内容与原文件完全相同）
  String l1;
  try {
    temp.writeAsBytesSync(original, flush: true);
    temp.renameSync(target.path);
    l1 = 'ok';
  } catch (error) {
    l1 = '失败：$error';
    if (error is FileSystemException) {
      l1 += ' errno=${error.osError?.errorCode}';
    }
  } finally {
    if (temp.existsSync()) {
      try {
        temp.deleteSync();
      } catch (_) {}
    }
  }
  stdout.writeln('L1 rename = $l1');

  // ② L2：原地重写（同样写原内容）
  String l2;
  try {
    target.writeAsBytesSync(original, flush: true);
    l2 = 'ok';
  } catch (error) {
    l2 = '失败：$error';
    if (error is FileSystemException) {
      l2 += ' errno=${error.osError?.errorCode}';
    }
  }
  stdout.writeln('L2 inplace = $l2');

  // ③ 复核：内容是否与原来逐字节相同
  final List<int> after = target.readAsBytesSync();
  final bool same =
      after.length == original.length &&
      List<int>.generate(original.length, (int i) => i).every(
        (int i) => after[i] == original[i],
      );
  stdout.writeln('内容未变 = $same（${after.length} 字节）');
}
