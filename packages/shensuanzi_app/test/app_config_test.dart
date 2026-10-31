import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  late Directory box;
  late AppConfigStore store;

  setUp(() {
    box = sandbox();
    store = AppConfigStore(File(p.join(box.path, 'config.json')));
  });

  tearDown(() {
    if (box.existsSync()) box.deleteSync(recursive: true);
  });

  // ============================================================ 位置
  group('配置文件的位置', () {
    test('%APPDATA%\\神算子\\config.json', () {
      final AppConfigStore real = AppConfigStore.forEnvironment(machine());
      expect(
        real.file.path,
        p.join(r'C:\Users\tester\AppData\Roaming', '神算子', 'config.json'),
      );
    });

    test('%APPDATA% 拿不到 → 退回用户目录，不崩', () {
      final AppConfigStore fallback = AppConfigStore.forEnvironment(
        machine(environment: <String, String>{}),
      );
      expect(
        fallback.file.path,
        p.join(r'C:\Users\tester', '.shensuanzi', '神算子', 'config.json'),
      );
    });

    test('配置是「设备偏好」，不和数据放一起', () {
      // 配置被清理软件删掉只丢偏好，经营数据一行都不会少
      expect(store.file.path, isNot(contains('神算子数据')));
    });
  });

  // ============================================================ 默认值
  group('默认配置', () {
    test('文件不存在 → 全默认，dataDirectory = null（→ 走向导）', () {
      final AppConfig config = store.load();
      expect(config.dataDirectory, isNull);
      expect(config.shopName, isNull);
      expect(config.uiScale, UiScale.standard);
    });

    test('默认缩放是 125%', () {
      expect(UiScale.defaultScale.factor, 1.25);
      expect(UiScale.defaultScale.label, '标准');
    });
  });

  // ============================================================ 往返
  group('读写往返', () {
    test('存了再读，字段一致', () {
      const AppConfig config = AppConfig(
        dataDirectory: r'D:\神算子数据',
        uiScale: UiScale.large,
        shopName: '张记五金',
      );
      store.save(config);

      final AppConfig back = store.load();
      expect(back.dataDirectory, r'D:\神算子数据');
      expect(back.uiScale, UiScale.large);
      expect(back.shopName, '张记五金');
    });

    test('JSON 键名是 snake_case，缩放存的是数值', () {
      store.save(
        const AppConfig(dataDirectory: r'D:\数据', uiScale: UiScale.huge),
      );
      final Map<String, Object?> json = Map<String, Object?>.from(
        jsonDecode(store.file.readAsStringSync()) as Map,
      );

      expect(json.keys.toSet(), <String>{
        'data_directory',
        'ui_scale',
        'shop_name',
      });
      expect(json['ui_scale'], 1.75);
    });

    test('save 会自动建父目录', () {
      final AppConfigStore deep = AppConfigStore(
        File(p.join(box.path, 'a', 'b', 'c', 'config.json')),
      );
      deep.save(const AppConfig(dataDirectory: r'D:\数据'));
      expect(deep.load().dataDirectory, r'D:\数据');
    });

    test('clear 之后回到默认', () {
      store.save(const AppConfig(dataDirectory: r'D:\数据'));
      store.clear();
      expect(store.load().dataDirectory, isNull);
      expect(store.file.existsSync(), isFalse);
    });

    test('clear 一个本来就不存在的文件 → 不抛', () {
      expect(store.clear, returnsNormally);
    });
  });

  // ============================================================ 容错
  // 2026-10-22（用户实测）：选「大」后界面不变，报
  // `Cannot open file ... config.json (OS Error: 拒绝访问。, errno = 5)`。
  // 根因是**瞬时锁**（杀毒软件实时扫描正在写的文件）—— ACL 与只读属性
  // 都是好的。⇒ save 必须重试，不能一失败就放弃。
  group('save() 的瞬时锁重试', () {
    test('写一直失败 ⇒ 重试 3 次后才把异常抛给上层', () {
      final Directory blocker = Directory(p.join(box.path, 'config.json'));
      blocker.createSync();
      addTearDown(() {
        try {
          blocker.deleteSync();
        } catch (_) {}
      });

      final List<Duration> waits = <Duration>[];
      final AppConfigStore store = AppConfigStore(
        File(p.join(box.path, 'config.json')),
        sleep: waits.add,
      );

      expect(() => store.save(const AppConfig()), throwsA(anything));
      expect(
        waits.length,
        3,
        reason: '共 4 次尝试：失败后睡 30/60/90ms，再失败才抛（总 180ms，别卡界面）',
      );
      expect(waits.first.inMilliseconds, 30);
      expect(waits.last.inMilliseconds, 90);
    });

    test('主位置写不进去 ⇒ 落到备用位置（设置不能永远存不上）', () {
      // 主位置占成目录 ⇒ 永远写不进去（模拟用户机器上的 errno 5）
      final Directory blocked = Directory(p.join(box.path, 'config.json'));
      blocked.createSync();
      addTearDown(() {
        try {
          blocked.deleteSync();
        } catch (_) {}
      });

      final File backup = File(p.join(box.path, 'local', 'config.json'));
      final AppConfigStore store = AppConfigStore(
        File(p.join(box.path, 'config.json')),
        fallbackFile: backup,
        sleep: (Duration _) {},
      );

      store.save(const AppConfig(uiScale: UiScale.giant));

      expect(backup.existsSync(), isTrue, reason: '必须落到备用位置');
      expect(store.load().uiScale, UiScale.giant, reason: '读也要认备用位置');
    });

    test('主位置与备用位置都写不进 ⇒ 落到**数据目录**（真机 2026-10-23）', () {
      // 真机现象：%APPDATA% 和 %LOCALAPPDATA% 都建不了文件，但数据目录能开库
      final Directory blocked = Directory(p.join(box.path, 'config.json'));
      blocked.createSync();
      addTearDown(() {
        try {
          blocked.deleteSync();
        } catch (_) {}
      });

      final String dataDir = p.join(box.path, 'data');
      Directory(dataDir).createSync(recursive: true);

      final AppConfigStore store = AppConfigStore(
        File(p.join(box.path, 'config.json')),
        sleep: (Duration _) {},
      )..useDataDirectoryFallback(dataDir);

      store.save(const AppConfig(uiScale: UiScale.giant));

      final File inData = File(p.join(dataDir, dataDirConfigFileName));
      expect(inData.existsSync(), isTrue, reason: '必须落到数据目录');
      expect(store.load().uiScale, UiScale.giant, reason: '读也要认它');
    });

    test('一直失败 ⇒ 把异常抛给上层（设置页靠它回滚并告知）', () {
      // 把 config.json 占成**目录** ⇒ 写永远失败
      final Directory blocker = Directory(p.join(box.path, 'config.json'));
      blocker.createSync();
      addTearDown(() {
        try {
          blocker.deleteSync();
        } catch (_) {}
      });

      final AppConfigStore store = AppConfigStore(
        File(p.join(box.path, 'config.json')),
        sleep: (Duration _) {}, // 别真睡（测试要快）
      );

      expect(() => store.save(const AppConfig()), throwsA(anything));
    });
  });

  group('配置是外部输入 → 读永不抛', () {
    test('JSON 语法坏了 → 默认值，不抛', () {
      store.file.writeAsStringSync('{ 这不是 json');
      expect(store.load().dataDirectory, isNull);
    });

    test('顶层不是对象 → 默认值', () {
      store.file.writeAsStringSync('[1, 2, 3]');
      expect(store.load().dataDirectory, isNull);
    });

    test('data_directory 类型不对 / 是空白 → 当作没配', () {
      store.file.writeAsStringSync(
        jsonEncode(<String, Object?>{'data_directory': 42}),
      );
      expect(store.load().dataDirectory, isNull);

      store.file.writeAsStringSync(
        jsonEncode(<String, Object?>{'data_directory': '   '}),
      );
      expect(store.load().dataDirectory, isNull);
    });

    test('未知缩放值 → 退回 125%，不抛', () {
      store.file.writeAsStringSync(
        jsonEncode(<String, Object?>{'ui_scale': 1.3}),
      );
      expect(store.load().uiScale, UiScale.standard);

      store.file.writeAsStringSync(
        jsonEncode(<String, Object?>{'ui_scale': '大'}),
      );
      expect(store.load().uiScale, UiScale.standard);
    });

    test('多出来的未知键被忽略', () {
      store.file.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'data_directory': r'D:\数据',
          'something_else': true,
        }),
      );
      expect(store.load().dataDirectory, r'D:\数据');
    });
  });

  // ============================================================ copyWith
  group('AppConfig.copyWith', () {
    test('只改一个字段，其它保持', () {
      const AppConfig base = AppConfig(
        dataDirectory: r'D:\数据',
        uiScale: UiScale.large,
        shopName: '店',
      );
      final AppConfig changed = base.copyWith(uiScale: UiScale.small);
      expect(changed.dataDirectory, r'D:\数据');
      expect(changed.shopName, '店');
      expect(changed.uiScale, UiScale.small);
    });

    test('clearShopName 能真的清掉店名（`null` 无法通过 copyWith 表达）', () {
      const AppConfig base = AppConfig(shopName: '店');
      expect(base.copyWith(clearShopName: true).shopName, isNull);
      expect(base.copyWith().shopName, '店', reason: '不传就是不改');
    });
  });

  // ============================================================ 缩放档位
  // 批 3 第 15 条：系统字号与应用档位**取较大值**（不乘）。
  group('effectiveTextScale', () {
    test('应用档位更大 ⇒ 用应用档位', () {
      expect(effectiveTextScale(system: 1.0, app: 2.0), 2.0);
      expect(effectiveTextScale(system: 1.3, app: 1.75), 1.75);
    });

    test('系统字号更大 ⇒ 跟着系统', () {
      expect(effectiveTextScale(system: 1.3, app: 1.25), 1.3);
      expect(effectiveTextScale(system: 2.0, app: 1.0), 2.0);
    });

    test('相等 / 两边都标准', () {
      expect(effectiveTextScale(system: 1.25, app: 1.25), 1.25);
      expect(effectiveTextScale(system: 1.0, app: 1.0), 1.0);
    });

    test('**永远不叠加**：最坏组合也不超过应用最大档', () {
      // 相乘会是 2.6 —— 界面必崩；取大值封在 2.0
      expect(effectiveTextScale(system: 1.3, app: 2.0), 2.0);
      expect(
        effectiveTextScale(system: 3.0, app: 2.0),
        3.0,
        reason: '系统比应用上限还大时，尊重系统（应用不该压小用户的选择）',
      );
    });
  });

  group('UiScale', () {
    test('五档，数值取自 reply.md', () {
      expect(UiScale.values.map((UiScale s) => s.factor), <double>[
        1.0,
        1.25,
        1.5,
        1.75,
        2.0,
      ]);
    });

    test('fromFactor 容差匹配（1.2499999 也算 1.25）', () {
      expect(UiScale.fromFactor(1.2499999), UiScale.standard);
      expect(UiScale.fromFactor(1.3), isNull);
      expect(UiScale.fromFactor(null), isNull);
    });
  });
  // ============================================================ §审查 OBS-15
  //
  // 「配置损坏」不能当成「第一次启动」——那是撒谎，还会让用户在慌乱里
  // 把原来那个完好的数据目录丢在一边。

  group('配置读取状态（§审查 OBS-15）', () {
    late Directory cfgBox;
    late File cfgFile;
    late AppConfigStore cfgStore;

    setUp(() {
      cfgBox = Directory.systemTemp.createTempSync('shensuanzi_cfg_status_');
      cfgFile = File(p.join(cfgBox.path, 'config.json'));
      cfgStore = AppConfigStore(cfgFile);
    });

    tearDown(() {
      try {
        cfgBox.deleteSync(recursive: true);
      } catch (_) {
        // 删不掉不影响结论
      }
    });

    test('文件不存在 ⇒ absent（**只有这一种**才是真·第一次启动）', () {
      expect(cfgStore.status(), AppConfigLoadStatus.absent);
      expect(cfgStore.salvageDataDirectory(), isNull, reason: '没东西可抢救');
    });

    test('正常配置 ⇒ ok', () {
      cfgStore.save(const AppConfig(dataDirectory: r'D:/数据'));
      expect(cfgStore.status(), AppConfigLoadStatus.ok);
      expect(cfgStore.load().dataDirectory, r'D:/数据');
    });

    test('JSON 截断（写到一半断电）⇒ locationLost，且能从原文**抢救**出路径', () {
      // 真·Windows 形态（一个反斜杠）；用 jsonEncode 生成**合法**的 JSON
      // 字符串字面量（`"D://fed"`）再手工截断 —— 这样测的正是
      // 「半截 JSON 里那段路径还能不能正确反转义回来」，不靠手写转义。
      const String original = r'D:/fed';
      final String literal = jsonEncode(original);
      cfgFile.writeAsStringSync('{\n  "data_directory": $literal,\n  "ui_sca');

      expect(
        cfgStore.status(),
        AppConfigLoadStatus.locationLost,
        reason: '文件在、位置读不出来 ⇒ 不是 absent',
      );
      expect(cfgStore.load().dataDirectory, isNull, reason: 'load 退化成默认，不崩');
      expect(cfgStore.salvageDataDirectory(), original, reason: '反斜杠必须正确反转义');
    });

    test('JSON 完整、但**没有位置字段** ⇒ 同样算 locationLost', () {
      cfgFile.writeAsStringSync('{"ui_scale": 1.25}');
      expect(cfgStore.status(), AppConfigLoadStatus.locationLost);
      expect(cfgStore.salvageDataDirectory(), isNull);
    });

    test('坏得没救的文本 ⇒ 抢救返回 null（坏片段不当数据用）', () {
      cfgFile.writeAsStringSync('{ 根本不是 JSON');
      expect(cfgStore.status(), AppConfigLoadStatus.locationLost);
      expect(cfgStore.salvageDataDirectory(), isNull);
    });

    test('留档：另存 .corrupt、**不删原件**、已存在就不覆盖', () {
      const String first = '{"data_directory": "坏了的第一版"';
      cfgFile.writeAsStringSync(first);
      cfgStore.preserveCorruptCopy();

      final File copy = File('${cfgFile.path}.corrupt');
      expect(copy.existsSync(), isTrue);
      expect(copy.readAsStringSync(), first);
      expect(cfgFile.existsSync(), isTrue, reason: '只是读不懂，不是垃圾 —— 不许删');

      // 再坏一次：**第一份**最有诊断价值，不覆盖
      cfgFile.writeAsStringSync('第二版更烂');
      cfgStore.preserveCorruptCopy();
      expect(copy.readAsStringSync(), first);
    });
  });

  group('月度对比格式（2026-10-31 真机）', () {
    test('默认是**倍数**；关掉时**不写进 JSON**（老配置零变化）', () {
      const AppConfig config = AppConfig(dataDirectory: r'D:/数据');
      expect(config.monthComparePercent, isFalse);
      expect(config.toJson().containsKey('month_compare_percent'), isFalse);
    });

    test('开启后能存能读', () {
      const AppConfig config = AppConfig(
        dataDirectory: r'D:/数据',
        monthComparePercent: true,
      );
      expect(config.toJson()['month_compare_percent'], isTrue);
      expect(AppConfig.fromJson(config.toJson()).monthComparePercent, isTrue);
    });

    test('字段缺失 / 类型不对 ⇒ 退回倍数（容错解析不抛）', () {
      expect(
        AppConfig.fromJson(<String, Object?>{
          'data_directory': r'D:/数据',
        }).monthComparePercent,
        isFalse,
      );
      expect(
        AppConfig.fromJson(<String, Object?>{
          'data_directory': r'D:/数据',
          'month_compare_percent': 'yes', // 字符串不是布尔
        }).monthComparePercent,
        isFalse,
      );
    });
  });
}
