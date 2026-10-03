// 根 Flutter 层的**导入守卫**。纯 Dart、无依赖，跑法：
//
//   dart run tool/import_guard.dart      （在仓库根执行）
//
// ## 为什么需要它
//
// `packages/shensuanzi_core` 与 `packages/shensuanzi_app` 是纯 Dart 包，
// `tool/typecheck.dart` 在那里是真门禁（把所有入口 import 一遍，编译不过就报）。
// 但根 `lib/` 与 `test/` 的文件都 import `package:flutter`：
//
// - `dart run` 编译不了它们（`dart:ui is not available on this platform`）
// - `dart analyze` 要起 analysis server 子进程（本机沙箱下 `CreateFile failed 231`）
//
// ⇒ **根层没有可达的编译门禁**，只能靠人跑 `flutter analyze`。
// 代价是真实的：§AF 落地时 4 个 widget 测试文件全部编译失败，原因都是
// 「用了 `ExportSink` / `ExportTable`，但没 import `package:shensuanzi_app/shensuanzi_app.dart`」
// —— `test/support/fake_export.dart` 里有那行导入，可 **Dart 的 import 不传递**，
// 别的文件看不见。
//
// 更气人的一次：§AZ 落地 1b 送货时 `lib/src/ui/app_shell.dart` 用了 `DeliveryPage`，
// **没 import `delivery_page.dart`** —— 而当时的本脚本只查桶文件，报了
// 「41 个文件，0 处缺导入」这一句**假绿**。（`flutter analyze` 一跑就现形，但那时
// 已经交出去了。）⇒ 本脚本从此扩成**两类检查**。
//
// ## 它覆盖两类错误（别当成编译门禁）
//
// ① 用了某个**桶**的导出名、却没有导入对应桶文件
// ② 用了**扫描集内另一个文件**声明的公开类型（`class` / `enum` / `mixin` /
//    `extension` / `typedef`），却没有 import 那个文件
//    —— ⚠️ **v1 只查无前缀的相对导入**（`import 'foo.dart';`）；
//    `as` 前缀的**不支持**（记在案），因为那时用法写成 `f.Foo`、两边都对不上
//
// ❌ 类型不匹配、参数写错、方法不存在、拼写错的标识符 —— 一律看不见
// ❌ 顶层**函数**与**变量**的跨文件引用 —— 不查（只认类型声明）
//
// 真正的门禁仍然是用户终端的 `flutter analyze`。这个脚本的作用是
// **把那类错误的发现时刻从「用户复跑 flutter analyze」提前到「我改完就自验」**。
//
// ## 判断规则
//
// 1. 从两个桶文件的 `show` 子句**推导**导出名（不手写清单 ⇒ 不会漂移）；
// 2. 扫根 `lib/**` 与 `test/**`，先做**去注释、去字符串**（Dart 源码级状态机），
//    再丢掉 `import`/`export`/`library` 行；
// 3. 用了某桶导出名、但该文件**没有** import 对应桶文件、且该名字不是本文件自己声明的
//    ⇒ 报一处；
// 4. ② 的同理：名字取自**扫描集内文件自己声明的公开类型**
//    （`_` 开头的**私有名跳过** —— 它们不可能被别的库引用，纳进来只会满屏误报）；
//    「有没有导入那个文件」按**路径解析**比对，不做字符串包含
//    （`import 'ui/foo.dart';` 写在 `lib/src/app.dart` 里 ⇒ 解析成 `lib/src/ui/foo.dart`；
//    `package:shensuanzi/...` 也映射回 `lib/...`）；
// 5. **接受假阳性**：局部变量遮蔽同名类型会误报 —— **宁多报，不假绿**。
//
// ## 一处实现细节（别退化成「对整段源码跑正则」）
//
// 注释 / 字符串里出现的 `import 'foo.dart';` **不是指令**。所以：
// `_strip` 把注释与字符串整体替换成**等长空格**（换行保留）⇒ 去噪文本与原文
// **偏移一致**；「这一行是不是真指令」按**去噪文本**判，路径再回**原文同偏移**取。
// 于是 `// import 'x.dart';` 与多行字符串里的同款文本都不会被误判。
//
// ## 用法与自检
//
//   dart run tool/import_guard.dart              # 扫本仓库
//   dart run tool/import_guard.dart <某个根>      # 扫指定根（给自检用）
//   dart run tool/selfcheck_import_guard.dart     # **验证守卫本身**（正例 + 反例 + 假 import）
//
// 核心逻辑在 [runGuard]（纯函数、不打印、不 `exit`）⇒ 自检能造一个临时「迷你仓库」
// 去断言它**该报的报、不该报的不报**。**改守卫必须同步跑自检**：
// 「守卫改坏了」和「代码真缺导入」在输出上长得一样，只有自检能分辨。
//
// ## 前提（现状成立）
//
// 根层代码一律经桶文件或相对路径取符号（`lib/` 内部全相对、`test/` 用
// `package:shensuanzi/src/...`），无 `part`。
library;

import 'dart:io';

/// 被守卫的桶（包名 → 桶路径，相对仓库根）
///
/// ⚠️ **根应用依赖了几个包，这里就要有几个** —— 2026-10-02 加 `shensuanzi_host`
/// 时发现：漏登记那个包，等于对它的符号**完全不设防**
/// （当时 `lib/src/app.dart` 用了 `HostServiceController` 却没 import，本脚本报「0 处」）。
const Map<String, String> barrels = <String, String>{
  'shensuanzi_app': 'packages/shensuanzi_app/lib/shensuanzi_app.dart',
  'shensuanzi_core': 'packages/shensuanzi_core/lib/shensuanzi_core.dart',
  'shensuanzi_host': 'packages/shensuanzi_host/lib/shensuanzi_host.dart',
};

/// 扫描范围（相对仓库根）
const List<String> scanRoots = <String>['lib', 'test'];

/// 根包名 —— 用于把 `package:shensuanzi/...` 映射回 `lib/...`
const String rootPackage = 'shensuanzi';

void main(List<String> args) {
  // 可选参数：扫描根（默认 = 本仓库根）。给自检脚本用 —— `tool/selfcheck_import_guard.dart`
  // 会造一个临时「迷你仓库」，所以核心逻辑必须能对**任意根**跑，且不能自己 `exit()`。
  final Directory repo = args.isNotEmpty ? Directory(args[0]) : _repoRoot();

  final GuardReport report;
  try {
    report = runGuard(repo: repo);
  } on StateError catch (error) {
    stderr.writeln(error.message);
    exit(2);
  }

  stdout.writeln('根 Flutter 层导入守卫（${report.roots.join(' + ')}）');
  stdout.writeln('  ① 缺桶导入   ② 缺同胞文件导入（v1：只查无前缀的相对导入）');
  stdout.writeln('');
  for (final MapEntry<String, int> entry in report.barrelExports.entries) {
    stdout.writeln('  ${entry.key}：${entry.value} 个导出名');
  }
  stdout.writeln('');
  stdout.writeln('  扫描集：${report.files} 个文件，${report.declarations} 个公开类型声明');
  stdout.writeln('');
  for (final String problem in report.problems) {
    stdout.writeln('  ✗ $problem');
  }
  stdout.writeln('');
  stdout.writeln('检查完成：${report.files} 个文件，${report.problems.length} 处缺导入');
  exit(report.problems.isEmpty ? 0 : 1);
}

/// 一次检查的结论（**纯数据，不打印、不 exit** —— 便于 [runGuard] 被自检复用）。
class GuardReport {
  GuardReport({
    required this.roots,
    required this.files,
    required this.declarations,
    required this.barrelExports,
    required this.problems,
  });

  /// 扫过的目录（相对仓库根）
  final List<String> roots;

  /// 扫描到的 `.dart` 文件数
  final int files;

  /// 扫描集里**公开**类型声明的总数
  final int declarations;

  /// 每个桶导出了多少名字（`键` = 包名）
  final Map<String, int> barrelExports;

  /// 每一处缺导入（人读的一句话）
  final List<String> problems;
}

/// 跑一遍守卫。**不打印、不 `exit`** —— 供 `main` 与自检脚本共用。
///
/// 桶文件缺失时抛 [StateError]（由调用方决定怎么报）。
GuardReport runGuard({
  required Directory repo,
  Map<String, String> barrelFiles = barrels,
  List<String> roots = scanRoots,
}) {
  // 1. 从桶文件取导出名
  final Map<String, Set<String>> exported = <String, Set<String>>{};
  for (final MapEntry<String, String> entry in barrelFiles.entries) {
    final File file = File('${repo.path}/${entry.value}');
    if (!file.existsSync()) {
      throw StateError('找不到桶文件：${entry.value}');
    }
    exported[entry.key] = _showNames(file.readAsStringSync());
  }

  // 2. 载入扫描集（读一次，两类检查共用）
  final List<_Unit> units = _loadUnits(repo, roots);
  int declarations = 0;
  for (final _Unit unit in units) {
    declarations += unit.declared.length;
  }

  // 3. 两类检查
  return GuardReport(
    roots: roots,
    files: units.length,
    declarations: declarations,
    barrelExports: <String, int>{
      for (final MapEntry<String, Set<String>> entry in exported.entries)
        entry.key: entry.value.length,
    },
    problems: <String>[
      ..._missingBarrelImports(units, exported),
      ..._missingSiblingImports(units),
    ],
  );
}

// ---------------------------------------------------------------- 数据载入

/// 一个被扫描的 Dart 文件。
///
/// ⚠️ 构造函数必须是 `const` —— 本项目启用了
/// `prefer_const_constructors_in_immutables`（`flutter_lints 6.0.0`），
/// 全 final 字段的类不写 `const` 会被判 **info**，而门禁是 0 issues（`info` 也算）。
class _Unit {
  const _Unit({
    required this.rel,
    required this.body,
    required this.declared,
    required this.imports,
    required this.rawImports,
  });

  /// 相对仓库根的路径（正斜杠），如 `lib/src/app.dart`
  final String rel;

  /// 去注释 / 去字符串、且剔除定向行之后的正文
  final String body;

  /// 本文件声明的**公开**类型名（`_` 开头的跳过）
  final Set<String> declared;

  /// 本文件导入的**本仓库文件**（解析成相对仓库根的路径）
  final Set<String> imports;

  /// 本文件 `import` 的**字面路径**（`dart:io` / `package:flutter/...` / `foo.dart`）
  final Set<String> rawImports;
}

List<_Unit> _loadUnits(Directory repo, List<String> roots) {
  final List<_Unit> units = <_Unit>[];
  for (final String sub in roots) {
    final Directory dir = Directory('${repo.path}/$sub');
    if (!dir.existsSync()) continue;
    for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String source = entity.readAsStringSync();
      final String rel = _relative(repo.path, entity.path);
      final String stripped = _strip(source);

      final Set<String> declared = <String>{
        for (final RegExpMatch match in RegExp(
          r'\b(?:class|enum|mixin|extension|typedef)\s+([A-Za-z$_][\w$]*)',
        ).allMatches(stripped))
          if (!match.group(1)!.startsWith('_')) match.group(1)!,
      };

      final Set<String> rawImports = <String>{};
      final Set<String> imports = <String>{};
      for (final String path in _directivePaths(source, stripped)) {
        rawImports.add(path);
        final String? local = _asRepoPath(path);
        if (local != null) {
          imports.add(local);
        } else if (!path.startsWith('dart:') && !path.startsWith('package:')) {
          imports.add(_resolveRelative(rel, path)); // 相对路径：按所在目录解析
        }
      }

      units.add(
        _Unit(
          rel: rel,
          body: stripped
              .split('\n')
              .where((String line) => !_isDirective(line))
              .join('\n'),
          declared: declared,
          imports: imports,
          rawImports: rawImports,
        ),
      );
    }
  }
  return units;
}

/// `path` 若指向本仓库的文件，返回它相对仓库根的路径；否则（`dart:` / 外部包）返回 `null`。
String? _asRepoPath(String path) {
  if (path.startsWith('dart:')) return null;
  if (path.startsWith('package:')) {
    const String prefix = 'package:$rootPackage/';
    return path.startsWith(prefix) ? 'lib/${path.substring(prefix.length)}' : null;
  }
  return null; // 相对路径由调用方按所在目录解析
}

// ------------------------------------------------------------------ 检查 ①

List<String> _missingBarrelImports(
  List<_Unit> units,
  Map<String, Set<String>> exported,
) {
  final List<String> problems = <String>[];
  for (final _Unit unit in units) {
    for (final MapEntry<String, Set<String>> entry in exported.entries) {
      // 已经导入了这个包（桶或 src 都算）
      if (unit.rawImports.any(
        (String p) => p.startsWith('package:${entry.key}/'),
      )) {
        continue;
      }
      for (final String name in entry.value) {
        if (_declares(unit.body, name)) continue; // 本文件自己声明的
        if (RegExp('\\b$name\\b').hasMatch(unit.body)) {
          problems.add(
            '${unit.rel}：用到 `$name`（来自 ${entry.key}），'
            '但没有 `import \'package:${entry.key}/${entry.key}.dart\';`',
          );
        }
      }
    }
  }
  return problems;
}

// ------------------------------------------------------------------ 检查 ②

/// 用了扫描集内**另一个文件**声明的公开类型，却没 import 那个文件。
List<String> _missingSiblingImports(List<_Unit> units) {
  // 名字 → 声明它的文件集合
  final Map<String, Set<String>> declaredIn = <String, Set<String>>{};
  for (final _Unit unit in units) {
    for (final String name in unit.declared) {
      declaredIn.putIfAbsent(name, () => <String>{}).add(unit.rel);
    }
  }

  final List<String> problems = <String>[];
  for (final _Unit unit in units) {
    for (final MapEntry<String, Set<String>> entry in declaredIn.entries) {
      final String name = entry.key;
      if (unit.declared.contains(name)) continue; // 自己声明的
      if (!RegExp('\\b$name\\b').hasMatch(unit.body)) continue; // 没用到
      if (entry.value.any(unit.imports.contains)) continue; // 已导入声明处
      problems.add(
        '${unit.rel}：用到 `$name`（声明在 ${entry.value.join(' / ')}），'
        '但没有 import 它',
      );
    }
  }
  return problems;
}

// -------------------------------------------------------------------- 工具

Directory _repoRoot() {
  // 脚本在 <repo>/tool/ 下，取上两级 —— 于是从任何目录跑都对
  final String script = File.fromUri(Platform.script).absolute.path;
  return Directory(File(script).parent.parent.path);
}

String _relative(String root, String path) {
  final String normalizedRoot = root.replaceAll('\\', '/');
  final String normalized = path.replaceAll('\\', '/');
  return normalized.startsWith('$normalizedRoot/')
      ? normalized.substring(normalizedRoot.length + 1)
      : normalized;
}

/// 桶文件里所有 `show A, B, C;` 的名字。
Set<String> _showNames(String source) {
  final Set<String> names = <String>{};
  for (final RegExpMatch match in RegExp(
    r'show\s+([^;]+);',
  ).allMatches(source)) {
    for (final String raw in match.group(1)!.split(',')) {
      final String name = raw.trim();
      if (name.isNotEmpty) names.add(name);
    }
  }
  return names;
}

/// 真·定向行里的路径（`import` / `export` / `part`）。
///
/// 用**去噪文本**判断「这一行是不是指令」，再从**原文**同一行取引号里的路径
/// —— 于是 `// import 'x.dart';` 与多行字符串里的同款文本都不会被误判。
List<String> _directivePaths(String source, String stripped) {
  final List<String> out = <String>[];
  int start = 0;
  for (int i = 0; i <= source.length; i++) {
    if (i != source.length && source[i] != '\n') continue;
    final String trimmed = stripped.substring(start, i).trimLeft();
    if (trimmed.startsWith('import ') ||
        trimmed.startsWith('export ') ||
        trimmed.startsWith('part ')) {
      final String? path = _pathLiteral(source.substring(start, i));
      if (path != null) out.add(path);
    }
    start = i + 1;
  }
  return out;
}

/// 从一行指令里取引号中的路径；取不到返回 `null`。
String? _pathLiteral(String line) {
  for (final String quote in <String>["'", '"']) {
    final int a = line.indexOf(quote);
    if (a < 0) continue;
    final int b = line.indexOf(quote, a + 1);
    if (b < 0) continue;
    return line.substring(a + 1, b);
  }
  return null;
}

/// 把 `import 'ui/foo.dart';` 解析成相对仓库根的路径（相对 [fromRel] 所在目录）。
String _resolveRelative(String fromRel, String path) {
  final List<String> parts = fromRel.split('/')..removeLast();
  for (final String segment in path.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(segment);
  }
  return parts.join('/');
}

/// 去注释、去字符串。
///
/// **被去掉的字符用等长空格占位**（换行保留）⇒ 结果与原文**偏移一致**，
/// 于是 [_directivePaths] 能用它判断「哪一行是真指令」再回原文取路径。
/// 为什么必须去：注释和文档里到处会出现 `ExportSink` 这种名字（本文件自己的
/// 文档头就有），不去掉会满屏假报警。块注释按 Dart 规则**支持嵌套**。
String _strip(String source) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < source.length) {
    final String c = source[i];
    final String next = i + 1 < source.length ? source[i + 1] : '';

    // 行注释（换行本身留给下面的通用分支写）
    if (c == '/' && next == '/') {
      while (i < source.length && source[i] != '\n') {
        out.write(' ');
        i++;
      }
      continue;
    }
    // 块注释（可嵌套）
    if (c == '/' && next == '*') {
      out.write('  ');
      int depth = 1;
      i += 2;
      while (i < source.length && depth > 0) {
        if (source[i] == '/' && i + 1 < source.length && source[i + 1] == '*') {
          out.write('  ');
          depth++;
          i += 2;
        } else if (source[i] == '*' &&
            i + 1 < source.length &&
            source[i + 1] == '/') {
          out.write('  ');
          depth--;
          i += 2;
        } else {
          out.write(source[i] == '\n' ? '\n' : ' ');
          i++;
        }
      }
      continue;
    }
    // 字符串（含三引号；raw 字符串按普通串处理，差别只影响转义，不影响我们去内容）
    if (c == "'" || c == '"') {
      final bool triple =
          i + 2 < source.length && source[i + 1] == c && source[i + 2] == c;
      final String quote = triple ? c * 3 : c;
      out.write(' ' * quote.length);
      i += quote.length;
      while (i < source.length) {
        if (source[i] == r'\' && !triple) {
          out.write('  ');
          i += 2; // 跳过转义的下一个字符
          continue;
        }
        if (source.startsWith(quote, i)) {
          out.write(' ' * quote.length);
          i += quote.length;
          break;
        }
        out.write(source[i] == '\n' ? '\n' : ' ');
        i++;
      }
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

bool _isDirective(String line) {
  final String trimmed = line.trimLeft();
  return trimmed.startsWith('import ') ||
      trimmed.startsWith('export ') ||
      trimmed.startsWith('part ') ||
      trimmed.startsWith('library ');
}

/// 该名字是不是本文件自己声明的（自己声明的就不用导入）。
bool _declares(String body, String name) =>
    RegExp('\\b(class|enum|typedef|mixin|extension)\\s+$name\\b').hasMatch(body);
