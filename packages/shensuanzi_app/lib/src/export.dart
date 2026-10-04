/// 导出执行（`docs/reply_review.md` §AF / `docs/reply.md` §AF 审查裁定）。
///
/// ## 判断都在本文件（纯 Dart，`dart test` 覆盖），UI 只摆放
///
/// - **AF-5 无上限**：行由 core 的 `*ForExport` 读出来（页面的 200 上限
///   不参与）—— 导出少一行**谁都不知道**，这是最危险的一类 bug
/// - **AF-3 目录主动创建**：每次导出前 `ensureWritableDirectory`
///   （第一次导出时目录还不存在），失败给「怎么办」
/// - **遗漏 2 并发**：同一份文件正在写时，新请求复用同一个 Future
/// - **遗漏 3 按钮状态**：UI 侧点击即禁用 +「导出中…」（本文件不管）
/// - **遗漏 4 空结果**：0 行**不生成文件**（只写表头的 CSV 会让用户以为坏了）
/// - **坑 1 / 坑 2 / 遗漏 1**：编码与转义全在 [csvBytes]（`csv.dart`）
/// - **遗漏 5**：结果文案（成功带**完整路径**）
///
/// ⚠️ **文件读写一律用同步 API**（`writeAsBytesSync`）：与 `BackupService`
/// 同一个理由 —— 数据量是几百 KB 级，而**异步 IO 在 widget 测试里不会自己
/// 完成**（`testWidgets` 的 fake async 不推真实事件循环），会让测试必须套
/// `runAsync`，测出来的东西更远。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'csv.dart';
import 'format.dart';
import 'fs.dart';

/// 一张待导出的表：**列名 + 行**（映射规则在 `export_tables.dart`，纯 Dart 可测）。
class ExportTable {
  /// ⚠️ **v3 口径（§BD·四 #3）**：导出列里**不许出现「单价」**。
  ///
  /// `unit_price` 自 v3 起是**派生展示**（= `round(amount / quantity)`），
  /// 拿它导出会有舍入差（36 × 2083 ≠ 75000）—— 明细级金额只许用 `amount`，
  /// 单据级用 `total_amount`。当前全部导出都是单据级/聚合级。
  ///
  /// 守卫在 [ExportSink.write] 的执行路径上（`_guardExportHeader`）——
  /// **不能放这里**：const 构造的 initializer assert 不允许方法调用/闭包。
  const ExportTable({
    required this.label,
    required this.header,
    required this.rows,
  });

  /// 表名（`商品` / `库存` / `往来方` / `单据` / `往来流水`）—— 进文件名
  final String label;

  /// 中文列名（给人看，不是字段名）
  final List<String> header;

  final List<List<String>> rows;

  bool get isEmpty => rows.isEmpty;
}

/// 导出文件名（§AF-7：中文 + 日期 + **无空格**）。
///
/// ```text
/// 神算子-商品-20260928.csv
/// 神算子-单据-20260928-20260601至20260928.csv   ← 有时间范围
/// 神算子-往来流水-王老板-20260928.csv            ← 带上往来方名，否则
///                                                  导三个往来方文件名全一样
/// ```
class ExportFileName {
  const ExportFileName({
    required this.label,
    required this.date,
    this.extra,
    this.from,
  });

  final String label;

  /// 导出时刻（**本地时间**）
  final DateTime date;

  /// 附在中段的名字（往来方名；用户输入 ⇒ 必须清洗）
  final String? extra;

  /// 时间范围起点（跟随页面 chips；`null` = 全量）
  final DateTime? from;

  /// Windows 不接受的文件名字符 → `_`。
  ///
  /// 往来方名是**用户输入**：`王老板/李老板`、`甲:乙`、结尾带点……写进文件名
  /// 轻则报错重则静默失败。⚠️ 未处理 Windows 保留设备名（`CON`/`NUL`）——
  /// 个体户把客户叫「CON」的概率低于维护成本。
  static String sanitize(String raw) {
    final String cleaned = raw
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (cleaned.isEmpty) return '未命名';
    return cleaned.length <= 40 ? cleaned : cleaned.substring(0, 40);
  }

  String get fileName {
    final StringBuffer buffer = StringBuffer('神算子-')..write(label);
    if (extra != null && extra!.isNotEmpty) {
      buffer
        ..write('-')
        ..write(sanitize(extra!));
    }
    buffer
      ..write('-')
      ..write(formatFileDate(date));
    if (from != null) {
      buffer
        ..write('-')
        ..write(formatFileDate(from!))
        ..write('至')
        ..write(formatFileDate(date));
    }
    return '${buffer.toString()}.csv';
  }
}

/// 导出结果（**sealed**：UI 侧 `switch` 必须穷尽，漏一个分支编不过）。
sealed class ExportOutcome {
  const ExportOutcome();
}

class ExportSuccess extends ExportOutcome {
  const ExportSuccess({required this.path, required this.rowCount});

  /// 最终 CSV 的完整路径（SnackBar 直接展示，用户可复制）
  final String path;

  /// 实际导出的**行数**（不含表头）—— 事后确认放这里最有意义：
  /// 用户点的时候不需要预先知道数量，拿到文件时「导了多少条」才重要（AF-5）
  final int rowCount;
}

/// 0 行 → **没有生成文件**（遗漏 4）
class ExportEmpty extends ExportOutcome {
  const ExportEmpty();
}

class ExportFailed extends ExportOutcome {
  const ExportFailed(this.reason);

  /// 说「怎么办」（领域层写好，UI 不造句）
  final String reason;
}

/// 导出结果的**用户可见**文案。
String exportOutcomeMessage(ExportOutcome outcome) => switch (outcome) {
  ExportSuccess(:final String path, :final int rowCount) =>
    '已导出 $rowCount 条到：\n$path',
  ExportEmpty() => '当前筛选没有数据，没有生成文件',
  ExportFailed(:final String reason) => '导出失败：$reason',
};

/// 导出的**能力面** —— 页面只依赖这个接口。
///
/// 为什么单开一个接口（而不是页面直接吃 `ExportService`）：五页的导出按钮
/// widget 测试**不该真往磁盘写文件**（§AF 门禁：「注入桩，不真写文件」）。
/// 有了接口，测试能注入一个记账用的假实现，还能顺带断言「页面拼出来的表
/// 是几行、列对不对」—— 比只看 SnackBar 有价值。
///
/// 名字不带 CSV：v1 只有 CSV，但这个位置将来要放 XLSX / PDF（§AF-1 留了口）。
abstract interface class ExportSink {
  Future<ExportOutcome> write(
    ExportTable table, {
    String? extra,
    DateTime? from,
  });
}

/// 导出服务。判断都在这里；UI 只调 [write] 并把结果交给 SnackBar。
class ExportService implements ExportSink {
  ExportService({required this.exportDirectory, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// 导出目录（数据目录的**兄弟目录**「神算子导出」，与备份平级）
  final String exportDirectory;

  final DateTime Function() _now;

  /// 遗漏 2：进行中的导出，**按目标文件名**去重。
  ///
  /// 为什么带 key（而不是像备份那样只留一个 `_running`）：备份永远写同一件事，
  /// 复用同一个 Future 是对的；导出**每张表内容不同** —— 复用会把 A 表的结果
  /// 当成 B 表的结果返回，比不做去重更糟。带 key 之后，「狂点两次同一个按钮」
  /// 复用、不同表互不干扰。
  final Map<String, Future<ExportOutcome>> _running =
      <String, Future<ExportOutcome>>{};

  /// 导出一张表。返回同一份文件的并发请求**拿到同一个 Future**（可测的形态）。
  @override
  Future<ExportOutcome> write(
    ExportTable table, {
    String? extra,
    DateTime? from,
  }) {
    final String target = ExportFileName(
      label: table.label,
      date: _now(),
      extra: extra,
      from: from,
    ).fileName;
    final Future<ExportOutcome>? running = _running[target];
    if (running != null) return running;
    // ⚠️ **回调必须写成块体**（`{ … }`），不能写箭头体 `=> _running.remove(target)`：
    // `whenComplete` 的入参类型是 `FutureOr<void> Function()` —— 一旦回调**返回了
    // 一个 Future，它会先等那个 Future**。而箭头体返回的正是刚从 Map 里取出的
    // 那个 Future（= `wrapped` 自己）⇒ **自等待，永不完成**（整个导出静默卡死，
    // 2026-09-28 实测：`selfcheck_export` 直接在第一个 await 处退出）。
    // 单字段版本（`BackupService` 的 `() => _running = null`）没这个坑 ——
    // 赋值表达式的值是 `null`，不是 Future。
    final Future<ExportOutcome> wrapped = _execute(table, target).whenComplete(() {
      _running.remove(target);
    });
    _running[target] = wrapped;
    return wrapped;
  }

  Future<ExportOutcome> _execute(ExportTable table, String fileName) async {
    // v3 口径守卫（§BD·四 #3）：「单价」列不许导出 —— unit_price 是派生展示
    //（见 ExportTable 文档）。放在**真实写盘路径**上，比构造 assert 更有牙。
    if (table.header.any((String column) => column.contains('单价'))) {
      return ExportFailed(
        '导出列配置错误：出现「单价」列。'
        '金额请用成交金额（amount），不要用单价（unit_price 派生展示有舍入差）',
      );
    }

    // 遗漏 4：0 行不生成文件（只有表头的 CSV 会让人以为「导出坏了」）
    if (table.isEmpty) return const ExportEmpty();

    // AF-3：目录第一次导出时还不存在 —— 先建 + 探针真写一次
    final String? problem = ensureWritableDirectory(
      exportDirectory,
      label: '导出文件夹',
    );
    if (problem != null) return ExportFailed(problem);

    final String path = p.join(exportDirectory, fileName);
    try {
      File(path).writeAsBytesSync(csvBytes(table.header, table.rows), flush: true);
      return ExportSuccess(path: path, rowCount: table.rows.length);
    } catch (error) {
      return ExportFailed(
        '导出失败（$error）。请重试；若反复失败，请检查磁盘空间',
      );
    }
  }
}
