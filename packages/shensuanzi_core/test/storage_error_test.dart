// 存储失败分类（`storage_error.dart`，M15）的单元测试。
//
// 判据是**结果码**而不是异常文本 —— 所以夹具直接造 `SqliteException`。
// 覆盖：锁 / 满 / 只读 / 损坏 / 打不开 / 非 SQLite / 扩展码回到主码。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

SqliteException ex(int code) => SqliteException(code, 'test');

void main() {
  group('classifyStorageFailure（按结果码，不按文本）', () {
    test('SQLITE_BUSY / SQLITE_LOCKED ⇒ locked', () {
      expect(classifyStorageFailure(ex(5)), StorageFailureKind.locked);
      expect(classifyStorageFailure(ex(6)), StorageFailureKind.locked);
    });

    test('SQLITE_FULL ⇒ full', () {
      expect(classifyStorageFailure(ex(13)), StorageFailureKind.full);
    });

    test('SQLITE_PERM / SQLITE_READONLY ⇒ readOnly', () {
      expect(classifyStorageFailure(ex(3)), StorageFailureKind.readOnly);
      expect(classifyStorageFailure(ex(8)), StorageFailureKind.readOnly);
    });

    test('扩展码回到主码：SQLITE_READONLY_RECOVERY(264) ⇒ readOnly', () {
      expect(classifyStorageFailure(ex(264)), StorageFailureKind.readOnly);
    });

    test('SQLITE_CORRUPT / SQLITE_NOTADB ⇒ corrupted', () {
      expect(classifyStorageFailure(ex(11)), StorageFailureKind.corrupted);
      expect(classifyStorageFailure(ex(26)), StorageFailureKind.corrupted);
    });

    test('SQLITE_CANTOPEN ⇒ unopenable', () {
      expect(classifyStorageFailure(ex(14)), StorageFailureKind.unopenable);
    });

    test('非 SqliteException ⇒ unknown（不抛、不猜）', () {
      expect(
        classifyStorageFailure(StateError('x')),
        StorageFailureKind.unknown,
      );
      expect(classifyStorageFailure('boom'), StorageFailureKind.unknown);
    });
  });

  group('storageFailureNote（给用户的那句话）', () {
    test('不含 SQL / 参数 / 异常类型名 —— 这是 M15 的核心诉求', () {
      final SqliteException real = SqliteException(
        5,
        'while executing INSERT',
        null,
        'INSERT INTO documents (id, total_amount) VALUES (?, ?)',
        <Object?>['d-1', 6000],
      );
      final String note = storageFailureNote(real);
      expect(note, isNot(contains('INSERT')));
      expect(note, isNot(contains('documents')));
      expect(note, isNot(contains('SqliteException')));
      expect(note, isNot(contains('6000')));
    });

    test('已知类别都告诉用户「内容还在」（失败时第一反应是白填了）', () {
      for (final int code in <int>[5, 13, 8, 11, 14]) {
        expect(
          storageFailureNote(ex(code)),
          contains('还在'),
          reason: '结果码 $code 的文案漏了「你填的内容还在」',
        );
      }
    });

    test('只读走「重新打开」而不是「检查内容重试」', () {
      final String note = storageFailureNote(ex(8));
      expect(note, contains('重新打开'));
    });

    test('unknown 指向日志（真实原因只在日志里）', () {
      expect(storageFailureNote(StateError('x')), contains('日志'));
    });
  });
}
