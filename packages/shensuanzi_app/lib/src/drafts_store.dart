/// 草稿的**文件存储**（真实诉求批 ①，2026-10-24，§CV·一百零一）。
///
/// ## 放在哪
///
/// `<数据目录>/drafts/<kind>.json`
///
/// - **不进主库**：草稿是脏数据，进 `documents` 会污染流水与对账；
/// - **不进 `%APPDATA%`**：草稿属于「这家店的账」，换数据目录时应该跟着走；
/// - **不进备份**：备份只拷 `shensuanzi.db`（草稿不该被当成账）。
///
/// ## ⚠️ 为什么**全部同步**读写
///
/// 页面 `dispose()` 时要把待落盘的内容写一次（用户可能直接关窗口）。
/// 那里**不能 `await`** —— 一 `await`，widget 已经销毁，紧接着关 App 时
/// 这次异步写盘会被中断，数据照样丢（审查意见 §二-1）。
/// 而草稿只有几十 KB，同步写 1–2 ms，不会卡。
///
/// 所以：**防抖用 Timer（异步），落盘用 `*Sync`（同步）** —— 两者不冲突。
///
/// ## 失败怎么办
///
/// 一律**静默**：目录不可写、磁盘满、文件被占用 —— 草稿是「尽力而为」，
/// 绝不能因为存不了草稿就让开单报错。读坏了（JSON 语法错 / 类型不对）
/// ⇒ 删掉那个文件并返回 `null`（下次进页不再提示）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_core/shensuanzi_core.dart';

/// 草稿文件的读写（**同步**，可在 `dispose` 里安全调用）。
class DraftsStore {
  DraftsStore({required this.dataDirectory});

  /// 数据目录（`shensuanzi.db` 所在处）
  final String dataDirectory;

  /// `drafts/` 子目录
  String get directory => p.join(dataDirectory, 'drafts');

  /// 某个种类的草稿文件路径
  String pathOf(DraftKind kind) => p.join(directory, '${kind.fileName}.json');

  /// 读草稿。没有 / 读坏 / 类型不对 ⇒ `null`（**读坏的会被删掉**）。
  Map<String, Object?>? read(DraftKind kind) {
    final File file = File(pathOf(kind));
    if (!file.existsSync()) return null;
    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) {
        _deleteQuietly(file);
        return null;
      }
      return Map<String, Object?>.from(decoded);
    } catch (_) {
      // 语法错 / 编码错 ⇒ 删掉：留着一个读不了的文件只会每次进页都白读一遍
      _deleteQuietly(file);
      return null;
    }
  }

  /// 写草稿（**同步**）。失败静默（草稿是尽力而为）。
  ///
  /// 先写 `.tmp` 再改名 —— 中途断电不会留下半个 JSON。
  bool writeSync(DraftKind kind, Map<String, Object?> json) {
    try {
      final Directory dir = Directory(directory);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final String target = pathOf(kind);
      final String tmp = '$target.tmp';
      File(tmp).writeAsStringSync(jsonEncode(json), flush: true);
      File(tmp).renameSync(target);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 删草稿（保存成功 / 主动放弃 / 取消并确认）。
  void delete(DraftKind kind) => _deleteQuietly(File(pathOf(kind)));

  /// 有草稿吗（**只判存在，不解析** —— 进页时先问这个，避免白读大文件）。
  bool exists(DraftKind kind) => File(pathOf(kind)).existsSync();

  void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // 删不掉不影响结论（下次读的时候会再试）
    }
  }
}
