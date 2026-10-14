// 本地文件写入失败（`local_file_error.dart`，`#35`/`#36`）的单元测试。
//
// 判据是 **errno**（`OSError.errorCode`）而不是异常文本 —— 所以夹具直接造
// `FileSystemException`（它 `implements IOException`，OS 码挂在 `osError` 上）。
// 覆盖：占用 / 满 / 只读 / 找不到 / 非 IO / **平台重叠码按平台分叉**。
import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

/// 造一个带 errno 的文件异常（`path` 故意填真路径 —— 用来断言文案**不含**它）。
FileSystemException ex(int code) => FileSystemException(
  '写入失败',
  r'D:\神算子导出\商品_2026-10-14.csv',
  OSError('os message', code),
);

void main() {
  group('classifyLocalFileFailure（按 errno，不按文本）', () {
    test('Windows 32 / 33（共享 / 锁冲突）⇒ busy', () {
      expect(
        classifyLocalFileFailure(ex(32), windows: true),
        LocalFileFailureKind.busy,
      );
      expect(
        classifyLocalFileFailure(ex(33), windows: true),
        LocalFileFailureKind.busy,
      );
    });

    test('POSIX 16（EBUSY）⇒ busy', () {
      expect(
        classifyLocalFileFailure(ex(16), windows: false),
        LocalFileFailureKind.busy,
      );
    });

    test('满：Windows 112 / POSIX 28 ⇒ noSpace', () {
      expect(
        classifyLocalFileFailure(ex(112), windows: true),
        LocalFileFailureKind.noSpace,
      );
      expect(
        classifyLocalFileFailure(ex(28), windows: false),
        LocalFileFailureKind.noSpace,
      );
    });

    test('只读：Windows 5 / POSIX 30 ⇒ readOnly', () {
      expect(
        classifyLocalFileFailure(ex(5), windows: true),
        LocalFileFailureKind.readOnly,
      );
      expect(
        classifyLocalFileFailure(ex(30), windows: false),
        LocalFileFailureKind.readOnly,
      );
    });

    test('找不到：2（文件）/ 3（路径）⇒ notFound', () {
      expect(classifyLocalFileFailure(ex(2)), LocalFileFailureKind.notFound);
      expect(classifyLocalFileFailure(ex(3)), LocalFileFailureKind.notFound);
    });

    test('⚠️ 平台重叠码按平台分叉：13 在 POSIX 是 EACCES、在 Windows 不是', () {
      expect(
        classifyLocalFileFailure(ex(13), windows: false),
        LocalFileFailureKind.readOnly,
        reason: 'POSIX 13 = EACCES',
      );
      expect(
        classifyLocalFileFailure(ex(13), windows: true),
        LocalFileFailureKind.unknown,
        reason: 'Windows 13 = ERROR_INVALID_DATA ⇒ 不能给「检查权限」这种误导建议',
      );
    });

    test('⚠️ 平台重叠码按平台分叉：11 在 POSIX 是 EAGAIN、在 Windows 不是', () {
      expect(
        classifyLocalFileFailure(ex(11), windows: false),
        LocalFileFailureKind.busy,
      );
      expect(
        classifyLocalFileFailure(ex(11), windows: true),
        LocalFileFailureKind.unknown,
      );
    });

    test('非 IO 异常 ⇒ unknown（不抛、不猜）', () {
      expect(
        classifyLocalFileFailure(StateError('x')),
        LocalFileFailureKind.unknown,
      );
      expect(classifyLocalFileFailure('boom'), LocalFileFailureKind.unknown);
    });

    test('FileSystemException 但没有 osError ⇒ unknown', () {
      expect(
        classifyLocalFileFailure(const FileSystemException('x')),
        LocalFileFailureKind.unknown,
      );
    });

    test('裸 OSError 也认', () {
      expect(
        classifyLocalFileFailure(const OSError('os', 32)),
        LocalFileFailureKind.busy,
      );
    });
  });

  group('localFileFailureAdvice（给用户的那句话）', () {
    test('不含路径 / errno 数字 / 异常类型名 —— 这是 #35② 的核心诉求', () {
      final String note = localFileFailureAdvice(ex(32));
      expect(note, isNot(contains('神算子导出')));
      expect(note, isNot(contains('csv')));
      expect(note, isNot(contains('32')));
      expect(note, isNot(contains('FileSystemException')));
      expect(note, isNot(contains('OSError')));
      expect(note, isNot(contains('os message')));
    });

    test('不含动作前缀（前缀由调用方各自拼）', () {
      for (final int code in <int>[32, 112, 5, 2, 999]) {
        expect(localFileFailureAdvice(ex(code)), isNot(contains('导出失败')));
      }
    });

    test('busy ⇒ 指向「关掉那个程序」（这是本次要修的：原来叫人检查磁盘）', () {
      expect(localFileFailureAdvice(ex(32), windows: true), contains('关掉'));
    });

    test('noSpace ⇒ 指向「空间 / 别的盘」', () {
      expect(localFileFailureAdvice(ex(112)), contains('空间'));
    });

    test('readOnly ⇒ 指向「权限 / 位置」', () {
      expect(localFileFailureAdvice(ex(5)), contains('权限'));
    });

    test('notFound ⇒ 指向「找不到 / 检查位置」', () {
      expect(localFileFailureAdvice(ex(2)), contains('找不到'));
    });

    test('unknown 指向日志（真实原因只在日志里）', () {
      expect(localFileFailureAdvice(StateError('x')), contains('日志'));
    });
  });
}
