/// 扫码配对页（§BL·三，2026-10-05 裁定 ③）。
///
/// ## 权限的两段式
///
/// 先给**理由文案**（「神算子需要相机权限来扫描电脑上的配对二维码。
/// 扫码只在本机处理，不会上传。」—— 裁定原文），用户点「开始扫码」
/// 才挂 `MobileScanner` —— 相机的系统权限弹窗在这一刻触发。
/// **不引 `permission_handler`**：`mobile_scanner` 启动即请求权限，
/// 理由前置 + 一次点击，少一个第三方依赖。
///
/// ## 流程
///
/// 扫到码 → `service.pairFromCode` 解析（非法码 = 页面内红字提示，不退出）
/// → 立即 `syncNow()` 首拉（成功才 pop 回设置页；失败把原因留在页面上，
/// 让用户能看着改）。
library;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart'
    show unexpectedFailureAdvice;

/// 返回值：配对 + 首拉都成功时的提示语；取消/失败返回 `null`。
///
/// [log] 可选 —— 只为把插件抛出的**原始英文异常**留进日志（M03：界面只给
/// 中文，原文进日志），没有日志时也不影响功能。
Future<String?> showPairingScanPage(
  BuildContext context,
  MobileSyncService service, {
  AppLog? log,
}) => Navigator.of(context).push<String>(
  MaterialPageRoute<String>(
    builder: (BuildContext context) =>
        PairingScanPage(service: service, log: log),
  ),
);

class PairingScanPage extends StatefulWidget {
  const PairingScanPage({super.key, required this.service, this.log});

  final MobileSyncService service;

  /// 原始异常只进日志（M03）—— 界面上一个字都不回显英文。
  final AppLog? log;

  @override
  State<PairingScanPage> createState() => _PairingScanPageState();
}

class _PairingScanPageState extends State<PairingScanPage> {
  /// `null` = 还在给理由 / 没开始扫
  bool _scanning = false;

  /// 扫码 / 连接过程中的错误（页内红字，不退出 —— 用户能照着改）
  String? _error;

  /// 首拉进行中（扫到码之后、pop 之前）
  bool _busy = false;

  /// 防重复处理同一帧的多个码
  bool _handled = false;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled || _busy) return;
    for (final Barcode barcode in capture.barcodes) {
      final String? raw = barcode.rawValue;
      if (raw == null || !raw.startsWith('shensuanzi://pair')) continue;
      _handled = true;
      await _pair(raw);
      return;
    }
  }

  Future<void> _pair(String raw) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.service.pairFromCode(raw);
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _handled = false;
          _error = '${error.message} 请对着电脑设置页上的二维码重新扫。';
        });
      }
      return;
    }
    // 首拉：成功才回设置页；失败把原因留在页面上（配对信息已存，
    // 用户可以回设置页直接「立即同步」重试，不用再扫一次）。
    await _firstSync();
  }

  /// **用配对码连接**（2026-10-25 D 批的兜底；2026-11-01 A4 改成 6 位短码）。
  ///
  /// 对话框里已经完成配对（校验 + 落盘），这里只做首拉 —— 与扫码路径共用
  /// [_firstSync]，两条路的「连上之后干什么」必须一模一样。
  Future<void> _manual() async {
    final bool? paired = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) =>
          ManualAddressDialog(service: widget.service),
    );
    if (paired != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    await _firstSync();
  }

  /// 配对已完成（扫码 / 手动填）⇒ 拉第一次。
  ///
  /// ⚠️ syncNow 的结果保证不抛（服务内全兜底），但这里再兜一层 ——
  /// 转圈永远停不下来比报错糟糕一万倍（真机踩过：§BL·落地·补 1）
  Future<void> _firstSync() async {
    SyncOutcome outcome;
    try {
      outcome = await widget.service.syncNow();
    } catch (error, stack) {
      // N-f 站点 3（2026-11-05 裁定甲）：`widget.log` 就在下面几十行的相机
      // 分支里用着，这条 catch 却把 `$error`（英文原文）直接甩到页面上。
      // 出口有，只是没调用 —— 现在补上，界面换成人话。
      widget.log?.crash(error, stack, label: '配对后首拉兜底');
      if (mounted) {
        setState(() {
          _busy = false;
          _handled = false;
          // lead 只给结论，动作交给分类文案 —— 若把「请重新扫码」也塞进 lead，
          // 认得出原因的那几档会变成「先让你扫码、再告诉你为什么失败」。
          // 本页扫码 UI 仍在屏上，入口不用靠这句话指。
          _error = unexpectedFailureAdvice(
            error,
            logged: widget.log != null,
            lead: '同步时出错。',
          );
        });
      }
      return;
    }
    if (!mounted) return;
    if (outcome.kind == SyncOutcomeKind.ok) {
      Navigator.of(context).pop(outcome.message);
      return;
    }
    setState(() {
      _busy = false;
      _handled = false;
      _error = outcome.message;
    });
  }

  /// 相机打不开时的页内提示（M03）。
  ///
  /// ⚠️ 界面**只给中文**；插件的原始英文异常送进日志（有日志时）。
  Widget _scanError(BuildContext context, MobileScannerException error) {
    widget.log?.crash(error, StackTrace.current, label: '扫码相机打不开');
    final ThemeData theme = Theme.of(context);
    final String message = scanFailureMessage(
      scanFailureKindOf(error.errorCode.name),
    );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.no_photography_outlined,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(height: 1.6),
            ),
            const SizedBox(height: 20),
            // 权限类错误「去设置里打开」之后需要回到本页重试 —— 给一个明确
            // 的入口：回到扫码前的说明页，用户点「开始扫码」会再请求一次权限。
            OutlinedButton.icon(
              onPressed: () => setState(() {
                _scanning = false;
                _error = null;
              }),
              icon: const Icon(Icons.refresh),
              label: const Text('重新试一次'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('扫码连接主机')),
      body: _busy
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('连接主机、拉取数据…', style: TextStyle(height: 1.6)),
                ],
              ),
            )
          : _scanning
          ? Column(
              children: <Widget>[
                if (_error != null)
                  Container(
                    width: double.infinity,
                    color: theme.colorScheme.errorContainer,
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        height: 1.6,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                Expanded(
                  child: MobileScanner(
                    onDetect: (BarcodeCapture capture) => _onDetect(capture),
                    // M03（2026-10-08）：插件自带的错误页是**英文**的
                    // （「Camera permission denied.」）。换成本地的中文解释 +
                    // 「怎么办」—— 归类与措辞在纯 Dart 的 `scan_error.dart`
                    // （`dart test` 钉得住），这里只摆放。
                    errorBuilder: _scanError,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '对着电脑「设置 → 多设备同步」里的二维码。',
                    style: TextStyle(
                      height: 1.6,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                ),
              ],
            )
          // 批 3 第 14 条：**引导态可滚**。2.0 档 + 小屏下说明文字会顶破屏幕，
          // 「开始扫码」被挤出可视区 = 用户以为这页没按钮。
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '神算子需要相机权限来扫描电脑上的配对二维码。'
                    '扫码只在本机处理，不会上传。',
                    style: TextStyle(height: 1.6),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '先在电脑上打开「设置 → 多设备同步」，把二维码显示出来。',
                    style: TextStyle(
                      height: 1.6,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(
                        height: 1.6,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () => setState(() => _scanning = true),
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('开始扫码'),
                  ),
                  const SizedBox(height: 8),
                  // D 批（2026-10-25）：**零兜底 → 有兜底**。
                  // 现场是电脑挑错了网卡（穿透工具抢了 WLAN），二维码扫得到、
                  // 手机连不上，而从前这一页只有「开始扫码」——用户没有出路。
                  //
                  // A4（2026-11-01 用户裁定）：入口名从「手动填地址」改成
                  // 「用 6 位配对码」—— 旧名字本身就在误导（用户以为只填 IP 就行，
                  // 而真正的配对码有 100 个字符，没人愿意抄）。
                  OutlinedButton.icon(
                    key: const Key('pairing-manual-entry'),
                    onPressed: _manual,
                    icon: const Icon(Icons.pin_outlined),
                    label: const Text('扫不了码？用 6 位配对码'),
                  ),
                ],
              ),
            ),
    );
  }
}

/// 「用配对码连接」对话框（2026-10-25 D 批；2026-11-01 A4 改成 6 位短码）。
///
/// ## 三种输入都收（分流见 `PairingAddress` / `MobileSyncService`）
///
/// | 用户手上有的 | 结果 |
/// |---|---|
/// | **6 位数字**（+ 地址） | 走短码配对：手机发请求 → **电脑上点「允许」** → 拿到凭据（A4） |
/// | 完整配对码 `shensuanzi://pair?...` | 等同扫码，**能完成配对**（含身份与令牌） |
/// | 光一个地址 `192.168.1.5:17890` | **只换地址**（前提：之前配对过，令牌沿用） |
///
/// ## 为什么不再叫「手动填地址」
///
/// 用户 2026-11-01 的原话：入口叫「手动填地址」、输入框写「电脑地址」，
/// 于是一直以为「填个 IP 就行」—— 而真正的配对码是 100 个字符，
/// 谁也不愿意抄。名字改成「用 6 位配对码」之后，**入口名本身就是说明书**。
///
/// ## 只有短码这一条路要联网（其余两条仍是纯本地）
///
/// 首拉（`syncNow`）仍由调用方做。短码要发 HTTP 是绕不开的 ——
/// 但它跑在注入的 `Transport` 上，widget 测试可以喂假传输，不会碰真网络
///（真网络在 `testWidgets` 的假时钟下会卡死，这是本仓踩过的坑）。
///
/// 格式错误的提示留在对话框里（红字），用户能当场改 —— 不用关掉重开。
class ManualAddressDialog extends StatefulWidget {
  const ManualAddressDialog({
    super.key,
    required this.service,
    this.title = '用配对码连接',
  });

  final MobileSyncService service;

  /// 对话框标题。**两处入口的场景不同，标题就该不同**：
  /// 扫码页是「第一次配对」（用配对码连接），设置页是「已配对的手机换地址」
  /// （换电脑地址）—— 用同一个标题会让后一种用户以为要重新配对。
  final String title;

  @override
  State<ManualAddressDialog> createState() => _ManualAddressDialogState();
}

class _ManualAddressDialogState extends State<ManualAddressDialog> {
  final TextEditingController _address = TextEditingController();
  final TextEditingController _code = TextEditingController();

  /// 格式/前置条件错误（红字，留在对话框里）
  String? _error;

  /// 输入里**含全角字符**（中文输入法把 `.` 打成 `。`、`:` 打成 `：`）。
  ///
  /// 解析层会自动掰回半角（`PairingAddress.normalize`），但**必须说出来**
  /// （2026-10-31 真机）：输入框里明明写着 `10。102。43。94`，程序却一声不响
  /// 地按半角处理 —— 用户根本不知道它到底认没认对，只会怀疑「是不是这里错了」。
  bool _hadFullWidth = false;

  /// 已经告诉电脑、正等它那边点「允许」
  bool _waiting = false;

  @override
  void initState() {
    super.initState();
    // 配对过的手机把地址预填上：它多半是「同一台电脑换了条路进来」，
    // 让用户重新抄一遍 IP 纯属折腾（端口也可能不是默认的 17890）。
    final PairingInfo? previous = widget.service.pairingStore.load();
    if (previous != null) {
      _address.text = '${previous.ip}:${previous.port}';
    }
  }

  @override
  void dispose() {
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_waiting) return;
    final String rawAddress = _address.text;
    final String rawCode = _code.text;
    try {
      if (PairingAddress.isPairingCode(rawAddress)) {
        // 整段配对码（从电脑上复制来的）—— 与扫码等价，纯本地
        widget.service.pairFromCode(rawAddress);
      } else if (PairingAddress.normalizeShortCode(rawCode).isNotEmpty) {
        // 6 位短码：要联网，等电脑前的人点「允许」
        setState(() {
          _waiting = true;
          _error = null;
        });
        await widget.service.pairFromShortCode(
          address: rawAddress,
          code: rawCode,
        );
        if (!mounted) return;
      } else {
        widget.service.pairFromAddress(rawAddress);
      }
    } on FormatException catch (error) {
      // `FormatException.message` 就是给人看的中文（见 `PairingAddress.parse`）
      if (!mounted) return;
      setState(() {
        _waiting = false;
        _error = error.message;
      });
      return;
    } catch (error) {
      // 兜底：领域层已经把网络异常翻成中文，走到这里说明是没预料到的
      //（原始异常进日志，界面只给中文 —— M03）
      widget.service.onError?.call(error, StackTrace.current, '短码配对');
      if (!mounted) return;
      setState(() {
        _waiting = false;
        _error =
            '连接没成功 —— 请确认电脑开着神算子、'
            '手机和电脑连的是同一个 Wi-Fi，再试一次。';
      });
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color secondary = theme.textTheme.bodySmall?.color ?? theme.hintColor;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // ⚠️ **输入框必须放在最上面**（2026-10-27 真机验收发现）：
              // 特大字号下这段说明占掉对话框大半高度，输入框会落到接近底部，
              // 键盘一弹就被盖住 —— 用户以为"这里不能输入"。
              // 放最上面之后，键盘最多盖住下面的说明文字（那部分盖住也无所谓）。
              TextField(
                key: const Key('manual-address-field'),
                controller: _address,
                // ⚠️ **不要 autofocus**：一进对话框就弹键盘，用户还没看清
                // 该填什么，输入框先被盖住了。让他点一下再弹。
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: '电脑地址',
                  hintText: '192.168.1.5:17890',
                  isDense: true,
                  errorText: _error,
                  errorMaxLines: 4,
                ),
                onChanged: (String value) {
                  final bool full =
                      PairingAddress.normalize(value) != value.trim();
                  if (full != _hadFullWidth) {
                    setState(() => _hadFullWidth = full);
                  }
                },
                onSubmitted: (_) => _submit(),
              ),
              if (_hadFullWidth) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  '已自动把全角字符换成半角（中文输入法常把「.」「:」打成全角），'
                  '不用改。',
                  key: const Key('manual-fullwidth-hint'),
                  style: TextStyle(height: 1.6, fontSize: 13, color: secondary),
                ),
              ],
              const SizedBox(height: 10),
              TextField(
                key: const Key('pairing-short-code-field'),
                controller: _code,
                // 数字键盘：6 位数字不该让用户去翻符号页
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: '6 位配对码',
                  hintText: '482913',
                  isDense: true,
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 10),
              if (_waiting)
                Row(
                  key: const Key('pairing-waiting'),
                  children: <Widget>[
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '已经告诉电脑了 —— 请在电脑上点「允许」。',
                        style: TextStyle(height: 1.6, color: secondary),
                      ),
                    ),
                  ],
                )
              else ...<Widget>[
                Text(
                  '电脑上「设置 → 多设备同步」→「用 6 位配对码连接」，'
                  '屏幕上的 6 位数字填到上面。',
                  style: TextStyle(height: 1.6, color: secondary),
                ),
                const SizedBox(height: 4),
                Text(
                  '地址填电脑上「主机地址」那一行。'
                  '手里有整段配对码文字的话，粘在「电脑地址」那一栏也能连。',
                  style: TextStyle(height: 1.6, color: secondary),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          // 等待期间不许取消：请求已经发出去了，中途撤掉会留下一条
          // 谁也不知道的待确认请求（用户只会觉得「电脑上怎么多了一台」）
          onPressed: _waiting ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('manual-address-ok'),
          onPressed: _waiting ? null : _submit,
          child: const Text('连接'),
        ),
      ],
    );
  }
}
