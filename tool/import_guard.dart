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
// ## 它只覆盖一类错误（别当成编译门禁）
//
// ✅ 用了某个桶导出名、却没有导入对应桶文件
// ❌ 类型不匹配、参数写错、方法不存在、拼写错的标识符 —— 一律看不见
//
// 真正的门禁仍然是用户终端的 `flutter analyze`。这个脚本的作用是
// **把那类错误的发现时刻从「用户复跑 flutter analyze」提前到「我改完就自验」**。
//
// ## 判断规则
//
// 1. 从两个桶文件的 `show` 子句**推导**导出名（不手写清单 ⇒ 不会漂移）；
// 2. 扫根 `lib/**` 与 `test/**`，先做**去注释、去字符串**（Dart 源码级状态机），
//    再丢掉 `import`/`export`/`library` 行；
// 3. 用到某名字、但该文件**没有** import 对应桶文件、且该名字不是本文件自己声明的
//    ⇒ 报一处。
//
// 前提（现状成立）：根层代码一律经桶文件取符号，无一处 import `package:*/src/`。
library;

import 'dart:io';

/// 被守卫的两个桶（包名 → 桶路径，相对仓库根）
const Map<String, String> barrels = <String, String>{
  'shensuanzi_app': 'packages/shensuanzi_app/lib/shensuanzi_app.dart',
  'shensuanzi_core': 'packages/shensuanzi_core/lib/shensuanzi_core.dart',
};

/// 扫描范围（相对仓库根）
const List<String> scanRoots = <String>['lib', 'test'];

void main() {
  final Directory repo = _repoRoot();
  stdout.writeln('根 Flutter 层导入守卫（lib/ + test/）—— 只查「缺桶导入」这一类');
  stdout.writeln('');

  // 1. 从桶文件取导出名
  final Map<String, Set<String>> exported = <String, Set<String>>{};
  for (final MapEntry<String, String> entry in barrels.entries) {
    final File file = File('${repo.path}/${entry.value}');
    if (!file.existsSync()) {
      stderr.writeln('找不到桶文件：${entry.value}');
      exit(2);
    }
    final Set<String> names = _showNames(file.readAsStringSync());
    exported[entry.key] = names;
    stdout.writeln('  ${entry.key}：${names.length} 个导出名');
  }
  stdout.writeln('');

  // 2. 逐文件检查
  final List<String> problems = <String>[];
  int files = 0;
  for (final String sub in scanRoots) {
    final Directory dir = Directory('${repo.path}/$sub');
    if (!dir.existsSync()) continue;
    for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      files++;
      final String source = entity.readAsStringSync();
      final String relative = _relative(repo.path, entity.path);
      final String body = _strip(source);
      final String header = body
          .split('\n')
          .where((String line) => !_isDirective(line))
          .join('\n');

      for (final MapEntry<String, Set<String>> entry in exported.entries) {
        if (source.contains('package:${entry.key}/')) continue; // 已经导入了这个包
        for (final String name in entry.value) {
          if (_declares(header, name)) continue; // 本文件自己声明的，不用导入
          if (RegExp('\\b$name\\b').hasMatch(header)) {
            problems.add(
              '$relative：用到 `$name`（来自 ${entry.key}），'
              '但没有 `import \'package:${entry.key}/${entry.key}.dart\';`',
            );
          }
        }
      }
    }
  }

  for (final String problem in problems) {
    stdout.writeln('  ✗ $problem');
  }
  stdout.writeln('');
  stdout.writeln('检查完成：$files 个文件，${problems.length} 处缺导入');
  exit(problems.isEmpty ? 0 : 1);
}

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

/// 去注释、去字符串（保留换行以便报行号，虽然当前只报文件名）。
///
/// 为什么必须去：注释和文档里到处会出现 `ExportSink` 这种名字（本文件自己的
/// 文档头就有），不去掉会满屏假报警。块注释按 Dart 规则**支持嵌套**。
String _strip(String source) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < source.length) {
    final String c = source[i];
    final String next = i + 1 < source.length ? source[i + 1] : '';

    // 行注释
    if (c == '/' && next == '/') {
      while (i < source.length && source[i] != '\n') {
        i++;
      }
      continue;
    }
    // 块注释（可嵌套）
    if (c == '/' && next == '*') {
      int depth = 1;
      i += 2;
      while (i < source.length && depth > 0) {
        if (source[i] == '/' && i + 1 < source.length && source[i + 1] == '*') {
          depth++;
          i += 2;
        } else if (source[i] == '*' &&
            i + 1 < source.length &&
            source[i + 1] == '/') {
          depth--;
          i += 2;
        } else {
          if (source[i] == '\n') out.write('\n');
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
      i += quote.length;
      while (i < source.length) {
        if (source[i] == r'\' && !triple) {
          i += 2; // 跳过转义的下一个字符
          continue;
        }
        if (source[i] == '\n') out.write('\n');
        if (source.startsWith(quote, i)) {
          i += quote.length;
          break;
        }
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
