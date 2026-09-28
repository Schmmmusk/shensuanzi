// 导出的**假实现**（不碰磁盘）—— 页面 widget 测试用。
//
// 为什么需要它：五页导出按钮的测试不该真往磁盘写文件（§AF 门禁：
// 「注入桩，不真写文件」）。有了它，测试还能顺带断言
// **页面拼出来的表**是几行、列对不对 —— 比只看 SnackBar 有价值得多。
//
// ⚠️ 它实现的是 `ExportSink`（能力面），不是 `ExportService` ——
// 页面只依赖前者，于是测试可以从这里注入。
import 'package:shensuanzi_app/shensuanzi_app.dart';

class FakeExport implements ExportSink {
  /// 每次调用收到的表（按调用顺序）
  final List<ExportTable> tables = <ExportTable>[];

  /// 每次调用传的 `extra`（往来方名）与 `from`（时间范围起点）
  final List<String?> extras = <String?>[];
  final List<DateTime?> froms = <DateTime?>[];

  /// 想返回什么结果就换掉它（默认成功）
  ExportOutcome result = const ExportSuccess(
    path: r'D:\神算子导出\神算子-商品-20260928.csv',
    rowCount: 3,
  );

  int get calls => tables.length;

  ExportTable get last => tables.last;

  @override
  Future<ExportOutcome> write(
    ExportTable table, {
    String? extra,
    DateTime? from,
  }) async {
    tables.add(table);
    extras.add(extra);
    froms.add(from);
    return result;
  }
}
