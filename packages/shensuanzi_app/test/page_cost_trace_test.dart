// 单页成本埋点（`SSZ_PAGE_COST_TRACE`）的单元测试（纯 Dart，`dart test` 可跑）。
//
// ## 为什么只测「格式」与「关闭时零行为」
//
// 开关是**编译期常量**：测试进程没传 `--dart-define=SSZ_PAGE_COST_TRACE=true`，
// 所以 `kPageCostTrace` 恒 false。于是这里钉两件事：
//  1. **关闭时不许有任何副作用**（不建文件）—— 这正是正式包的行为；
//  2. **格式必须对**（用纯函数 `pageCostLine` 直接喂数据）。
//     现场要靠这行 JSON 判「重建几次」，格式歪了等于白埋。
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:test/test.dart';

void main() {
  group('关闭时零副作用（= 正式包行为）', () {
    test('kPageCostTrace 在测试里是 false（没传 dart-define）', () {
      expect(kPageCostTrace, isFalse);
    });

    test('finish 不建文件', () async {
      final Directory dir = Directory.systemTemp.createTempSync('ssz_cost_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File target = File(p.join(dir.path, 'page-cost.jsonl'));

      final PageCostTrace trace = PageCostTrace(page: 'stock', file: target);
      trace.build();
      trace.aggregates(39000);
      await trace.finish();

      expect(
        target.existsSync(),
        isFalse,
        reason: '开关关着还写盘 = 正式包每进一次库存页就留一个文件，绝不能发生',
      );
    });

    test('内存库（path 为 null）根本不给落盘目标', () {
      expect(PageCostTrace.fileFor(null), isNull);
    });
  });

  group('计数（纯内存，与开关无关）', () {
    test('builds / aggMs / transitMs 累计正确，且逐次明细按序', () {
      final PageCostTrace trace = PageCostTrace(page: 'stock');
      trace.build();
      trace.aggregates(39000);
      trace.inTransit(70000);
      trace.build();
      trace.aggregates(40000);
      trace.inTransit(71000);

      expect(trace.builds, 2);
      final Map<String, dynamic> json =
          jsonDecode(trace.line(DateTime(2026, 11, 9, 22, 24)))
              as Map<String, dynamic>;
      expect(json['builds'], 2);
      expect(json['aggMs'], 79, reason: '39 + 40：合计，不是平均');
      expect(json['transitMs'], 141);
      final List<dynamic> perBuild = json['perBuild'] as List<dynamic>;
      expect(perBuild.length, 2);
      expect((perBuild[0] as List<dynamic>).sublist(1), <int>[39, 70]);
      expect((perBuild[1] as List<dynamic>).sublist(1), <int>[40, 71]);
    });

    test('先记聚合后记 build 不会崩（调用顺序错了也不许抛）', () {
      final PageCostTrace trace = PageCostTrace(page: 'stock');
      trace.aggregates(39000);
      trace.inTransit(70000);
      expect(trace.builds, 0);
      // ⚠️ 原写法 `line(...) is String` 恒为 true（`line()` 返回就是 `String`），
      // 被 `unnecessary_type_check` 抓了。换成真断言：顺序错了也要能拼出可解析的行。
      expect(trace.line(DateTime(2026, 11, 11)), contains('"page":"stock"'));
    });
  });

  group('格式（纯函数）', () {
    test('pageCostLine：字段齐、是合法 JSON、一条不含换行', () {
      final DateTime now = DateTime(2026, 11, 9, 22, 24, 3);
      final String line = pageCostLine(
        page: 'stock',
        now: now,
        builds: 3,
        spanMs: 2010,
        aggMs: 118,
        transitMs: 211,
        perBuild: <List<int>>[
          <int>[0, 39, 70],
          <int>[812, 40, 71],
          <int>[1600, 39, 70],
        ],
      );
      expect(line, isNot(contains('\n')), reason: 'JSONL 靠换行分条');
      final Map<String, dynamic> json =
          jsonDecode(line) as Map<String, dynamic>;
      expect(json['kind'], 'pagecost');
      expect(json['ts'], now.toIso8601String());
      expect(json['page'], 'stock');
      expect(json['builds'], 3);
      expect(json['spanMs'], 2010);
      expect(json['aggMs'], 118);
      expect(json['transitMs'], 211);
      expect((json['perBuild'] as List<dynamic>).length, 3);
    });

    test('pageCostLine：0 次重建也是合法 JSON（不许拼出 "[,]"）', () {
      final Map<String, dynamic> json =
          jsonDecode(
                pageCostLine(
                  page: 'stock',
                  now: DateTime(2026),
                  builds: 0,
                  spanMs: 12,
                  aggMs: 0,
                  transitMs: 0,
                  perBuild: <List<int>>[],
                ),
              )
              as Map<String, dynamic>;
      expect(json['builds'], 0);
      expect(json['perBuild'], <dynamic>[]);
    });
  });

  test('fileFor：落在库文件旁边的「日志」目录（只拷一个文件夹就够）', () {
    final File? file = PageCostTrace.fileFor(
      p.join('data', '神算子', 'shensuanzi.db'),
    );
    expect(file, isNotNull);
    expect(file!.path, p.join('data', '神算子', '日志', 'page-cost.jsonl'));
  });
}
