// 明细行「并排 / 堆叠」判定（M10，2026-10-08）。
//
// 真机症状：窄屏 + 超大字号（设置里最高 200%）时，单价框的
// 「单价（元/箱）」label 被压成省略号 —— 根因是明细行固定横向比例。
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:test/test.dart';

void main() {
  group('entryFieldsShouldStack（M10）', () {
    test('宽屏 + 标准字号 ⇒ 并排（桌面行为零变化）', () {
      expect(
        entryFieldsShouldStack(maxWidth: 800, textScale: 1),
        isFalse,
      );
    });

    test('窄屏 + 标准字号 ⇒ 堆叠（阈值 340）', () {
      expect(entryFieldsShouldStack(maxWidth: 300, textScale: 1), isTrue);
      expect(entryFieldsShouldStack(maxWidth: 339, textScale: 1), isTrue);
      expect(
        entryFieldsShouldStack(maxWidth: entryFieldsMinWidth, textScale: 1),
        isFalse,
        reason: '正好等于阈值 ⇒ 还放得下（判据是 < 阈值）',
      );
    });

    test('真机 M10 场景：360 宽 + 2 倍字号 ⇒ 必须堆叠', () {
      expect(entryFieldsShouldStack(maxWidth: 360, textScale: 2), isTrue);
    });

    test('同一宽度，字号越大越倾向堆叠（阈值随字号放宽）', () {
      // 400 宽：标准字号放得下，2 倍字号放不下
      expect(entryFieldsShouldStack(maxWidth: 400, textScale: 1), isFalse);
      expect(entryFieldsShouldStack(maxWidth: 400, textScale: 2), isTrue);
      // 桌面大窗 + 2 倍字号仍然并排（不能把桌面行为改坏）
      expect(entryFieldsShouldStack(maxWidth: 900, textScale: 2), isFalse);
    });

    test('无界宽度（横向滚动容器）⇒ 不堆叠（没有「太窄」这回事）', () {
      expect(
        entryFieldsShouldStack(maxWidth: double.infinity, textScale: 2),
        isFalse,
      );
    });

    test('非法的字号（0 / 负数）按 1 处理，不能把阈值算成 0', () {
      expect(entryFieldsShouldStack(maxWidth: 300, textScale: 0), isTrue);
      expect(entryFieldsShouldStack(maxWidth: 300, textScale: -2), isTrue);
      expect(entryFieldsShouldStack(maxWidth: 340, textScale: 0), isFalse);
    });
  });
}
