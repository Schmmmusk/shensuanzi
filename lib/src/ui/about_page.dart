/// **关于**（2026-11-28 重构；乙案收尾）。
///
/// ## 结构（标准 App 的信息架构）
///
/// ```
/// 关于（本页 = 门户）
/// ├── 图标 + 软件名 + 版本（大号加粗，居中）
/// └── ListTile 列表
///     ├── 开源许可        → OpenSourceLicensePage（读 LICENSE 文件）
///     ├── 第三方组件      → ThirdPartyPage（读 THIRD_PARTY.md）
///     ├── 开发人员        → DevelopersPage
///     ├── 致谢            → ThanksPage
///     ├── 开发者后记      → PostscriptPage
///     └── 访问源码仓库    → 调系统浏览器（打不开 GitHub 时给 Gitee）
/// ```
///
/// ## 纪律
///
/// - **零全局状态**：门户与文本子页都是 `StatelessWidget`；读文件那层用
///   `StatefulWidget` 只为持有 `Future`（不外泄）。版本由构造参数传入。
/// - **长文本不抄进代码**：见 `about_document.dart` 文件头（许可声明只有一个来源）。
/// - **读不到就说明白**：`text == null` 时显示「未能读取文件」+ 找过的位置，
///   绝不白屏 / 抛异常。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'about_document.dart';
import 'about_markdown.dart';

/// 关于页（门户）。纯展示，无回调、无全局状态。
class AboutPage extends StatelessWidget {
  const AboutPage({
    super.key,
    required this.versionLine,
    required this.schemaVersion,
    this.openUrl,
  });

  /// 版本行（`AppVersion.display`），由调用方传。
  final String versionLine;

  /// 打开外部链接的出口（测试注入用）。`null` ⇒ 用 [openExternalUrl]。
  ///
  /// 之所以做成构造参数：**零全局状态**（用户裁定），同时让"点开源仓库"
  /// 这条路径可测 —— 否则测试只能靠真的去拉起浏览器。
  final Future<bool> Function(String url)? openUrl;

  /// 数据格式版本（`Schema.version`），同上。
  final int schemaVersion;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color secondary = theme.textTheme.bodySmall?.color ?? Colors.black54;

    Widget tile({
      required Key key,
      required IconData icon,
      required String title,
      String? subtitle,
      required VoidCallback onTap,
    }) => ListTile(
      key: key,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: theme.colorScheme.primary),
      title: Text(title, style: const TextStyle(height: 1.6)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(height: 1.6, color: secondary),
            ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // ---- 顶部：图标 + 名称 + 版本（居中放大）----
                const SizedBox(height: 16),
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Image.asset(
                      'assets/app_icon.png',
                      key: const Key('about-icon'),
                      width: 88,
                      height: 88,
                      // 原图 1024×1024（1.4 MB）—— 只显示 88 逻辑像素，
                      // 按 2 倍屏幕解码就够，别把 1024² 解进内存。
                      cacheWidth: 176,
                      fit: BoxFit.cover,
                      // 理论上打包不会漏，但漏了不能白屏：回退到主题色 + 图标
                      errorBuilder:
                          (BuildContext context, Object error, StackTrace? s) =>
                              Container(
                                width: 88,
                                height: 88,
                                color: theme.colorScheme.primary.withValues(
                                  alpha: 0.12,
                                ),
                                child: Icon(
                                  Icons.receipt_long,
                                  size: 48,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '神算子',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$versionLine（schema v$schemaVersion）',
                  key: const Key('about-version'),
                  textAlign: TextAlign.center,
                  style: TextStyle(height: 1.6, color: secondary),
                ),
                const SizedBox(height: 20),
                const Divider(height: 1),
                const SizedBox(height: 8),

                // ---- 列表项 ----
                tile(
                  key: const Key('about-license'),
                  icon: Icons.gavel,
                  title: '开源许可',
                  onTap: () => _push(context, const OpenSourceLicensePage()),
                ),
                tile(
                  key: const Key('about-third-party'),
                  icon: Icons.widgets_outlined,
                  title: '第三方组件',
                  onTap: () => _push(context, const ThirdPartyPage()),
                ),
                tile(
                  key: const Key('about-developers'),
                  icon: Icons.people_outline,
                  title: '开发人员',
                  onTap: () => _push(context, const DevelopersPage()),
                ),
                tile(
                  key: const Key('about-thanks'),
                  icon: Icons.volunteer_activism_outlined,
                  title: '致谢',
                  onTap: () => _push(context, const ThanksPage()),
                ),
                tile(
                  key: const Key('about-postscript'),
                  icon: Icons.edit_note,
                  title: '开发者后记',
                  onTap: () => _push(context, const PostscriptPage()),
                ),
                tile(
                  key: const Key('about-source'),
                  icon: Icons.code,
                  title: '访问源码仓库',
                  subtitle: '打不开 GitHub 时，用 Gitee 镜像',
                  onTap: () => _openRepository(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (BuildContext _) => page));
  }

  /// 打开系统浏览器。**打不开就给出 Gitee 链接**（国内访问 GitHub 常失败）。
  ///
  /// 不引 `url_launcher`：那是新的平台插件依赖（要动各平台注册与构建配置）。
  /// Windows 上 `cmd /c start` 够用，且失败可判定、可兜底。
  Future<void> _openRepository(BuildContext context) async {
    final bool ok = await (openUrl ?? openExternalUrl)(sourceRepositoryUrl);
    if (!context.mounted) return;
    if (ok) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('没能打开浏览器', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text('请手动复制下面的地址，粘贴到浏览器里：'),
              const SizedBox(height: 8),
              const SelectableText(sourceRepositoryUrl),
              const SelectableText(mirrorRepositoryUrl),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('知道了'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 源码仓库（GitHub 为主，Gitee 为国内备用）
/// 源码仓库（GitHub 为主）
const String sourceRepositoryUrl = 'https://github.com/Schmmmusk/shensuanzi';

/// 国内备用镜像（GitHub 打不开时）
const String mirrorRepositoryUrl = 'https://gitee.com/fdatps/shensuanzi';

/// 用系统默认浏览器打开 [url]；返回是否成功。
///
/// 只支持桌面三平台（「关于」在桌面壳里）；其他平台一律 `false`，
/// 由调用方给"手动复制"的兜底。
Future<bool> openExternalUrl(String url) async {
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    return false;
  }
  try {
    if (Platform.isWindows) {
      // 第 3 个参数是窗口标题：`start` 会把首个位置参数当标题，
      // 给空串才能把 url 当成打开目标。
      final ProcessResult r = await Process.run('cmd', <String>[
        '/c',
        'start',
        '',
        url,
      ], runInShell: false);
      return r.exitCode == 0;
    }
    final String cmd = Platform.isMacOS ? 'open' : 'xdg-open';
    final ProcessResult r = await Process.run(cmd, <String>[url]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

// ============================================================ 子页面

/// 开源许可（读 `LICENSE`）。
///
/// ⚠️ 名字**不能**叫 `LicensePage` —— Flutter 的 Material 库里已经有一个同名类
/// （`material/about.dart`），重名会让调用点报 "imported from both"，
/// 也让后来者分不清点进去看到的是哪一个。
class OpenSourceLicensePage extends StatelessWidget {
  const OpenSourceLicensePage({super.key, this.searchDirs});

  /// 测试注入用；生产不传（见 `about_document.dart` 的搜索顺序）
  final List<Directory>? searchDirs;

  @override
  Widget build(BuildContext context) => _ProgramDocumentPage(
    title: '开源许可',
    fileName: 'LICENSE',
    missingHint: '许可原文应该在这个文件里：',
    searchDirs: searchDirs,
  );
}

/// 第三方组件（读 `THIRD_PARTY.md`）。
class ThirdPartyPage extends StatelessWidget {
  const ThirdPartyPage({super.key, this.searchDirs});

  final List<Directory>? searchDirs;

  @override
  Widget build(BuildContext context) => _ProgramDocumentPage(
    title: '第三方组件',
    fileName: 'THIRD_PARTY.md',
    missingHint: '组件与许可清单应该在这个文件里：',
    searchDirs: searchDirs,
    // 2026-11-28：`.md` 要渲染成标题 + 表格，不能把 `#` 与 `|` 原样丢给用户
    markdown: true,
  );
}

/// 读「程序文件夹里的文本文件」并展示（长文本可滚，读不到有兜底）。
///
/// **纯 `StatelessWidget`**：文件同步读（见 `loadAboutDocument` 注释），
/// 所以没有 Future / 没有 loading 态 —— 页面没有状态可丢。
class _ProgramDocumentPage extends StatelessWidget {
  const _ProgramDocumentPage({
    required this.title,
    required this.fileName,
    required this.missingHint,
    this.searchDirs,
    this.markdown = false,
  });

  final String title;
  final String fileName;
  final String missingHint;

  /// `true` ⇒ 按 Markdown 渲染（标题 / 表格 / 列表）；`false` ⇒ 等宽原文
  final bool markdown;

  /// 只给测试注入；生产为 `null`
  final List<Directory>? searchDirs;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AboutDocument doc = loadAboutDocument(
      fileName,
      searchDirs: searchDirs,
    );
    if (!doc.found) {
      // 安全兜底：绝不白屏 / 不崩。把"找过哪儿"写出来，用户能自己判断
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '未能读取文件',
                key: const Key('about-document-missing'),
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                '$missingHint$fileName\n'
                '（可能在安装目录里，也可能被误删了。下面是我找过的位置。）',
                style: TextStyle(height: 1.8, color: theme.hintColor),
              ),
              const SizedBox(height: 12),
              for (final String path in doc.searched)
                SelectableText(
                  path,
                  style: TextStyle(
                    height: 1.6,
                    fontSize: 12,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
            ],
          ),
        ),
      );
    }
    if (markdown) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SingleChildScrollView(
          key: const Key('about-document-text'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: MarkdownView(parseMarkdown(doc.text!)),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: SelectableText(
          doc.text!,
          key: const Key('about-document-text'),
          style: const TextStyle(height: 1.7, fontSize: 13),
        ),
      ),
    );
  }
}

/// 纯文本子页（开发人员 / 致谢 / 后记共用外壳）。
class _TextSubPage extends StatelessWidget {
  const _TextSubPage({required this.title, required this.sections});

  final String title;

  /// 段落：`(小标题, 正文)`。小标题为 `null` 时只有正文。
  final List<(String?, String)> sections;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color secondary = theme.textTheme.bodySmall?.color ?? Colors.black54;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final (String?, String) section in sections) ...<Widget>[
                  if (section.$1 != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: Text(
                        section.$1!,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      section.$2,
                      style: TextStyle(height: 1.9, color: secondary),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 开发人员。
///
/// ⚠️ 名单**按 Git 提交记录**列，不编造角色分工（谁负责哪块只有你们自己知道）。
class DevelopersPage extends StatelessWidget {
  const DevelopersPage({super.key});

  @override
  Widget build(BuildContext context) => const _TextSubPage(
    title: '开发人员',
    sections: <(String?, String)>[
      (null, '神算子由以下人员开发与维护（按 Git 提交记录整理，排名不分先后）：'),
      ('主要作者', 'fdapts（1142004097@qq.com）'),
      ('协作开发', 'lonstarcat（kbakihito@gmail.com）'),
      ('项目维护', 'fdatps（cedarandjoy@163.com）· Schmmmusk'),
      (null, '联系与反馈：GitHub / Gitee 的 issue，或发邮件到 cedarandjoy@163.com。'),
    ],
  );
}

/// 致谢。
class ThanksPage extends StatelessWidget {
  const ThanksPage({super.key});

  @override
  Widget build(BuildContext context) => const _TextSubPage(
    title: '致谢',
    sections: <(String?, String)>[
      (null, '这个软件站在很多人的肩膀上：'),
      (
        '开源项目',
        'Flutter 与 Dart（UI 框架与语言）、SQLite（数据库引擎），'
            '以及 THIRD_PARTY.md 里列出的每一个包 —— 它们的作者把工具免费交出来，'
            '才有"一个人也能做桌面软件"的可能。',
      ),
      (
        '使用建议',
        '感谢每一位愿意把真实记账流程讲清楚的店主：'
            '「字要够大」「别让我自己加」「账要对得上」这些要求，'
            '才是这个软件今天的样子。',
      ),
    ],
  );
}

/// 开发者后记。
///
/// ⚠️ 这里的文字取自项目自己的设计记录（离线优先 / 面向中老年 / 数据归用户），
/// **不是**杜撰的个人经历。作者若要写自己的话，直接替换本页文本即可。
class PostscriptPage extends StatelessWidget {
  const PostscriptPage({super.key});

  @override
  Widget build(BuildContext context) => const _TextSubPage(
    title: '开发者后记',
    sections: <(String?, String)>[
      (
        null,
        '做这个软件，是因为见过太多小店的账本：一个硬皮本、一支圆珠笔，'
            '月底对一次账要花一晚上，还常常对不上。',
      ),
      (
        '三个不肯让步的选择',
        '① 离线优先 —— 店里断网也得能开单，数据只存在你自己的电脑上；\n'
            '② 字要大、按钮要大 —— 这个软件是给五十岁以上的人用的，不是给程序员用的；\n'
            '③ 账要对得上 —— 每一笔钱、每一件货都有流水，能翻到原始的录入单位。',
      ),
      (
        '关于长期',
        '软件以 AGPL-3.0 开源：就算有一天不再维护，'
            '数据和源码都在你手里，谁都可以接着做下去。',
      ),
    ],
  );
}
