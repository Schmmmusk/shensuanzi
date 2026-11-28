/// **读取「程序文件夹里的长文本」**（2026-11-28，关于页重构）。
///
/// ## 为什么读文件，而不是把文本抄进代码
///
/// `LICENSE` 与 `THIRD_PARTY.md` 是**许可声明**，打包时随产物一起分发
/// （`docs/windows_build.md` §八）。若在 Dart 里再抄一份，只要一份没跟上依赖升级，
/// 就成了**错误的许可声明** —— 那是法律问题。所以：**唯一来源是文件本身**。
///
/// ## 找不到时怎么办（安全兜底）
///
/// 用户可能误删、也可能在开发态运行（exe 目录里还没有这两个文件）。
/// 本模块**不抛异常**，返回 `text == null` + `searched`（找过哪些位置），
/// 由页面显示「未能读取」+ 具体路径 —— 白屏或崩溃是最差的处理。
///
/// 搜索顺序：
/// 1. **可执行文件所在目录**（安装后的真实位置）；
/// 2. **当前工作目录**（`flutter run` / `dart test` 时通常就是仓库根，
///    开发态能直接看到真文件，不必手工拷贝）。
library;

import 'dart:io';

/// 读取结果。`text == null` ⇒ 没找到（页面显示兜底文案）。
class AboutDocument {
  const AboutDocument({required this.text, required this.searched});

  /// 文件内容；`null` = 没找到 / 读失败
  final String? text;

  /// 依次找过的位置（给用户看"我去哪儿找过"，也方便开发态排查）
  final List<String> searched;

  bool get found => text != null;
}

/// 读 [fileName]（如 `LICENSE`）：先 exe 目录，再当前工作目录。
///
/// **同步**读：文件很小（LICENSE ~34 KB、THIRD_PARTY ~5 KB）、只在用户点开
/// 「关于」子页时读一次。换来的是页面可以是纯 `StatelessWidget`（没有 Future、
/// 没有 loading 态、没有"点开先转圈"）—— 对这种一年看一次的信息，
/// 少一层状态比省几毫秒更值。
///
/// [searchDirs] 只给测试注入用；生产不传。
AboutDocument loadAboutDocument(
  String fileName, {
  List<Directory>? searchDirs,
}) {
  final List<Directory> dirs = searchDirs ?? _defaultSearchDirs();
  final List<String> searched = <String>[];
  for (final Directory dir in dirs) {
    final File file = File('${dir.path}${Platform.pathSeparator}$fileName');
    searched.add(file.path);
    try {
      if (!file.existsSync()) continue;
      return AboutDocument(text: file.readAsStringSync(), searched: searched);
    } catch (_) {
      // 权限 / 编码问题：当作"没读到"，继续试下一个位置（不抛给 UI）
      continue;
    }
  }
  return AboutDocument(text: null, searched: searched);
}

List<Directory> _defaultSearchDirs() {
  final List<Directory> dirs = <Directory>[];
  try {
    // ① 程序所在目录（安装态）；Android 上 resolvedExecutable 无意义，跳过
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      dirs.add(File(Platform.resolvedExecutable).parent);
    }
  } catch (_) {
    // 个别平台拿不到路径 —— 忽略，走下一个候选
  }
  // ② 当前工作目录（开发态 / 从命令行启动时的仓库根）
  try {
    dirs.add(Directory.current);
  } catch (_) {
    // 同上
  }
  return dirs;
}
