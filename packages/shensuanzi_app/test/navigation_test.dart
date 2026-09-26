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
      expect(
        NavSection.values.map((NavSection s) => s.name),
        <String>['home', 'quick', 'data', 'system'],
      );

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
    test('高频动作只有两个开单页，且排在最上面', () {
      expect(
        AppNavigation.of(NavSection.quick).map((NavDestination d) => d.id),
        <String>['sale', 'purchase'],
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
    test('只有开单页是沉浸模式（销售开单 / 采购入库）', () {
      final Set<String> immersive = <String>{
        for (final NavDestination d in AppNavigation.destinations)
          if (d.immersive) d.id,
      };
      expect(immersive, <String>{'sale', 'purchase'});
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
      expect(AppNavigation.widthFor(compact: true, scale: 0.1),
          AppNavigation.iconOnlyWidth);
    });

    test('点击区高度 ≥ 44（中老年用户的最小可点区域）', () {
      expect(AppNavigation.itemHeight, greaterThanOrEqualTo(44));
      expect(AppNavigation.indicatorWidth, 3, reason: '高亮竖条是三重信号之一');
    });
  });
}
