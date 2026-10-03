// 导入守卫的**自检**：`dart run tool/selfcheck_import_guard.dart`
//
// ## 为什么需要它
//
// 守卫的输出只有一句话：「N 处缺导入」。于是有两种情况**长得一模一样**：
//
// - 「代码真缺导入」→ 该报 ✅
// - 「守卫自己改坏了（比如去噪退化成整段正则、路径解析写错）」→ 误报/漏报 ❌
//
// 光看那行输出分不出来。本脚本用一个**临时迷你仓库**把两者分开：
// 造出「该报的」与「不该报的」两种文件，断言守卫**报的正好是那几条**。
//
// ## 覆盖的判定面
//
// | 编号 | 断言 |
// |---|---|
// | A | 正例：`import 'b.dart'` + 用 `B` ⇒ 0 |
// | B | **反例②**：用 `B` 但没 import ⇒ 1（§AZ 那次的真身） |
// | C | 假 import（**注释**版）骗不过 ⇒ 仍 1 |
// | D | 假 import（**字符串**版）骗不过 ⇒ 仍 1 |
// | E | **私有名跳过**：别的文件 `class _C` 不算数 ⇒ 0 |
// | F | **路径解析**：`sub/a.dart` 里 `import '../b.dart'` ⇒ 0 |
// | G | **路径解析**（反）：`sub/a.dart` 里 `import 'b.dart'` 指向 `sub/b.dart` ⇒ 仍 1 |
// | H | `package:shensuanzi/...` 映射回 `lib/...` ⇒ 0 |
// | I | **反例①**：用桶导出名 `Zed` 却没 import 桶 ⇒ 1 |
// | J | 正例①：import 了桶 ⇒ 0 |
// | K | `as` 前缀**不误报**（v1 声明不支持，但也不能报） ⇒ 0 |
// | L | **已知边界**：顶层函数引用**不查** ⇒ 0（诚实记录，不是"通过"） |
//
// 退出码：全部通过为 0，否则为 1。**不使用随机数据**。

import 'dart:io';

import 'import_guard.dart';

int _passed = 0;
final List<String> _failures = <String>[];

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  ✓ $name');
  } else {
    _failures.add(name);
    stdout.writeln('  ✗ $name${detail == null ? '' : '  → $detail'}');
  }
}

void section(String title) => stdout.writeln('\n[$title]');

/// 桶导出名（自检固定用它 —— `Zed` **刻意不在任何扫描文件里声明**，
/// 于是「缺桶导入」与「缺同胞导入」两类检查在用例里互不干扰）。
const Map<String, String> _barrelFiles = <String, String>{
  'demo': 'lib/barrel.dart',
};

const List<String> _roots = <String>['lib'];

void main() {
  stdout.writeln('导入守卫自检：`dart run tool/selfcheck_import_guard.dart`');
  stdout.writeln('（造临时迷你仓库，断言守卫「该报的报、不该报的不报」）');

  section('A 正例：同胞导入');
  _expect1('import 了 b.dart + 用 B ⇒ 0 处', (Directory root) {
    _write(root, 'lib/b.dart', 'class B {}\n');
    _write(root, 'lib/a.dart', '''
import 'b.dart';

class A {
  B? b;
}
''');
  }, 0);

  section('B/C/D 反例②：缺同胞导入，且两种假 import 都骗不过');
  _expect1('没 import ⇒ 1 处（§AZ 那次的真身）', (Directory root) {
    _write(root, 'lib/b.dart', 'class B {}\n');
    _write(root, 'lib/a.dart', '''
class A {
  B? b;
}
''');
  }, 1, contains: 'B');

  _expect1('注释里的 import 不算指令 ⇒ 仍 1 处', (Directory root) {
    _write(root, 'lib/b.dart', 'class B {}\n');
    _write(root, 'lib/a.dart', '''
// import 'b.dart';

class A {
  B? b;
}
''');
  }, 1, contains: 'B');

  _expect1('字符串里的 import 不算指令 ⇒ 仍 1 处', (Directory root) {
    _write(root, 'lib/b.dart', 'class B {}\n');
    _write(root, 'lib/a.dart', '''
const String decoy = "import 'b.dart';";

class A {
  B? b;
}
''');
  }, 1, contains: 'B');

  section('E 私有名跳过（否则三个页面各一份 `_RowCtl` 会连环误报）');
  _expect1('别的文件声明 `class _C`，本文件用它 ⇒ 0 处', (Directory root) {
    _write(root, 'lib/c.dart', 'class _C {}\n');
    _write(root, 'lib/a.dart', '''
class A {
  _C? c;
}
''');
  }, 0);

  section('F/G/H 路径解析（不是按文件名比对）');
  _expect1("sub/a.dart 里 import '../b.dart' 指回 lib/b.dart ⇒ 0 处", (
    Directory root,
  ) {
    _write(root, 'lib/b.dart', 'class B {}\n');
    _write(root, 'lib/sub/a.dart', '''
import '../b.dart';

class A {
  B? b;
}
''');
  }, 0);

  _expect1(
    "sub/a.dart 里 import 'b.dart' 指向 lib/sub/b.dart（不存在）⇒ 仍 1 处",
    (Directory root) {
      _write(root, 'lib/b.dart', 'class B {}\n');
      _write(root, 'lib/sub/a.dart', '''
import 'b.dart';

class A {
  B? b;
}
''');
    },
    1,
    contains: 'B',
  );

  _expect1('package:shensuanzi/... 映射回 lib/... ⇒ 0 处', (Directory root) {
    _write(root, 'lib/src/b.dart', 'class B {}\n');
    _write(root, 'lib/a.dart', '''
import 'package:shensuanzi/src/b.dart';

class A {
  B? b;
}
''');
  }, 0);

  section('I/J 缺桶导入（检查 ① 的回归）');
  _expect1('用桶导出名 Zed 却没 import 桶 ⇒ 1 处', (Directory root) {
    _write(root, 'lib/uses.dart', '''
class Uses {
  Zed? z;
}
''');
  }, 1, contains: 'Zed');

  _expect1('import 了桶 ⇒ 0 处', (Directory root) {
    _write(root, 'lib/uses.dart', '''
import 'package:demo/demo.dart';

class Uses {
  Zed? z;
}
''');
  }, 0);

  section('K/L 两条已知边界（不误报 / 不查）');
  _expect1('as 前缀：v1 不支持，但也不能误报 ⇒ 0 处', (Directory root) {
    _write(root, 'lib/b.dart', 'class B {}\n');
    _write(root, 'lib/a.dart', '''
import 'b.dart' as b;

class A {
  b.B? x;
}
''');
  }, 0);

  _expect1('顶层**函数**引用不查（v1 边界）⇒ 0 处', (Directory root) {
    _write(root, 'lib/f.dart', 'int helper() => 1;\n');
    _write(root, 'lib/a.dart', '''
class A {
  int x = helper();
}
''');
  }, 0);

  stdout.writeln('');
  if (_failures.isEmpty) {
    stdout.writeln('自检通过：$_passed / $_passed');
    exit(0);
  }
  stdout.writeln('自检失败：通过 $_passed，失败 ${_failures.length}');
  for (final String name in _failures) {
    stdout.writeln('  ✗ $name');
  }
  exit(1);
}

/// 造一个迷你仓库、跑守卫、断言问题条数（可选断言首条含某子串）。
///
/// 固定写入 `lib/barrel.dart` —— 「缺桶导入」这类检查要有桶才谈得上。
void _expect1(
  String name,
  void Function(Directory root) build,
  int expected, {
  String? contains,
}) {
  final Directory root = Directory.systemTemp.createTempSync('ssz_guard_');
  try {
    _write(root, 'lib/barrel.dart', "export 'src/thing.dart' show Zed;\n");
    _write(root, 'lib/src/thing.dart', 'class Thing {}\n');
    build(root);

    final GuardReport report = runGuard(
      repo: root,
      barrelFiles: _barrelFiles,
      roots: _roots,
    );

    if (report.problems.length != expected) {
      final String found = report.problems.isEmpty
          ? ''
          : '：${report.problems.join(' | ')}';
      check(name, false, '预期 $expected 处，实得 ${report.problems.length} 处$found');
      return;
    }
    if (contains != null &&
        !report.problems.every(
          (String p) => p.contains(contains),
        )) {
      check(name, false, '问题文案里没提到 `$contains`：${report.problems.join(' | ')}');
      return;
    }
    check(name, true);
  } finally {
    root.deleteSync(recursive: true);
  }
}

void _write(Directory root, String rel, String content) {
  final File file = File('${root.path}/$rel');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}
