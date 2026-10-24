// 草稿文件存储（真实诉求批 ①，2026-10-24，§CV·一百零一）。
//
// 钉四件事：
// ① 往返（写什么读什么）；
// ② **读坏 ⇒ null 且把坏文件删掉**（留着只会每次进页白读一遍）；
// ③ **写失败静默**（目录不可写时开单不能因此报错）；
// ④ 三种草稿互不干扰（按 kind 分文件）。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory box;
  late DraftsStore store;

  setUp(() {
    box = Directory.systemTemp.createTempSync('sz_drafts_');
    store = DraftsStore(dataDirectory: box.path);
  });
  tearDown(() {
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上可能还被占用
    }
  });

  test('往返：写什么读什么', () {
    final Map<String, Object?> json = <String, Object?>{
      'v': 1,
      'kind': 'sale',
      'savedAt': 1761300000000,
      'partyName': '王老板',
      'lines': <Object?>[
        <String, Object?>{'productName': '牛奶', 'quantity': '3'},
      ],
    };
    expect(store.writeSync(DraftKind.sale, json), isTrue);
    expect(store.exists(DraftKind.sale), isTrue);

    final Map<String, Object?>? back = store.read(DraftKind.sale);
    expect(back, isNotNull);
    expect(back!['partyName'], '王老板');
    expect(back['savedAt'], 1761300000000);
    expect((back['lines']! as List<Object?>).length, 1);
  });

  test('没有草稿 ⇒ null（不抛）', () {
    expect(store.read(DraftKind.sale), isNull);
    expect(store.exists(DraftKind.sale), isFalse);
  });

  test('JSON 坏了 ⇒ null，且坏文件被删掉', () {
    final String path = store.pathOf(DraftKind.sale);
    Directory(p.dirname(path)).createSync(recursive: true);
    File(path).writeAsStringSync('{ 这不是 JSON');
    expect(store.exists(DraftKind.sale), isTrue, reason: '前置：文件确实在');

    expect(store.read(DraftKind.sale), isNull);
    expect(File(path).existsSync(), isFalse, reason: '读不了就删 —— 留着只会每次进页白读一遍');
  });

  test('内容不是对象（比如一个数组）⇒ null 且删掉', () {
    final String path = store.pathOf(DraftKind.purchase);
    Directory(p.dirname(path)).createSync(recursive: true);
    File(path).writeAsStringSync('[1,2,3]');
    expect(store.read(DraftKind.purchase), isNull);
    expect(File(path).existsSync(), isFalse);
  });

  test('三种草稿互不干扰', () {
    store.writeSync(DraftKind.sale, <String, Object?>{'kind': 'sale'});
    store.writeSync(DraftKind.purchase, <String, Object?>{'kind': 'purchase'});
    store.writeSync(DraftKind.delivery, <String, Object?>{'kind': 'delivery'});

    expect(store.read(DraftKind.sale)!['kind'], 'sale');
    expect(store.read(DraftKind.purchase)!['kind'], 'purchase');
    expect(store.read(DraftKind.delivery)!['kind'], 'delivery');

    store.delete(DraftKind.purchase);
    expect(store.exists(DraftKind.purchase), isFalse);
    expect(store.exists(DraftKind.sale), isTrue, reason: '删一个不能连带别人');
  });

  test('目录不可写 ⇒ 写失败但**不抛**（开单不能因此报错）', () {
    // 在 `drafts` 该在的位置蹲一个**同名文件** —— createSync(recursive) 会失败
    final String draftsPath = store.directory;
    File(draftsPath).writeAsStringSync('占位');
    addTearDown(() {
      try {
        File(draftsPath).deleteSync();
      } catch (_) {
        // 忽略
      }
    });

    expect(
      () => store.writeSync(DraftKind.sale, <String, Object?>{'kind': 'sale'}),
      returnsNormally,
      reason: '草稿是尽力而为，绝不能因为存不了就让开单失败',
    );
    expect(
      store.writeSync(DraftKind.sale, <String, Object?>{'kind': 'sale'}),
      isFalse,
    );
    expect(store.read(DraftKind.sale), isNull);
  });

  test('写的是 `.tmp` 再改名（中途不留半个 JSON）', () {
    store.writeSync(DraftKind.sale, <String, Object?>{'kind': 'sale'});
    expect(
      File('${store.pathOf(DraftKind.sale)}.tmp').existsSync(),
      isFalse,
      reason: '临时文件必须已经改名成正式文件',
    );
    expect(File(store.pathOf(DraftKind.sale)).existsSync(), isTrue);
  });

  test('delete 不存在的草稿也不抛', () {
    expect(() => store.delete(DraftKind.delivery), returnsNormally);
  });
}
