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

import 'package:flutter/material.dart';
import 'package:shensuanzi_host/shensuanzi_host.dart';

/// 项目统一的**内联提示色**（与开单页/核销页同款：橙色 ≠ 错误红，
/// 因为「可以不拦人的提醒一律内联」—— `ui_principles.md` §1.3）。
const Color _hintAmber = Color(0xFFB45309);

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

  /// 正在等启停结果（按钮与开关都要禁用，否则能连点出好几次启停）
  bool _busy = false;

  /// 跑一次动作并把结果反映到界面。
  ///
  /// ⚠️ `setState` 前必须判 `mounted`：启停是异步的（要绑端口），
  /// 用户完全可能在等待期间切走页面。
  Future<void> _run(Future<HostServiceSnapshot> Function() action) async {
    setState(() => _busy = true);
    final HostServiceSnapshot next = await action();
    if (!mounted) return;
    setState(() {
      _snapshot = next;
      _busy = false;
    });
  }

  Future<void> _toggle(bool on) async {
    await _run(
      () => on ? widget.controller.start() : widget.controller.stop(),
    );
    if (!mounted) return;
    // 打开成功且手里有明文 ⇒ 立刻把码摆出来（§AH 遗漏 4：
    // 「打开开关 → 显示二维码」，这一步不能要求用户再点一次）
    if (on && _snapshot.qrAvailable) await _showQr();
  }

  Future<void> _showQr() async {
    final PairingPayload? payload = widget.controller.pairingPayload;
    if (payload == null) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => _PairingDialog(
        payload: payload,
        addressLine: _snapshot.addressLine,
      ),
    );
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
            Icon(_stateIcon(snapshot.state), size: 18, color: _stateColor(theme, snapshot.state)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(snapshot.headline, style: const TextStyle(height: 1.6)),
            ),
          ],
        ),

        // 副文案：失败时是「怎么办」（领域层给的），运行中是探不到地址的提示
        if (snapshot.detail != null) ...<Widget>[
          const SizedBox(height: 4),
          _hintLine(snapshot.detail!),
        ],

        if (snapshot.isRunning) ...<Widget>[
          const SizedBox(height: 8),
          // 手输兜底（遗漏 4）—— 扫码失败时用户要能照着敲
          if (snapshot.addressLine != null)
            SelectableText(
              snapshot.addressLine!,
              style: TextStyle(height: 1.6, color: secondary),
            ),
          if (traffic != null)
            Text(traffic, style: TextStyle(height: 1.6, color: secondary)),
          const SizedBox(height: 8),

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
      const Icon(Icons.info_outline, color: _hintAmber, size: 18),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          text,
          style: const TextStyle(height: 1.6, color: _hintAmber),
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
class _PairingDialog extends StatelessWidget {
  const _PairingDialog({required this.payload, this.addressLine});

  final PairingPayload payload;
  final String? addressLine;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color secondary = theme.textTheme.bodySmall?.color ?? theme.hintColor;

    return AlertDialog(
      title: const Text('手机扫码连接'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Center(child: _QrView(payload: payload)),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  HostServiceSnapshot.qrHint,
                  style: const TextStyle(height: 1.6),
                ),
              ),
              if (addressLine != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  '扫不出来就手动填这个地址：',
                  style: TextStyle(height: 1.6, color: secondary),
                ),
                const SizedBox(height: 2),
                // 可选中：用户要能复制走
                SelectableText(addressLine!),
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
