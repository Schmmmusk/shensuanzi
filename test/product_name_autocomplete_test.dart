// 商品名称自动补全 —— **匹配与排序**的纯函数测试（提案 §七 第 1、2 条）。
//
// 为什么先测这个：排序规则是「完全匹配 > 前缀 > 包含 > 编码」，
// 它决定了用户按回车会选中哪一个。写错不会崩，只会「老是选中错的」——
// 那是最难被发现的一类问题。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/product_name_autocomplete.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

Product _p(
  String code,
  String name, {
  String? barcode,
  bool active = true,
  int cost = 1000,
  int sell = 1500,
}) => Product(
  id: 'id-$code',
  code: code,
  name: name,
  barcode: barcode,
  isActive: active,
  costPrice: cost,
  sellPrice: sell,
  createdAt: 1700000000000,
  updatedAt: 1700000000000,
);

List<String> _names(List<Product> products) =>
    products.map((Product p) => p.name).toList();

void main() {
  final List<Product> shelf = <Product>[
    _p('P0001', '大米'),
    _p('P0002', '大米（东北）'),
    _p('P0003', '优质大米'),
    _p('P0004', '可口可乐'),
    _p('P0005', '面粉'),
    _p('P0006', '停用大米', active: false),
  ];

  group('排序：完全匹配 > 前缀 > 包含 > 编码', () {
    test('输入「大米」：完全匹配排第一，前缀次之，包含最后', () {
      expect(
        _names(rankProductMatches('大米', shelf)),
        <String>['大米', '大米（东北）', '优质大米'],
        reason:
            '「大米」是 P0001 的完整名称 ⇒ 第一；「大米（东北）」是前缀 ⇒ 第二；'
            '「优质大米」只是包含 ⇒ 第三。停用商品不出现（见下一条）',
      );
    });

    test('输入「大米（」：只有前缀命中', () {
      expect(_names(rankProductMatches('大米（', shelf)), <String>['大米（东北）']);
    });

    test('输入「米」：三条都命中，顺序按 完全=无 > 前缀=无 > 包含', () {
      // 没有以「米」开头的商品，所以三条全是「包含」，按 code 升序稳定
      expect(_names(rankProductMatches('米', shelf)), <String>[
        '大米',
        '大米（东北）',
        '优质大米',
      ], reason: '同分按 code 升序 —— 每次按键顺序不能抖');
    });

    test('前缀优先于包含 —— **即使包含项的 code 更小**', () {
      // ⚠️ 这条是反向灵敏度逼出来的：上面那条「大米」的用例里，前缀项
      // （P0002）恰好 code 也比包含项（P0003）小 ⇒ 把「前缀」这一档整个废掉，
      // 顺序照样不变，测试**钉不住**。这里刻意让前缀项的 code 更大。
      final List<Product> tricky = <Product>[
        _p('P0001', '优质大米'), // 包含，code 小
        _p('P0009', '大米粉'), // 前缀，code 大
      ];
      expect(
        _names(rankProductMatches('大米', tricky)),
        <String>['大米粉', '优质大米'],
        reason: '前缀档若失效，两条都落进「包含」，就会按 code 排成 优质大米 → 大米粉',
      );
    });

    test('输入编码「P0005」：命中面粉（编码优先于名称都不命中）', () {
      expect(_names(rankProductMatches('P0005', shelf)), <String>['面粉']);
    });

    test('输入条码前缀也能命中', () {
      final List<Product> withBarcode = <Product>[
        _p('P0001', '大米', barcode: '6901234567890'),
        _p('P0002', '面粉'),
      ];
      expect(_names(rankProductMatches('6901', withBarcode)), <String>['大米']);
    });
  });

  group('停用商品', () {
    test('普通搜索里不出现', () {
      expect(
        _names(rankProductMatches('大米', shelf)),
        isNot(contains('停用大米')),
        reason: '停用商品混在候选里，用户选中就是「这单卖不出去」',
      );
    });

    test('输入完整名称时仍然给出（否则用户会建一个重名的）', () {
      expect(
        _names(rankProductMatches('停用大米', shelf)),
        <String>['停用大米'],
        reason: '与 findByExactName 一致：它不过滤 is_active',
      );
    });
  });

  group('边界', () {
    test('空输入 / 全空白 ⇒ 不弹候选', () {
      expect(rankProductMatches('', shelf), isEmpty);
      expect(rankProductMatches('   ', shelf), isEmpty);
    });

    test('最多 8 条', () {
      final List<Product> many = <Product>[
        for (int i = 0; i < 20; i++)
          _p('P${i.toString().padLeft(4, '0')}', '大米$i'),
      ];
      expect(rankProductMatches('大米', many).length, 8);
    });

    test('大小写不敏感', () {
      final List<Product> english = <Product>[_p('P0001', 'Coke')];
      expect(_names(rankProductMatches('coke', english)), <String>['Coke']);
    });

    test('前后空白不影响匹配', () {
      expect(_names(rankProductMatches('  大米  ', shelf)).first, '大米');
    });
  });

  group('候选副标题（内容视页面而定）', () {
    test('采购页显示进价', () {
      final Product p = _p('P0002', '面粉', cost: 1800, sell: 2500);
      expect(
        productCandidateSubtitle(p, forPurchase: true),
        'P0002 · 进价 ¥18.00',
      );
    });

    test('销售/送货页显示售价', () {
      final Product p = _p('P0002', '面粉', cost: 1800, sell: 2500);
      expect(
        productCandidateSubtitle(p, forPurchase: false),
        'P0002 · 售价 ¥25.00',
      );
    });

    test('停用商品必须标出来（选中前就要看见）', () {
      final Product p = _p('P0009', '停用大米', active: false);
      expect(
        productCandidateSubtitle(p, forPurchase: false),
        contains('（已停用）'),
      );
    });
  });

  // ------------------------------------------------------------ 防漂移（提案 §六 最后一行）
  //
  // 三个开单页是**同构代码**（纪律 18 的高发区）。补全逻辑若各写一份，迟早漂移。
  // 这条源码级断言钉两件事：三页各只接**一次**共用组件、且 `forPurchase` 传对了
  // （采购看进价、销售/送货看售价 —— 传错不会崩，只会显示错的价格，最难发现）。
  group('三页接线（源码级）', () {
    String read(String relative) =>
        File('lib/src/ui/$relative').readAsStringSync();

    test('三页各接一次 ProductNameAutocomplete（不复制匹配逻辑）', () {
      for (final String page in <String>[
        'sale_page.dart',
        'purchase_page.dart',
        'delivery_page.dart',
      ]) {
        final int count = RegExp(
          r'ProductNameAutocomplete\(',
        ).allMatches(read(page)).length;
        expect(
          count,
          1,
          reason:
              '$page 应恰好接一次共用组件（实际 $count 次）；'
              '多出来的那份就是漂移的开始',
        );
      }
    });

    test('forPurchase 传对：只有采购页是 true', () {
      expect(read('purchase_page.dart'), contains('forPurchase: true'));
      expect(read('sale_page.dart'), contains('forPurchase: false'));
      expect(read('delivery_page.dart'), contains('forPurchase: false'));
    });

    test('三页都接了「回车 ⇒ 立刻建档」，且询问逻辑只有一处', () {
      for (final String page in <String>[
        'sale_page.dart',
        'purchase_page.dart',
        'delivery_page.dart',
      ]) {
        final String src = read(page);
        expect(src, contains('onCreateRequested:'), reason: '$page 没接回车建档');
        expect(src, contains('_offerCreate('), reason: '$page 没有 _offerCreate');
        // 页面只能**调用**，不能自己**定义**询问对话框
        expect(
          src,
          contains('await offerCreateMissingProduct('),
          reason: '$page 应调用共用函数',
        );
        expect(
          src,
          isNot(contains('Future<Product?> offerCreateMissingProduct(')),
          reason: '$page 不该自己写建档询问 —— 那是 `product_name_autocomplete.dart` 的职责',
        );
      }
      expect(
        File('lib/src/ui/product_name_autocomplete.dart')
            .readAsStringSync()
            .contains('Future<Product?> offerCreateMissingProduct('),
        isTrue,
      );
    });

    test('匹配与排序只在组件里定义一次（页面不许自己写 rankProductMatches）', () {
      for (final String page in <String>[
        'sale_page.dart',
        'purchase_page.dart',
        'delivery_page.dart',
      ]) {
        expect(
          read(page),
          isNot(contains('rankProductMatches')),
          reason: '$page 不该自己算候选 —— 那是组件的职责',
        );
      }
    });
  });
}
