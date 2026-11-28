import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/keyboard_reveal.dart';

void main() {
  testWidgets('键盘高度连续变化时已可见的焦点保持原位', (tester) async {
    final focus = FocusNode();
    final scroll = ScrollController(initialScrollOffset: 80);
    addTearDown(focus.dispose);
    addTearDown(scroll.dispose);
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpWidget(
      MaterialApp(
        home: KeyboardReveal(
          child: Scaffold(
            body: SingleChildScrollView(
              controller: scroll,
              child: Column(
                children: [
                  const SizedBox(height: 120),
                  Focus(
                    focusNode: focus,
                    child: const SizedBox(height: 50, width: 200),
                  ),
                  const SizedBox(height: 1400),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    final original = scroll.offset;
    tester.view.viewInsets = const FakeViewPadding(bottom: 120);
    await tester.pump(const Duration(milliseconds: 16));
    tester.view.viewInsets = const FakeViewPadding(bottom: 270);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    expect(scroll.offset, original);
  });
  testWidgets('键盘遮住字段时只移动被遮挡的距离，并尊重减少动态效果', (tester) async {
    final focus = FocusNode();
    final scroll = ScrollController();
    addTearDown(focus.dispose);
    addTearDown(scroll.dispose);
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    const key = Key('focused-field');
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: KeyboardReveal(
          child: Scaffold(
            body: SingleChildScrollView(
              controller: scroll,
              child: Column(
                children: [
                  const SizedBox(height: 540),
                  Focus(
                    focusNode: focus,
                    child: const SizedBox(key: key, height: 50, width: 200),
                  ),
                  const SizedBox(height: 900),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    await tester.pump(const Duration(milliseconds: 16));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump(const Duration(milliseconds: 16));
    expect(scroll.offset, 0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(scroll.offset, closeTo(90, 1));
    expect(tester.getBottomLeft(find.byKey(key)).dy, closeTo(500, 1));
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(90, 1));
  });
}
