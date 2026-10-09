// 主机端同步失败的可读原因（`docs/reply_review.md` §CS·五 裁定 ③，2026-10-08）。
//
// 覆盖两件事：
// ① 约束冲突按**结果码**细分（UNIQUE / FK / CHECK+NOT NULL），不是按异常文本；
// ② 给客户端的**一句话里绝不出现** SQL、绑定参数、表名、异常类型名
//    —— 这是 M15 同一条诉求的同步版（原文「原始 SqliteException 只进日志」）。
//
// ⚠️ `SqliteException` 的第一个位置参数是 **extendedResultCode**（不是 resultCode）。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/dev_terms.dart';

/// 按扩展结果码造异常
SqliteException ex(int extendedCode, [String message = 'test']) =>
    SqliteException(extendedCode, message);

void main() {
  group('constraintKindOf（按结果码，不按文本）', () {
    test('UNIQUE / PRIMARY KEY ⇒ duplicate', () {
      expect(constraintKindOf(ex(2067)), ConstraintKind.duplicate); // UNIQUE
      expect(constraintKindOf(ex(1555)), ConstraintKind.duplicate); // PK
    });

    test('FOREIGN KEY ⇒ missingReference', () {
      expect(constraintKindOf(ex(787)), ConstraintKind.missingReference);
    });

    test('CHECK / NOT NULL ⇒ invalid', () {
      expect(constraintKindOf(ex(275)), ConstraintKind.invalid);
      expect(constraintKindOf(ex(1299)), ConstraintKind.invalid);
    });

    test('主码是 19 但扩展码不认识 ⇒ 兜底 invalid（宁可笼统，也不漏报）', () {
      expect(constraintKindOf(ex(19)), ConstraintKind.invalid);
      expect(constraintKindOf(ex(19 | 0x100)), ConstraintKind.invalid);
    });

    test('不是约束冲突 ⇒ null（存储故障交给 M15 的分类）', () {
      expect(constraintKindOf(ex(5)), isNull); // SQLITE_BUSY
      expect(constraintKindOf(StateError('x')), isNull);
      expect(constraintKindOf('字符串'), isNull);
    });
  });

  group('syncFailureReason（给客户端的那句话）', () {
    test('三类约束冲突各给一句中文', () {
      expect(
        syncFailureReason(ex(2067)),
        contains('唯一字段重复'),
      );
      expect(
        syncFailureReason(ex(787)),
        contains('引用的对象在主机上不存在'),
      );
      expect(
        syncFailureReason(ex(1299)),
        contains('不完整或不合法'),
      );
    });

    test('存储类故障复用 M15 的分类（措辞面向「主机侧」）', () {
      expect(syncFailureReason(ex(5)), contains('主机正忙')); // BUSY
      expect(syncFailureReason(ex(13)), contains('磁盘空间')); // FULL
      expect(syncFailureReason(ex(8)), contains('不能写入')); // READONLY
      expect(syncFailureReason(ex(26)), contains('损坏')); // NOTADB
    });

    test('搞不清的错 ⇒ 让用户交日志，而不是把异常倒给他', () {
      final String reason = syncFailureReason(StateError('内部状态不对'));
      expect(reason, contains('日志'));
      expect(reason, isNot(contains('StateError')));
      expect(reason, isNot(contains('内部状态不对')));
    });

    test('**绝不泄露 SQL / 参数 / 表名 / 类型名**（M15 同一条诉求）', () {
      // 真实形态：SqliteException(2067, 'UNIQUE constraint failed: products.code',
      //   <explanation>, 'INSERT INTO products (id, code) VALUES (?, ?)',
      //   <Object?>['p-1', 'P001'])
      final SqliteException real = SqliteException(
        2067,
        'UNIQUE constraint failed: products.code',
        null,
        'INSERT INTO products (id, code) VALUES (?, ?)',
        <Object?>['p-1', 'P001'],
      );

      final String reason = syncFailureReason(real);
      // **通用**术语（含 SQL / 异常口径）走**共用表**（core 的
      // `forbiddenDevTermsInUserText`）；模块特有的样例 —— 表名 / 样例数据 /
      // 绑定参数占位符 —— 作为 `extra` 留在本模块（§CV·十三·二）。
      expectNoDevTerms(
        reason,
        extra: <String>['p-1', 'P001', '?', 'products'],
      );
    });

    test('每一类都非空且是完整句子（含句号）', () {
      for (final Object error in <Object>[
        ex(2067),
        ex(787),
        ex(1299),
        ex(5),
        ex(13),
        ex(8),
        ex(11),
        ex(14),
        StateError('x'),
      ]) {
        final String reason = syncFailureReason(error);
        expect(reason.trim(), isNotEmpty, reason: '$error');
        expect(reason, endsWith('。'), reason: '$error');
      }
    });
  });

  group('malformedSyncRequestReason（协议违反的通用回执，§CV·十五）', () {
    test('本身也守「用户可见文本」的规矩：无开发术语 + 说了「怎么办」', () {
      expectNoDevTerms(malformedSyncRequestReason);
      expect(
        malformedSyncRequestReason,
        contains('重试'),
        reason: '只讲「怎么办」—— 这些错误用户修不了，说清「哪里错了」没用',
      );
    });
  });
}
