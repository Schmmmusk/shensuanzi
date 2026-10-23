// `lib/src/ui/scaled.dart` 的机械保证（批 3 第 13 条）。
//
// 这个文件是「尺寸/断点随缩放派生」的**唯一来源**：所有页面都从这里取。
// 它错了，全应用的布局判据一起错 —— 所以单独钉住。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/scaled.dart';

void main() {
  /// 在一个指定缩放下取 context 做断言
  Future<T> withScale<T>(
    WidgetTester tester,
    double scale,
    T Function(BuildContext context) body,
  ) async {
    late T result;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData().copyWith(
          textScaler: TextScaler.linear(scale),
        ),
        child: Builder(
          builder: (BuildContext context) {
            result = body(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return result;
  }

  testWidgets('uiScaleOf 取的是**环境里实际生效**的倍数', (WidgetTester tester) async {
    expect(await withScale(tester, 1.0, uiScaleOf), 1.0);
    expect(await withScale(tester, 1.25, uiScaleOf), 1.25);
    expect(await withScale(tester, 2.0, uiScaleOf), 2.0);
  });

  testWidgets('scaledOf：基准尺寸 × 缩放', (WidgetTester tester) async {
    expect(
      await withScale(tester, 1.25, (BuildContext c) => scaledOf(c, 96)),
      120.0,
    );
    expect(
      await withScale(tester, 2.0, (BuildContext c) => scaledOf(c, 48)),
      96.0,
    );
  });

  testWidgets('isNarrowOf：断点跟着缩放走', (WidgetTester tester) async {
    // 1.0 档：480 是界
    expect(
      await withScale(tester, 1.0, (BuildContext c) => isNarrowOf(c, 479)),
      isTrue,
    );
    expect(
      await withScale(tester, 1.0, (BuildContext c) => isNarrowOf(c, 481)),
      isFalse,
    );
    // 2.0 档：界变成 960 —— **同一宽度 700 从「够宽」变成「窄」**
    expect(
      await withScale(tester, 2.0, (BuildContext c) => isNarrowOf(c, 700)),
      isTrue,
    );
    expect(
      await withScale(tester, 2.0, (BuildContext c) => isNarrowOf(c, 961)),
      isFalse,
    );
  });

  testWidgets('isNarrowOf：可以换基准（流水页 600）', (WidgetTester tester) async {
    expect(
      await withScale(
        tester,
        1.0,
        (BuildContext c) => isNarrowOf(c, 599, base: flowNarrowBase),
      ),
      isTrue,
    );
    expect(
      await withScale(
        tester,
        1.0,
        (BuildContext c) => isNarrowOf(c, 601, base: flowNarrowBase),
      ),
      isFalse,
    );
  });
}
