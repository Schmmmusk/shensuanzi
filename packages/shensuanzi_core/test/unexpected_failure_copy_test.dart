// 兜底 catch 的用户文案（`unexpected_failure_copy.dart`，#43② / N-f）的单元测试。
//
// 三条判据，对应 2026-11-05 裁定甲的 ①②③：
//  ① 日志留证据 —— 本文件不管（是调用方的事），但文案**不许**替日志说话；
//  ② 界面不拼异常原文 —— 用**带 payload 的真异常**当夹具（`SqliteException`
//     的 message 带整条 SQL 与绑定参数，正是 #54 要挡的东西）；
//  ③ **没接日志出口就不许说「看日志」** —— `logged` 默认 `false`，
//     所以「认不出来 + logged=false」那档必须**不提**日志。
import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// 带 SQL 与绑定参数的真实形态（照 `storage_error_test.dart` 的夹具写法）。
/// 一旦文案里出现 `SECRET-PAYLOAD` 或 `INSERT INTO` ⇒ 经营内容泄到界面。
SqliteException sqliteWithPayload(int code) => SqliteException(
  code,
  'while executing INSERT',
  null,
  'INSERT INTO documents (id, remark) VALUES (?, ?)',
  <Object?>['d-1', 'SECRET-PAYLOAD 张三欠 800'],
);

/// 逐档扫一遍所有返回值，断言**不含**开发者术语。
/// 判据是「字符串里出现这个词」，不是「我觉得这句话像人话」。
void expectNoDevTerms(String text, {required String where}) {
  for (final term in <String>[
    'Exception',
    'OSError',
    'SqliteException',
    'StateError',
    'SQLITE_',
    'errno',
    'SECRET-PAYLOAD',
    'INSERT',
    r'D:\',
    r'C:\',
  ]) {
    expect(text, isNot(contains(term)), reason: '$where 里漏出了「$term」');
  }
}

void main() {
  group('① 库层：按 SQLite 结果码分档', () {
    test('BUSY / FULL / READONLY / CORRUPT / CANTOPEN 各给不同的一句话', () {
      final texts = <String>{
        unexpectedFailureAdvice(sqliteWithPayload(5)),
        unexpectedFailureAdvice(sqliteWithPayload(13)),
        unexpectedFailureAdvice(sqliteWithPayload(8)),
        unexpectedFailureAdvice(sqliteWithPayload(11)),
        unexpectedFailureAdvice(sqliteWithPayload(14)),
      };
      // 五档撞成一句 = 分支等于没写（同 #24 的判据）。
      expect(texts, hasLength(5));
    });

    test('扩展码回到主码：SQLITE_READONLY_RECOVERY(264) 走只读那档', () {
      expect(
        unexpectedFailureAdvice(sqliteWithPayload(264)),
        unexpectedFailureAdvice(sqliteWithPayload(8)),
      );
    });

    test('⚠️ 不带出 SQL / 绑定参数 / 异常类型（#54 的红线）', () {
      for (final code in <int>[5, 13, 8, 11, 14, 1, 999]) {
        final text = unexpectedFailureAdvice(sqliteWithPayload(code));
        expectNoDevTerms(text, where: 'SQLite 码 $code');
      }
    });
  });

  group('② 文件系统：借用 #35 的 errno 分档', () {
    test('errno 32（被 Excel 占用）⇒ 说「关掉打开它的程序」', () {
      final text = unexpectedFailureAdvice(const OSError('busy', 32));
      expect(text, contains('占用'));
      expect(text, contains('Excel'));
      expectNoDevTerms(text, where: 'errno 32');
    });

    test('errno 112（磁盘满）⇒ 说清空间不够', () {
      expect(
        unexpectedFailureAdvice(const OSError('no space', 112)),
        contains('空间'),
      );
    });

    test('FileSystemException 持有 OSError ⇒ 也认（不是只看 OSError 子类）', () {
      final err = FileSystemException(
        'Failed to open file',
        r'D:\神算子数据\神算子.db',
        const OSError('denied', 5),
      );
      final text = unexpectedFailureAdvice(err);
      expect(text, contains('权限'));
      // 绝对路径是这条异常最容易漏出去的东西。
      expectNoDevTerms(text, where: 'FileSystemException');
    });
  });

  group('③ 「看日志」只在真有日志出口时说', () {
    test('认不出来的异常 + logged=false ⇒ **不许**提日志（默认值就是这个）', () {
      final text = unexpectedFailureAdvice(StateError('配置写不进去'));
      expect(text, isNot(contains('日志')));
      expectNoDevTerms(text, where: 'unknown + logged=false');
    });

    test('认不出来的异常 + logged=true ⇒ 提日志', () {
      expect(
        unexpectedFailureAdvice(StateError('配置写不进去'), logged: true),
        contains('日志'),
      );
    });

    test('认不出来的 OSError ⇒ 也不提日志（`localFileFailureAdvice` 的 '
        'unknown 档自带「把日志发给技术支持」，在无出口的调用点是假话）', () {
      final text = unexpectedFailureAdvice(const OSError('weird', 4321));
      expect(text, isNot(contains('日志')));
    });

    test('SQLite unknown 档同理：logged=false 时不提日志', () {
      final text = unexpectedFailureAdvice(sqliteWithPayload(999));
      expect(text, isNot(contains('日志')));
    });
  });

  group('④ 任何情况下都不拼原文', () {
    test('普通 Exception / StateError / 自定义异常 / 字符串 ⇒ 都不漏内容', () {
      final samples = <Object>[
        Exception('boom-SECRET'),
        StateError('状态不对 boom-SECRET'),
        ArgumentError('参数 boom-SECRET'),
        '裸字符串 boom-SECRET',
        const FileSystemException('没有 osError'),
      ];
      for (final e in samples) {
        final text = unexpectedFailureAdvice(e, logged: true);
        expect(text, isNot(contains('boom-SECRET')), reason: '$e 漏了原文');
        expectNoDevTerms(text, where: '${e.runtimeType}');
      }
    });

  });

  group('⑤ lead：调用方已说结论时不重复', () {
    test('认不出来的异常 + lead ⇒ 不再补「这一步没能完成」', () {
      final text = unexpectedFailureAdvice(
        StateError('x'),
        logged: true,
        lead: '修复没能完成。',
      );
      expect(text, startsWith('修复没能完成。'));
      // 关键判据：不再叠一句同义反复的「这一步没能完成」。
      expect(text, isNot(contains('这一步没能完成')));
    });

    test('认得出的异常 + lead ⇒ lead 拼在分类文案前面', () {
      final text = unexpectedFailureAdvice(
        const OSError('busy', 32),
        lead: '同步时出错。',
      );
      expect(text, startsWith('同步时出错。文件正被另一个程序占用'));
    });

    test('不传 lead ⇒ 行为与之前一致（自带结论）', () {
      expect(
        unexpectedFailureAdvice(StateError('x')),
        startsWith('这一步没能完成。'),
      );
    });
  });

  group('⑥ 兜底文案的完整性', () {
    test('每档都给了非空句子（空文案 = 界面上一个空白条）', () {
      final samples = <Object>[
        sqliteWithPayload(5),
        const OSError('x', 32),
        Exception('x'),
        'x',
      ];
      for (final e in samples) {
        expect(unexpectedFailureAdvice(e).trim(), isNotEmpty);
      }
    });
  });
}