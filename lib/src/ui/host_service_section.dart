/// 设置页「多设备同步」区的**内容**（`docs/reply_review.md` §AH · AH-A）。
///
/// ## 与 `settings_page.dart` 的分工
///
/// 那边给**卡片外壳**（`_Section`：标题 + 卡片），这里只给**内容** ——
/// 于是配色、圆角、间距只有一处定义。
///
/// ## 三条裁定落点
///
/// | 项 | 做法 |
/// |---|---|
/// | **遗漏 4** 配对流程 | 开关 → 状态行 → 二维码（含 IP/端口）+ **手输兜底**（可选中复制）+ 底部说明 |
/// | **遗漏 5** 默认关 | 开关由 `HostServiceController` 初始 `stopped` 保证；旁边写明「打开意味着什么」 |
/// | **遗漏 6** 状态可视化 | 四态图标 + 主文案；**失败行必须说「怎么办」**（文案来自纯 Dart 层） |
///
/// ## 一处 **§AH 没写、实现时才发现** 的流程
///
/// `HostIdentity.plaintextToken` **不落盘**（`auth.dart` 刻意的安全设计：只存
/// sha256）。于是**重启应用后画不出二维码** —— 哈希不可逆。
/// 所以状态行有第二形态：`needsReset` ⇒ 不显示「显示二维码」，改显示
/// 「重新生成配对码」（并说清后果：已连过的手机要重新扫码）。
///
/// ## 判断都在纯 Dart 层
///
/// 状态迁移、文案、地址探测都在 `shensuanzi_host` 的 `HostServiceController`。
/// 这里**只做摆放与取值**（铁律）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'app_colors.dart';
// §BL·一：`PairingPayload` 是**同步协议**的 wire 格式，已迁进 `shensuanzi_core`
// —— host 只是 re-export。这里**直接依赖源头**（`import_guard` 会要求）：
// 用 `show` 限定，避免与 host 桶里的同名 re-export 撞在一起。
import 'package:shensuanzi_core/shensuanzi_core.dart' show PairingPayload;
import 'package:shensuanzi_host/shensuanzi_host.dart';

/// 项目统一的**内联提示色**（与开单页/核销页同款：橙色 ≠ 错误红，
/// 因为「可以不拦人的提醒一律内联」—— `ui_principles.md` §1.3）。

/// 多设备同步区的面板内容。
class HostServicePanel extends StatefulWidget {
  const HostServicePanel({super.key, required this.controller});

  /// 启停控制器（**纯 Dart**，应用启动时建好、随库一起活）
  final HostServiceController controller;

  @override
  State<HostServicePanel> createState() => _HostServicePanelState();
}

class _HostServicePanelState extends State<HostServicePanel> {
  late HostServiceSnapshot _snapshot = widget.controller.snapshot;

  @override
  void initState() {
    super.initState();
    // #40⑤：手机推上来的数据**真的落库**后，这一块（「最近连接」/流量）
    // 必须跟着走 —— 否则它永远停在打开设置页那一刻的快照上
    widget.controller.addDataListener(_onHostData);
  }

  @override
  void dispose() {
    widget.controller.removeDataListener(_onHostData);
    super.dispose();
  }

  void _onHostData() {
    if (!mounted) return;
    setState(() => _snapshot = widget.controller.snapshot);
  }

  /// 正在等启停结果（按钮与开关都要禁用，否则能连点出好几次启停）
  /// 当前是否有一个启停动作在飞（按钮据此禁用 + 转圈）
  bool _busy = false;

  /// 上一次操作失败的原因（人话，显示在面板上）。
  ///
  /// ⚠️ 没有它的话，「操作失败」对用户来说就是**转圈 + 按钮变灰** ——
  /// 他不知道发生了什么，也不知道能不能再试（2026-10-31 真机）。
  String? _actionError;

  /// 跑一次动作并把结果反映到界面。
  ///
  /// ⚠️ `setState` 前必须判 `mounted`：启停是异步的（要绑端口），
  /// 用户完全可能在等待期间切走页面。
  Future<void> _run(Future<HostServiceSnapshot> Function() action) async {
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      // ⚠️ **必须有超时**：`action()` 万一永远不完成（端口关不干净 / 磁盘卡住），
      // 没有超时就会一直转圈，用户只能重启软件。
      final HostServiceSnapshot next = await action().timeout(
        const Duration(seconds: 20),
      );
      if (!mounted) return;
      setState(() => _snapshot = next);
    } on TimeoutException {
      if (!mounted) return;
      setState(
        () => _actionError =
            '这一步超过 20 秒还没完成，可能端口被别的程序占着。'
            '请把软件关掉重开，再试一次。',
      );
    } catch (error) {
      // ⚠️ **必须 catch**（2026-10-31 真机）：从前这里没有 try，`action()` 一抛异常
      // `_busy` 就永远停在 true —— 转圈不停、所有按钮变灰、只能重启软件。
      // 具体异常不给用户看（SocketException / FileSystemException 他读不懂），
      // 原始异常走 debugPrint，开发时在控制台能看见。
      debugPrint('[host-service] 操作失败: $error');
      if (!mounted) return;
      setState(
        () => _actionError =
            '刚才那一步没成功（可能是数据文件正被占用）。'
            '请再点一次；一直这样就把软件关掉重开。'
            // 调试版附带原始异常：正式版不给用户看（SocketException /
            // FileSystemException 这些词他读不懂），但排查时没有它就是瞎猜。
            '${kDebugMode ? '\n[调试] ${error.runtimeType}: $error' : ''}',
      );
    } finally {
      // 无论成功、失败、超时，**必须复位** —— 这是「按钮不会永远变灰」的唯一保证
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(bool on) async {
    await _run(() => on ? widget.controller.start() : widget.controller.stop());
    if (!mounted) return;
    // 打开成功且手里有明文 ⇒ 立刻把码摆出来（§AH 遗漏 4：
    // 「打开开关 → 显示二维码」，这一步不能要求用户再点一次）
    if (on && _snapshot.qrAvailable) await _showQr();
  }

  Future<void> _showQr() async {
    final PairingPayload? payload = widget.controller.pairingPayload;
    if (payload == null) {
      // ⚠️ **不能静默 return**（2026-10-31 真机）：用户点了「显示二维码」，
      // 界面毫无反应 —— 他只会以为软件卡死了，然后反复点。
      //
      // 真正的原因只有一个：**令牌只在内存里**（硬盘上只有 hash），
      // 服务没跑起来 / 刚重启过时拿不到明文令牌，就画不出码。
      // 说清楚 + 给一条能走通的路（重新生成），比沉默强一百倍。
      if (!mounted) return;
      final bool? regenerate = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('配对码现在画不出来'),
          content: const SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Text(
                '配对码里的令牌为了安全只存在内存里，没有存到硬盘 —— '
                '所以服务重启过之后，旧的码就画不出来了。\n\n'
                '点「重新生成」会做一张新的码。'
                '已经连过的手机需要重新扫一次（它们原来那张码同时作废）。',
                style: TextStyle(height: 1.6),
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('知道了'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('重新生成'),
            ),
          ],
        ),
      );
      if (regenerate == true && mounted) await _regenerate();
      return;
    }
    await showDialog<void>(
      context: context,
      // D 批：对话框直接吃 controller —— 换地址时码要当场重画（见 `_PairingDialog`）
      builder: (BuildContext context) =>
          _PairingDialog(controller: widget.controller),
    );
    // 对话框里可能换过地址 ⇒ 关掉后把面板刷新一次（地址行要跟着变）
    if (!mounted) return;
    setState(() => _snapshot = widget.controller.snapshot);
  }

  /// 重新生成配对码 —— **会作废所有已配对的手机**，所以先要一次确认。
  Future<void> _regenerate() async {
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('重新生成配对码？'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Text(
                  '${HostServiceSnapshot.resetWarning}。'
                  '如果你只是想把这台电脑上的码再看一眼，不需要重新生成 —— '
                  '重新生成之后原来的码就作废了。',
                  style: const TextStyle(height: 1.6),
                ),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('再想想'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('生成新的'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    await _run(() => widget.controller.resetToken());
    if (!mounted) return;
    if (_snapshot.qrAvailable) await _showQr();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color secondary = theme.textTheme.bodySmall?.color ?? theme.hintColor;
    final HostServiceSnapshot snapshot = _snapshot;
    // 「最近连接：N 分钟前」跟当前时刻有关 —— 每次 build 取一次
    final String? traffic = snapshot.trafficLabel(
      DateTime.now().millisecondsSinceEpoch,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // ---- 开关（默认关；关着时也要说清「打开意味着什么」）----
        Row(
          children: <Widget>[
            const Expanded(child: Text('手机 / 平板连到这里')),
            if (_busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            Switch(
              key: const Key('host-service-switch'),
              value: snapshot.isRunning,
              onChanged: _busy ? null : _toggle,
            ),
          ],
        ),
        Text(
          HostServiceSnapshot.switchHint,
          style: TextStyle(height: 1.6, color: secondary),
        ),
        const SizedBox(height: 12),

        // ---- 状态行（遗漏 6）----
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              _stateIcon(snapshot.state),
              size: 18,
              color: _stateColor(theme, snapshot.state),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                snapshot.headline,
                style: const TextStyle(height: 1.6),
              ),
            ),
          ],
        ),

        // 副文案：失败时是「怎么办」（领域层给的），运行中是探不到地址的提示
        if (snapshot.detail != null) ...<Widget>[
          const SizedBox(height: 4),
          _hintLine(snapshot.detail!),
        ],

        // 上一次操作失败 ⇒ 说清「没成功 + 怎么办」。
        // ⚠️ **必须无条件渲染**（2026-10-31 真机）：放进 `if (isRunning)` 里的话，
        // 失败时服务本来就没跑起来 ⇒ 这行永远不显示，用户只看到转圈和灰按钮。
        if (_actionError != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            _actionError!,
            key: const Key('host-service-action-error'),
            style: TextStyle(height: 1.6, color: theme.colorScheme.error),
          ),
        ],

        if (snapshot.isRunning) ...<Widget>[
          const SizedBox(height: 8),
          // 手输兜底（遗漏 4）—— 扫码失败时用户要能照着敲
          if (snapshot.addressLine != null)
            SelectableText(
              snapshot.addressLine!,
              style: TextStyle(height: 1.6, color: secondary),
            ),
          // D 批：候选不止一个 ⇒ 提前告诉用户「可以换」，别等他连不上再去找
          if (snapshot.hasAddressChoice)
            Text(
              '手机连不上？点「显示二维码」可以换一个网卡地址'
              '（这台电脑有 ${snapshot.addressOptions.length} 个）。',
              style: TextStyle(height: 1.6, color: secondary),
            ),
          if (traffic != null)
            Text(traffic, style: TextStyle(height: 1.6, color: secondary)),
          const SizedBox(height: 8),

          // 令牌只活在内存里 ⇒ 说清「这次能用、下次要重来」
          if (widget.controller.identityPersistFailed) ...<Widget>[
            const SizedBox(height: 6),
            _hintLine(
              '配对码只对这次运行有效 —— 写不进数据文件夹里的 host.json。'
              '手机现在照样能连；下次开机再连时，要重新生成一次码。',
            ),
          ],

          // 能画码 ⇒ 给「显示二维码」；画不出（重启后）⇒ 给「重新生成」+ 说清后果
          if (snapshot.qrAvailable)
            OutlinedButton.icon(
              key: const Key('host-service-show-qr'),
              onPressed: _busy ? null : _showQr,
              icon: const Icon(Icons.qr_code_2),
              label: const Text('显示二维码'),
            )
          else if (snapshot.needsReset) ...<Widget>[
            _hintLine(
              '这台电脑重启过了，之前的配对码显示不出来（为安全起见，'
              '码上的令牌没有存到硬盘）。${HostServiceSnapshot.resetWarning}。',
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('host-service-reset'),
              onPressed: _busy ? null : _regenerate,
              icon: const Icon(Icons.autorenew),
              label: const Text('重新生成配对码'),
            ),
          ],
        ],

        // ---- 失败 ⇒ 给「重试」（遗漏 6：崩了要说怎么办）----
        if (snapshot.state == HostServiceState.failed) ...<Widget>[
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            key: const Key('host-service-retry'),
            onPressed: _busy ? null : () => _run(widget.controller.start),
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ],
    );
  }

  /// 橙色内联提示（与开单页/核销页同一形态）
  Widget _hintLine(String text) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      const Icon(Icons.info_outline, color: AppColors.warningOrange, size: 18),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          text,
          style: const TextStyle(height: 1.6, color: AppColors.warningOrange),
        ),
      ),
    ],
  );

  static IconData _stateIcon(HostServiceState state) {
    switch (state) {
      case HostServiceState.stopped:
        return Icons.power_settings_new;
      case HostServiceState.starting:
        return Icons.hourglass_empty;
      case HostServiceState.running:
        return Icons.check_circle_outline;
      case HostServiceState.failed:
        return Icons.error_outline;
    }
  }

  static Color _stateColor(ThemeData theme, HostServiceState state) {
    switch (state) {
      case HostServiceState.running:
        return theme.colorScheme.primary;
      case HostServiceState.failed:
        return theme.colorScheme.error;
      case HostServiceState.stopped:
      case HostServiceState.starting:
        return theme.textTheme.bodySmall?.color ?? theme.hintColor;
    }
  }
}

/// 扫码对话框。
///
/// ⚠️ 内容必须**可滚动**（项目铁律：缩放调到 200% 时固定高度会把主按钮顶出屏幕）。
///
/// ## 为什么它是 StatefulWidget 且直接吃 controller（2026-10-25 D 批）
///
/// 对话框里多了一块「换一个地址」—— 用户点另一个网卡时，**二维码必须当场重画**。
/// 从前这里收的是 `PairingPayload` 快照，换地址后码不会变
///（「换了但没生效」比不能换更糟）。现在每次 build 都从 controller 现取，
/// 换完 `setState` 即可；`_QrView` 自己的 `didUpdateWidget` 会比对 `uri` 重新编码。
class _PairingDialog extends StatefulWidget {
  const _PairingDialog({required this.controller});

  final HostServiceController controller;

  @override
  State<_PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<_PairingDialog> {
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color secondary = theme.textTheme.bodySmall?.color ?? theme.hintColor;
    final HostServiceSnapshot snapshot = widget.controller.snapshot;
    final PairingPayload? payload = widget.controller.pairingPayload;

    return AlertDialog(
      title: const Text('手机扫码连接'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (payload == null)
                const Text('二维码暂时画不出来，请关掉再打开一次同步服务。')
              else
                Center(child: _QrView(payload: payload)),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  HostServiceSnapshot.qrHint,
                  style: const TextStyle(height: 1.6),
                ),
              ),
              if (snapshot.addressLine != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  '扫不出来就手动填这个地址：',
                  style: TextStyle(height: 1.6, color: secondary),
                ),
                const SizedBox(height: 2),
                // 可选中：用户要能复制走
                SelectableText(snapshot.addressLine!),
              ],
              // 扫码 / 手填地址都不行时，还有最后一条路：把码的文字整段带过去。
              // ⚠️ 没有这个按钮，手机端「粘配对码」那条路**根本拿不到码**
              //（电脑上只显示了 `主机地址：ip:port`，不含身份与令牌）。
              if (payload != null) ...<Widget>[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('host-copy-pairing-code'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: payload.uri));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('配对码已复制 —— 去手机上「手动填地址」整段粘进去'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('复制配对码文字'),
                ),
              ],
              // ---------------------------------------------------- D 批
              // 自动挑的地址可能挑错（穿透工具 / 虚拟网卡 / 公司 VPN）。
              // 挑错时用户看到的只有「手机连不上」，从前**毫无自救手段** ——
              // 这里把候选全摆出来，点一下换一个，码当场重画。
              if (snapshot.hasAddressChoice) ...<Widget>[
                const SizedBox(height: 16),
                Text(
                  '手机连不上？换一个地址试试'
                  '（这台电脑有 ${snapshot.addressOptions.length} 个网卡地址）：',
                  style: const TextStyle(height: 1.6),
                ),
                const SizedBox(height: 4),
                for (final NetAddressOption option in snapshot.addressOptions)
                  _AddressChoice(
                    key: Key('host-address-option-${option.address}'),
                    option: option,
                    selected: option.address == snapshot.address,
                    onTap: () {
                      widget.controller.selectAddress(option.address);
                      setState(() {});
                    },
                  ),
                Text(
                  '换完要用手机重新扫一次上面的码。',
                  style: TextStyle(height: 1.6, color: secondary),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.pop(context),
          // 「收起」而不是「关闭」：**「关闭」暗示「关掉服务」**，
          // 中老年用户看到会以为关掉之后手机就连不上了，于是**不敢点**
          // （`ui_principles` §1.2 的「给用户明确预期」）。
          // 「收起」说的是「码还能再拿出来」—— 事实也如此（令牌仍在内存）。
          child: const Text('收起'),
        ),
      ],
    );
  }
}

/// 候选地址的一行（D 批）：`✓ 10.102.43.94（WLAN）`
///
/// 点整行 = 选中。**必须显示网卡名** —— 只给 IP 的话用户认不出哪个是自己家的 WiFi，
/// 而这一块存在的意义正是「让用户用他自己的知识补上机器的知识」。
class _AddressChoice extends StatelessWidget {
  const _AddressChoice({
    super.key,
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final NetAddressOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        // 44 高：`ui_principles.md` §二 的触控目标下限
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: <Widget>[
            Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              size: 18,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(option.label, style: const TextStyle(height: 1.6)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 二维码画布（**零新依赖** —— 见 `reply_review.md` §BB·三 / §BF）。
///
/// ⚠️ **StatefulWidget 持 `PairingQr` 实例**（§BF·二 补强 1 —— 三处修复的**第二处**）：
/// 编码必须在**这里**发生一次，**不能在 painter 的 `paint()` 里** ——
/// 否则哪怕库层缓存了，每帧 paint 仍会构造新实例、重新编码。
/// 判据：`_QrViewState` 只在 `initState` / `didUpdateWidget` 构造 `PairingQr`；
/// `paint()` **不再构造**。
class _QrView extends StatefulWidget {
  const _QrView({required this.payload});

  /// 边长（≈ 手机屏幕上的常见二维码尺寸）。
  /// **不做成参数**：目前只有对话框一个用点，多一个参数就是多一个没人传的分支。
  static const double size = 240;

  final PairingPayload payload;

  @override
  State<_QrView> createState() => _QrViewState();
}

class _QrViewState extends State<_QrView> {
  late PairingQr _qr = PairingQr(widget.payload);

  @override
  void didUpdateWidget(covariant _QrView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.payload.uri != widget.payload.uri) {
      _qr = PairingQr(widget.payload);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      // §BF·二 补强 1：对话框入场动画期间**不重 paint**（三处修复的第三处）
      child: SizedBox(
        width: _QrView.size,
        height: _QrView.size,
        child: CustomPaint(
          size: const Size.square(_QrView.size),
          painter: PairingQrPainter(_qr),
        ),
      ),
    );
  }
}

/// 自绘二维码。**只画，不算** —— 矩阵已在 [PairingQr] 里缓存好（§BF·二）。
///
/// 为什么不用 `qr_flutter`：见 `reply_review.md` §BB·三 / §BF（治标 + 推翻零依赖裁定）。
///
/// **公开**（而非 `_` 私有）是为了让根层测试能断言 [shouldRepaint]
/// （§BF·二 补强 3：它是「缓存生效」的最后一环）。
class PairingQrPainter extends CustomPainter {
  const PairingQrPainter(this.qr);

  final PairingQr qr;

  /// 四周留白（**模块数**）。规范要求 ≥ 4。
  ///
  /// 少留白的后果特别隐蔽：二维码**看上去完全正常**，相机却对不上焦 /
  /// 截掉定位角 ⇒ 「扫不出来但找不到原因」。宁可多留。
  static const int quietZone = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final int modules = qr.moduleCount + quietZone * 2;
    final double sideless = size.shortestSide;
    final double cell = sideless / modules;
    final double origin = (size.width - cell * modules) / 2;
    final double originY = (size.height - cell * modules) / 2;

    // ⚠️ 二维码**恒为深色画在白色上**，不跟随主题。
    // 扫描器要的是对比度；把码画成浅色背景上的浅色模块 = 扫不出来。
    canvas.drawRect(
      Rect.fromLTWH(origin, originY, cell * modules, cell * modules),
      Paint()..color = const Color(0xFFFFFFFF),
    );

    final Paint dark = Paint()..color = const Color(0xFF000000);
    final List<List<bool>> matrix = qr.matrix;
    for (int row = 0; row < qr.moduleCount; row++) {
      for (int col = 0; col < qr.moduleCount; col++) {
        if (!matrix[row][col]) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            origin + (col + quietZone) * cell,
            originY + (row + quietZone) * cell,
            // +0.5 是**缝补**：相邻模块之间会因抗锯齿留出亚像素白缝，
            // 小尺寸下连成条纹 ⇒ 相机认成「不是模块」。
            cell + 0.5,
            cell + 0.5,
          ),
          dark,
        );
      }
    }
  }

  /// 同一实例 ⇒ **false**（`RepaintBoundary` 才不被 painter 自己绕过，§BF·二 补强 3）；
  /// 实例不同（载荷真的换了，经 `didUpdateWidget` 换入）⇒ true ——
  /// **无条件 false 是错的**：`CustomPaint` 换 painter 时要靠这里决定重画与否，
  /// 一律 false 会把**旧码留在屏上**。
  @override
  bool shouldRepaint(covariant PairingQrPainter oldDelegate) =>
      qr != oldDelegate.qr;
}
