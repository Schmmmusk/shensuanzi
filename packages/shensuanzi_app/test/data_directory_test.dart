import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final DataDirectoryPolicy policy = DataDirectoryPolicy(machine());

  // ============================================================ 默认位置
  group('默认数据目录', () {
    test('有非系统盘 → 优先非系统盘（重装系统不丢数据）', () {
      expect(
        DataDirectoryPolicy(machine()).defaultDataDirectory(),
        r'D:\神算子数据',
      );
    });

    test('只有系统盘 → 退回用户目录下', () {
      expect(
        DataDirectoryPolicy(systemDriveOnly()).defaultDataDirectory(),
        r'C:\Users\tester\神算子数据',
      );
    });

    test('非系统盘只有 U 盘 → 不用它，退回用户目录（拔盘就没了）', () {
      final DataDirectoryPolicy p = DataDirectoryPolicy(
        machine(drives: <DriveInfo>[cDrive, eUsb]),
      );
      expect(p.defaultDataDirectory(), r'C:\Users\tester\神算子数据');
    });

    test('非系统盘只有网络盘 → 不用它', () {
      final DataDirectoryPolicy p = DataDirectoryPolicy(
        machine(drives: <DriveInfo>[cDrive, zNetwork]),
      );
      expect(p.defaultDataDirectory(), r'C:\Users\tester\神算子数据');
    });

    test('非系统盘剩余空间不足 → 不用它', () {
      final DataDirectoryPolicy p = DataDirectoryPolicy(
        machine(drives: <DriveInfo>[cDrive, fTight]),
      );
      expect(p.defaultDataDirectory(), r'C:\Users\tester\神算子数据');
    });

    test('固定盘优先于 U 盘（D 固定 + E 可移动 → 选 D）', () {
      final DataDirectoryPolicy p = DataDirectoryPolicy(
        machine(drives: <DriveInfo>[cDrive, eUsb, dDrive]),
      );
      expect(p.defaultDataDirectory(), r'D:\神算子数据');
    });

    test('连 HOME 都拿不到 → 兜底到系统盘', () {
      final DataDirectoryPolicy p = DataDirectoryPolicy(
        machine(home: '', drives: <DriveInfo>[cDrive]),
      );
      expect(p.defaultDataDirectory(), r'C:\神算子数据');
    });
  });

  // ============================================================ 硬拒绝
  group('校验 · 拒绝', () {
    DirectoryAdvice inspect(String path) => policy.inspect(path);

    test('空路径 → 拒绝，并说「怎么办」', () {
      final DirectoryAdvice advice = inspect('   ');
      expect(advice.verdict, DirectoryVerdict.reject);
      expect(advice.isUsable, isFalse);
      expect(advice.advice, isNotNull, reason: '错误信息必须带「怎么办」');
    });

    test('相对路径 → 拒绝', () {
      expect(inspect(r'神算子数据').verdict, DirectoryVerdict.reject);
      expect(inspect(r'..\数据').verdict, DirectoryVerdict.reject);
    });

    test('系统盘根目录 → 拒绝', () {
      final DirectoryAdvice advice = inspect(r'C:\');
      expect(advice.verdict, DirectoryVerdict.reject);
      expect(advice.reason, contains('根目录'));
    });

    test('C:\\Windows → 拒绝（含任意子路径）', () {
      expect(inspect(r'C:\Windows').verdict, DirectoryVerdict.reject);
      expect(inspect(r'C:\Windows\System32').verdict, DirectoryVerdict.reject);
      expect(inspect(r'c:\windows\system32').verdict, DirectoryVerdict.reject,
          reason: 'Windows 路径大小写不敏感');
    });

    test('C:\\Program Files（含 x86）→ 拒绝', () {
      expect(inspect(r'C:\Program Files').verdict, DirectoryVerdict.reject);
      expect(inspect(r'C:\Program Files\神算子').verdict, DirectoryVerdict.reject);
      expect(
        inspect(r'C:\Program Files (x86)\神算子').verdict,
        DirectoryVerdict.reject,
      );
    });

    test('名字里带 Windows 但不是系统目录 → 放行', () {
      // 目录名以 `Windows` 开头就误判的话，这个用例会挂
      expect(inspect(r'D:\Windows备份').verdict, DirectoryVerdict.ok);
      expect(inspect(r'D:\Program Files 备份').verdict, DirectoryVerdict.ok);
    });
  });

  // ============================================================ 警告
  group('校验 · 警告（能用但有代价）', () {
    DirectoryAdvice inspect(String path) => policy.inspect(path);

    test('%LOCALAPPDATA% 下 → 警告（清理软件会扫这里）', () {
      final DirectoryAdvice advice = inspect(r'C:\Users\tester\AppData\Local\神算子');
      expect(advice.verdict, DirectoryVerdict.warn);
      expect(advice.isUsable, isTrue, reason: '警告不拦人');
      expect(advice.reason, contains('%LOCALAPPDATA%'));
    });

    test('%APPDATA% 下 → 警告', () {
      expect(
        inspect(r'C:\Users\tester\AppData\Roaming\神算子').verdict,
        DirectoryVerdict.warn,
      );
    });

    test('%TEMP% 下 → 警告', () {
      expect(
        inspect(r'C:\Users\tester\AppData\Local\Temp\神算子').verdict,
        DirectoryVerdict.warn,
      );
    });

    test('OneDrive 目录下 → 警告（SQLite 在同步盘上会被写坏）', () {
      final DirectoryAdvice advice = inspect(r'C:\Users\tester\OneDrive\神算子');
      expect(advice.verdict, DirectoryVerdict.warn);
      expect(advice.reason, contains('同步'));
    });

    test('第三方网盘关键字（坚果云 / Dropbox / 百度网盘）→ 警告', () {
      expect(inspect(r'D:\坚果云\神算子').verdict, DirectoryVerdict.warn);
      expect(inspect(r'D:\Dropbox\神算子').verdict, DirectoryVerdict.warn);
      expect(inspect(r'D:\百度网盘\神算子').verdict, DirectoryVerdict.warn);
    });

    test('U 盘 → 警告（拔掉就打不开）', () {
      final DirectoryAdvice advice = DataDirectoryPolicy(
        machine(drives: <DriveInfo>[cDrive, eUsb]),
      ).inspect(r'E:\神算子数据');
      expect(advice.verdict, DirectoryVerdict.warn);
      expect(advice.reason, contains('可移动'));
    });

    test('网络盘 → 警告', () {
      final DirectoryAdvice advice = DataDirectoryPolicy(
        machine(drives: <DriveInfo>[cDrive, zNetwork]),
      ).inspect(r'Z:\神算子数据');
      expect(advice.verdict, DirectoryVerdict.warn);
      expect(advice.reason, contains('网络'));
    });

    test('剩余空间不足 → 警告，且报具体值', () {
      final DirectoryAdvice advice = DataDirectoryPolicy(
        machine(drives: <DriveInfo>[cDrive, fTight]),
      ).inspect(r'F:\神算子数据');
      expect(advice.verdict, DirectoryVerdict.warn);
      expect(advice.reason, contains('50.0 MB'));
    });

    test('非系统盘根目录 → 警告（不好认、不好迁移）', () {
      final DirectoryAdvice advice = inspect(r'D:\');
      expect(advice.verdict, DirectoryVerdict.warn);
      expect(advice.reason, contains('根目录'));
      expect(advice.advice, contains('神算子数据'));
    });

    test('盘类型未知（拿不到信息）→ 不因此拦人', () {
      // 纯 Dart 探测只能得到 unknown；unknown 既不是 removable 也不是 network
      final DataDirectoryPolicy p = DataDirectoryPolicy(
        machine(drives: <DriveInfo>[cDrive, const DriveInfo(root: r'D:\')]),
      );
      expect(p.inspect(r'D:\神算子数据').verdict, DirectoryVerdict.ok);
    });
  });

  // ============================================================ 放行
  group('校验 · 放行', () {
    test('D:\\神算子数据 → 没问题', () {
      final DirectoryAdvice advice = policy.inspect(r'D:\神算子数据');
      expect(advice.verdict, DirectoryVerdict.ok);
      expect(advice.isWarning, isFalse);
    });

    test('用户自己起的名字也放行', () {
      expect(policy.inspect(r'D:\我的账本').verdict, DirectoryVerdict.ok);
      expect(policy.inspect(r'D:\a\b\c\d').verdict, DirectoryVerdict.ok);
    });
  });

  // ============================================================ 迁移
  group('迁移校验（新位置不能和旧位置互相嵌套）', () {
    test('新位置在旧位置里面 → 拒绝', () {
      final DirectoryAdvice advice = policy.inspectMigration(
        r'D:\数据',
        r'D:\数据\子目录',
      );
      expect(advice.verdict, DirectoryVerdict.reject);
      expect(advice.reason, contains('新位置在旧位置里面'));
    });

    test('旧位置在新位置里面 → 拒绝', () {
      final DirectoryAdvice advice = policy.inspectMigration(
        r'D:\数据\子目录',
        r'D:\数据',
      );
      expect(advice.verdict, DirectoryVerdict.reject);
      expect(advice.reason, contains('旧位置在新位置里面'));
    });

    test('并列的两个目录 → 放行', () {
      expect(
        policy.inspectMigration(r'D:\数据', r'D:\数据2').verdict,
        DirectoryVerdict.ok,
      );
    });

    test('目标本身非法（如 C:\\）→ 直接返回该结论', () {
      final DirectoryAdvice advice = policy.inspectMigration(r'D:\数据', r'C:\');
      expect(advice.verdict, DirectoryVerdict.reject);
      expect(advice.reason, contains('根目录'));
    });

    test('盘根作容器：新位置在旧位置（盘根）里面 → 拒绝', () {
      // ⚠️ 这条曾因 `isNested` 对盘根失效而**静默放行**
      expect(policy.isNested(r'C:\Users\x', r'C:\'), isTrue);
      final DirectoryAdvice advice = policy.inspectMigration(r'D:\', r'D:\数据');
      expect(advice.verdict, DirectoryVerdict.reject);
    });
  });

  // ============================================================ 备份位置
  group('备份目录是数据目录的兄弟目录', () {
    test('D:\\神算子数据 → D:\\神算子备份', () {
      expect(policy.backupDirectoryFor(r'D:\神算子数据'), r'D:\神算子备份');
    });

    test('深层目录也一样', () {
      expect(
        policy.backupDirectoryFor(r'D:\a\b\神算子数据'),
        r'D:\a\b\神算子备份',
      );
    });

    test('数据目录自己就叫「神算子备份」→ 备份让位，不和自己重合', () {
      final String backup = policy.backupDirectoryFor(r'D:\神算子备份');
      expect(backup, r'D:\神算子备份-1');
      expect(backup, isNot(r'D:\神算子备份'), reason: '重合会把数据搬进自己的备份里');
    });

    test('容量提示：拿不到剩余空间就不编一个值', () {
      expect(policy.spaceHint(r'D:\神算子数据'), 'D 盘剩余 128.0 GB');
      expect(DataDirectoryPolicy(machine(drives: <DriveInfo>[]))
          .spaceHint(r'D:\神算子数据'), isNull);
    });

    test('容量提示：有卷标就带上（§BK·二：用户认得出是哪块盘）', () {
      final DataDirectoryPolicy withLabel = DataDirectoryPolicy(
        machine(drives: <DriveInfo>[
          const DriveInfo(
            root: r'E:\',
            kind: DriveKind.fixed,
            freeBytes: 128 * gb,
            volumeLabel: '仓库',
          ),
        ]),
      );
      expect(withLabel.spaceHint(r'E:\神算子数据'), 'E 盘「仓库」剩余 128.0 GB');
    });
  });

  // ============================================================ 工具函数
  group('formatBytes', () {
    test('按量级选单位', () {
      expect(formatBytes(512), '512 字节');
      expect(formatBytes(2048), '2.0 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatBytes(128 * gb), '128.0 GB');
    });

    test('未知 → 显示「未知」，不显示 0', () {
      expect(formatBytes(null), '未知');
    });
  });
}
