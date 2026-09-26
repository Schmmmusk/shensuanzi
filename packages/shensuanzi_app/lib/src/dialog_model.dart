/// 首启「选择数据存放位置」对话框的**状态机**（纯 Dart，可测）。
///
/// ## 为什么单独抽出来
///
/// 对话框只有一屏，但**它的决策一旦错，用户数据就危险**
/// （`%LOCALAPPDATA%` 被清、OneDrive 冲突、U 盘拔盘）；
/// 而 Flutter 的 widget 测试在本机跑不了。把状态机抽成纯 Dart，
/// 就能用 `dart test` 把「默认路径 / 三档校验 / 二次确认 / 复用老数据」
/// 全部钉住 —— **widget 只剩画界面**。
///
/// ## 交互（`docs/reply.md` §二）
///
/// ```text
/// ┌────────────────────────────────────┐
/// │  选择数据存放位置                   │
/// │  建议放在非系统盘：                 │
/// │  D:\神算子数据\        D 盘剩余 128 GB
/// │  ⚠（有警告/拒绝时这里出一句话）      │
/// │        [ 更改 ]  [ 开始使用 ]       │
/// └────────────────────────────────────┘
/// ```
///
/// **不做**：欢迎语、店名输入、账户预设、完成页 —— 那是第 10 天回补的部分。
library;

import 'dart:io';

import 'bootstrap.dart';
import 'data_directory.dart';
import 'data_directory_service.dart';
import 'data_marker.dart';

/// 「开始使用」按下去之后发生了什么
enum ConfirmOutcome {
  /// 新建：空目录（或不存在），已创建并写入标记
  created,

  /// 复用：目录里已有 `.shensuanzi-data`，**数据立刻回来**
  reused,

  /// 目录非空且没有标记 —— 先问用户。确认后**再调一次**
  /// `confirm(acceptForeign: true)` 才会真的初始化
  needsForeignConfirm,

  /// 用不了：校验为 `reject`，或落盘失败。原因见 [DataDirectoryDialogModel.notice]
  blocked,
}

/// 提示的严重程度 —— 给 widget 选颜色用（不要用文字串去判断）
enum DialogNoticeKind {
  none,

  /// 能用但有代价（`%LOCALAPPDATA%` / 网盘 / U 盘 / 目录里已有别的东西）
  warning,

  /// 真的不行（系统目录 / 系统盘根 / 写不进去）
  error,
}

class DataDirectoryDialogModel {
  DataDirectoryDialogModel(this.service);

  final DataDirectoryService service;

  String _path = '';
  DirectoryAdvice _advice = const DirectoryAdvice.ok();
  bool _needsForeignConfirm = false;
  String? _failure;
  DataLocation? _location;

  /// 当前候选路径
  String get path => _path;

  /// 当前校验结论
  DirectoryAdvice get advice => _advice;

  /// 容量提示，如 `D 盘剩余 128 GB`；拿不到为 `null`（不编一个值）
  String? get capacityHint =>
      _path.isEmpty ? null : service.spaceHint(_path);

  /// 能不能点「开始使用」。
  ///
  /// **`warn` 也是 `true`** —— 警告不拦人（`docs/data_directory.md` §3.2）。
  bool get canConfirm => _advice.isUsable && !_needsForeignConfirm;

  /// 目录非空且没有标记 —— widget 该把按钮换成「就用这个文件夹」
  bool get needsForeignConfirm => _needsForeignConfirm;

  /// 落盘失败的原因（写不进去等）；成功或还没试过时为 `null`
  String? get failure => _failure;

  /// 初始化结果；还没成功时为 `null`
  DataLocation? get location => _location;

  bool get isDone => _location != null;

  /// **给用户看的唯一一句话**（含「怎么办」）；一切正常时为 `null`。
  ///
  /// 按 `docs/ui_principles.md` §五：说「怎么办」，不说「哪里错了」。
  String? get notice {
    if (_failure != null) return _failure;
    if (_advice.verdict == DirectoryVerdict.reject) {
      return _compose(_advice.reason, _advice.advice);
    }
    if (_needsForeignConfirm) {
      return '这个文件夹里已经有别的东西。'
          '确认要放在这里的话，请再点一次「就用这个文件夹」。';
    }
    if (_advice.verdict == DirectoryVerdict.warn) {
      return _compose(_advice.reason, _advice.advice);
    }
    return null;
  }

  /// 提示的严重程度（widget 据此选颜色，不要用文字串判断）
  DialogNoticeKind get noticeKind {
    if (_failure != null || _advice.verdict == DirectoryVerdict.reject) {
      return DialogNoticeKind.error;
    }
    if (_needsForeignConfirm || _advice.verdict == DirectoryVerdict.warn) {
      return DialogNoticeKind.warning;
    }
    return DialogNoticeKind.none;
  }

  /// 打开对话框：用**默认位置**起步（首次启动不弹目录选择框）。
  void open() => choosePath(service.resolveDefault());

  /// 用户点了「更改」，并在系统文件夹选择器里选了一个路径。
  ///
  /// 会清掉上一次的结果 —— **改了路径，之前的结论就作废**
  /// （否则会拿旧的成功结果去开库，而那个目录已经不是用户选的了）。
  void choosePath(String path) {
    _location = null;
    _failure = null;
    _needsForeignConfirm = false;
    _path = path;
    _advice = service.validate(path);
    if (!_advice.isUsable) return;
    // 非空且无标记 → 先问用户，**不是**直接拒绝：
    // 他可能就是要放在这个文件夹里（见 docs/data_directory.md §5）
    _needsForeignConfirm = contentsOf(path) == DirectoryContents.foreign;
  }

  /// 点了「开始使用」（或确认过之后的「就用这个文件夹」）。
  ///
  /// **不抛异常** —— 失败也要有结论，UI 才知道该显示什么。
  ConfirmOutcome confirm({bool acceptForeign = false}) {
    if (!_advice.isUsable) return ConfirmOutcome.blocked;
    if (_needsForeignConfirm && !acceptForeign) {
      return ConfirmOutcome.needsForeignConfirm;
    }
    try {
      final DataLocation location = service.ensureInitialized(
        _path,
        acceptForeignDirectory: acceptForeign,
      );
      _location = location;
      _needsForeignConfirm = false;
      _failure = null;
      return location.createdNow
          ? ConfirmOutcome.created
          : ConfirmOutcome.reused;
    } on DataDirectoryRejected catch (error) {
      _failure = _compose(error.reason, error.howTo);
      return ConfirmOutcome.blocked;
    } on FileSystemException catch (error) {
      _failure = '这个位置现在写不进去'
          '（${error.osError?.message ?? error.message}），请换一个文件夹';
      return ConfirmOutcome.blocked;
    }
  }

  static String _compose(String reason, String? advice) =>
      (advice == null || advice.isEmpty) ? reason : '$reason。$advice';
}
