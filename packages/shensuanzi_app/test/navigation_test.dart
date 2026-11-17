import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:test/test.dart';

void main() {
  // ============================================================ 完整性
  group('导航结构 · 完整性', () {
    test('每个入口都有非空文字标签（图标-only 对中老年用户等于不存在）', () {
      for (final NavDestination destination in AppNavigation.destinations) {
        expect(destination.label.trim(), isNotEmpty, reason: destination.id);
        expect(destination.iconKey.trim(), isNotEmpty, reason: destination.id);
      }
    });

    test('id 唯一', () {
      final Set<String> ids = <String>{
        for (final NavDestination d in AppNavigation.destinations) d.id,
      };
      expect(ids.length, AppNavigation.destinations.length);
    });

    test('入口数量够覆盖核心功能（至少 9 项）', () {
      expect(AppNavigation.destinations.length, greaterThanOrEqualTo(9));
    });

    test('不留空组（空组会渲染出一条孤立分隔线）', () {
      for (final NavSection section in NavSection.values) {
        expect(AppNavigation.of(section), isNotEmpty, reason: section.name);
      }
    });

    test('分组顺序 = 声明顺序：首页 → 高频动作 → 数据查询 → 系统', () {
      expect(NavSection.values.map((NavSection s) => s.name), <String>[
        'home',
        'quick',
        'data',
        'system',
      ]);

      // 取出每项在列表中的下标，验证 section 是**分段连续**的
      final List<NavSection> order = <NavSection>[
        for (final NavDestination d in AppNavigation.destinations) d.section,
      ];
      final List<NavSection> contiguous = <NavSection>[];
      for (final NavSection section in order) {
        if (contiguous.isEmpty || contiguous.last != section) {
          contiguous.add(section);
        }
      }
      expect(
        contiguous,
        NavSection.values,
        reason: '同一个组必须连成一段，不能穿插（否则分隔线会错位）',
      );
    });
  });

  // ============================================================ 分组内容
  group('导航结构 · 分组内容', () {
    test('高频动作是三个开单页，且排在最上面', () {
      expect(
        AppNavigation.of(NavSection.quick).map((NavDestination d) => d.id),
        <String>['sale', 'delivery', 'purchase'],
        reason: '§AP：送货与销售 / 采购并列，**不做模式开关**',
      );
      // 在整张列表里紧随首页之后
      expect(AppNavigation.destinations[1].section, NavSection.quick);
    });

    test('数据查询按「找什么」组织', () {
      expect(
        AppNavigation.of(NavSection.data).map((NavDestination d) => d.label),
        <String>['商品', '库存', '单据', '往来方', '账户'],
      );
    });

    test('系统组在最后', () {
      expect(
        AppNavigation.of(NavSection.system).map((NavDestination d) => d.label),
        <String>['设置', '帮助'],
      );
      expect(AppNavigation.destinations.last.section, NavSection.system);
    });

    test('首页组只有概览，且是列表第一项', () {
      expect(
        AppNavigation.of(NavSection.home).map((NavDestination d) => d.id),
        <String>['overview'],
      );
      expect(AppNavigation.destinations.first.id, 'overview');
    });
  });

  // ============================================================ 沉浸模式
  group('沉浸模式', () {
    test('只有开单页是沉浸模式（销售开单 / 送货 / 采购入库）', () {
      final Set<String> immersive = <String>{
        for (final NavDestination d in AppNavigation.destinations)
          if (d.immersive) d.id,
      };
      expect(immersive, <String>{'sale', 'delivery', 'purchase'});
    });

    test('查询类与系统类都不是沉浸模式（要显示面包屑）', () {
      for (final NavDestination d in <NavDestination>[
        ...AppNavigation.of(NavSection.data),
        ...AppNavigation.of(NavSection.system),
        ...AppNavigation.of(NavSection.home),
      ]) {
        expect(d.immersive, isFalse, reason: d.id);
      }
    });
  });

  // ============================================================ 查找
  group('查找与默认项', () {
    test('byId 命中', () {
      expect(AppNavigation.byId('sale')!.label, '销售开单');
      expect(AppNavigation.byId('settings')!.label, '设置');
    });

    test('byId 未命中 / null → null（旧配置里的 id 可能已不存在，不能抛）', () {
      expect(AppNavigation.byId('nope'), isNull);
      expect(AppNavigation.byId(null), isNull);
      expect(AppNavigation.byId(''), isNull);
    });

    test('initial：没给 id → 概览', () {
      expect(AppNavigation.initial().id, 'overview');
      expect(AppNavigation.fallbackId, 'overview');
    });

    test('initial：给了合法 id → 用它；给了非法 id → 退回概览而不是空白', () {
      expect(AppNavigation.initial('stock').id, 'stock');
      expect(AppNavigation.initial('已不存在的页面').id, 'overview');
    });

    test('fallbackId 必须真的存在（否则 initial 会静默跑到第一项）', () {
      expect(AppNavigation.byId(AppNavigation.fallbackId), isNotNull);
    });
  });

  // ============================================================ 宽度
  group('导航宽度', () {
    test('默认 220；紧凑 160', () {
      expect(AppNavigation.expandedWidth, 220);
      expect(AppNavigation.compactWidth, 160);
      expect(AppNavigation.widthFor(), 220);
      expect(AppNavigation.widthFor(compact: true), 160);
    });

    test('按缩放等比放大（文字不换行）', () {
      expect(AppNavigation.widthFor(scale: 1.5), 330);
      expect(AppNavigation.widthFor(scale: 2), 440);
    });

    test('缩放再大也不低于「仅图标」宽度（兜底，不是默认）', () {
      expect(AppNavigation.widthFor(scale: 0.2), AppNavigation.iconOnlyWidth);
      expect(
        AppNavigation.widthFor(compact: true, scale: 0.1),
        AppNavigation.iconOnlyWidth,
      );
    });

    test('点击区高度 ≥ 44（中老年用户的最小可点区域）', () {
      expect(AppNavigation.itemHeight, greaterThanOrEqualTo(44));
      expect(AppNavigation.indicatorWidth, 3, reason: '高亮竖条是三重信号之一');
    });
  });

  // ============================================================ 实际列宽
  //
  // 2026-11-14 用户真机（系统 200% + 应用超大）：列宽 440 逻辑，而标签只要 143
  // ⇒ **列内 68% 是空的**，导航仍吃掉 35% 横向空间。裁定「甲」：
  // 列宽 = 基准宽 + **内容增长量**（余量固定，不跟着缩放放大）。
  group('导航实际列宽（navWidth）', () {
    test('1.0 档：等于基准宽 220（观感不变）', () {
      expect(AppNavigation.contentWidthFor(scale: 1.0), 104);
      expect(AppNavigation.navWidth(scale: 1.0, availableWidth: 1247), 220);
    });

    test('2.0 档：296 而不是 440（旧式子的空列被一起放大了）', () {
      // 改坏点：navWidth 退回 `widthFor(scale)` ⇒ 这条红（440）
      expect(AppNavigation.contentWidthFor(scale: 2.0), 180);
      expect(
        AppNavigation.navWidth(scale: 2.0, availableWidth: 1247),
        296,
        reason: '220 + (180 − 104)：只让内容那 76 增长',
      );
      expect(
        AppNavigation.navWidth(scale: 2.0, availableWidth: 1247),
        lessThan(AppNavigation.widthFor(scale: 2.0)),
        reason: '必须比线性放大的旧值窄 —— 否则等于没改',
      );
    });

    test('窗口占比上限仍兜底（分屏 480 逻辑宽 ⇒ 40% = 192）', () {
      expect(AppNavigation.navWidth(scale: 2.0, availableWidth: 480), 192);
    });

    test('极窄窗口：退成仅图标，宽度按缩放算（60 只是下限）', () {
      // 2026-11-17（用户真机确认「够用」，裁定甲）：断言从 60 改成 76。
      // 76 = 3 + 13 + 12 + 20×2 + 8 —— 图标本身随字号放大，60 是 1.0 档的下限。
      // 原来的 60 是 2026-11-14「仅图标」落地**之前**的期望，两轮改动后
      // 两条断言互相矛盾（挂了 1 天，见 docs/reply_review.md §九十六）。
      expect(AppNavigation.navWidth(scale: 2.0, availableWidth: 100), 76);
    });

    test('仅图标宽度**永不低于** iconOnlyWidth（下限护栏）', () {
      for (final double s in <double>[1.0, 1.25, 1.5, 2.0, 3.0]) {
        final ({double width, bool iconOnly}) l = AppNavigation.navLayout(
          scale: s,
          availableWidth: 100,
        );
        expect(l.iconOnly, isTrue, reason: '100 宽的窗口必然装不下标签');
        expect(
          l.width,
          greaterThanOrEqualTo(AppNavigation.iconOnlyWidth),
          reason: 'scale $s：图标再小也不能窄过 1.0 档的下限（否则点击区不足）',
        );
      }
    });

    test('装不下标签 ⇒ 退成仅图标（iconOnly=true），宽度按图标算', () {
      // 420 宽 / 2.0 档：40% 上限 168 < 内容需求 180 ⇒ 只剩图标
      final ({double width, bool iconOnly}) at420 = AppNavigation.navLayout(
        scale: 2.0,
        availableWidth: 420,
      );
      expect(at420.iconOnly, isTrue);
      expect(at420.width, 3 + 13 + 12 + 20 * 2.0 + 8, reason: '竖条+间距+图标+余量');
      expect(at420.width, greaterThan(AppNavigation.iconOnlyWidth));
    });

    test('挤但还装得下 ⇒ 仍是文字（480 宽 / 2.0 档 ⇒ 192）', () {
      // 改坏点：把 iconOnly 判据写成「比 widthFor 小就退化」⇒ 这条会红
      final ({double width, bool iconOnly}) at480 = AppNavigation.navLayout(
        scale: 2.0,
        availableWidth: 480,
      );
      expect(at480.iconOnly, isFalse);
      expect(at480.width, 192, reason: '撞 40% 上限，但 192 ≥ 内容 180 ⇒ 标签放得下');
    });

    test('正常窗口（1247 宽 / 2.0 档）⇒ 296，且不是仅图标', () {
      final ({double width, bool iconOnly}) big = AppNavigation.navLayout(
        scale: 2.0,
        availableWidth: 1247,
      );
      expect(big.iconOnly, isFalse);
      expect(big.width, 296);
      expect(
        AppNavigation.navWidth(scale: 2.0, availableWidth: 1247),
        big.width,
      );
    });

    test('最长标签不超过 labelMaxChars（否则列宽算小了会截断）', () {
      for (final NavDestination destination in AppNavigation.destinations) {
        expect(
          destination.label.length,
          lessThanOrEqualTo(AppNavigation.labelMaxChars),
          reason: '「${destination.label}」比 labelMaxChars 长 —— 改导航结构时忘了同步列宽公式',
        );
      }
    });
  });
}
