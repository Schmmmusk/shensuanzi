/// 启动路径的**场景判定**（§审查「启动路径健壮性」批次）。
///
/// ## 为什么要把判定收成一处
///
/// 在此之前，启动分支散在根 `lib/src/app.dart` 的 `_prepare()` 里，是一串
/// `if`；每加一个边界就往里补一段：
///
/// | 边界 | 来自 |
/// |---|---|
/// | 库损坏 → 停在错误页（**不许**走向导） | §审查 BUG-03 |
/// | 配置读不懂 → 先抢救、救不到才向导 | §审查 OBS-15 |
/// | 首启撞上已有数据 → 要询问 | §审查 OBS-11 前半 |
/// | 同一目录被第二个实例打开 → 拦 | §审查 OBS-14 |
///
/// 顺序稍错就会互相盖住 —— **真机踩过**：库损坏被当成「首次启动」，
/// 选目录向导把 `config.json` 覆盖成默认路径，用户原来的目录再也切不回去。
///
/// 现在判定是**一个纯函数**（`AppBootstrap.startupDecision()`）：输入是
/// 「配置状态 + 位置能否解析 + 库能否打开 + 默认位置有没有数据」，
/// 输出一个 [StartupScenario]。UI 只做 `switch`，**不再自己排队**。
///
/// 判定**不落盘**（留档 / 抢救这些写操作由调用方决定做不做）——
/// 纯函数才能被 `dart test` 钉住。
library;

import 'bootstrap.dart';

/// 本次启动落在哪个场景。
enum StartupScenario {
  /// 配置有路径、目录与标记都在、库也能打开 ⇒ **直接进主界面**。
  openExisting,

  /// 配置有路径，但**库打不开**（损坏 / 被占用 / 版本比代码新）⇒ 错误页。
  ///
  /// 给「重试」（库修好即原样回来）与「换一个文件夹」两条路，
  /// **绝不覆盖配置** —— 覆盖就等于把用户的目录从配置里抹掉。
  brokenDatabase,

  /// 配置有路径、目录与标记都在，但**库文件本身不见了**（2026-10-07 新增，
  /// `docs/reply.md` §6 的 #1）。
  ///
  /// ⚠️ **为什么必须与 [brokenDatabase] 分开**：[brokenDatabase] 是「文件在、
  /// 读不出来」，这一条是「文件没了」。混在一起时走的是 [recoverLocation] →
  /// 向导 → 用户的目录可能被配置抹掉；而若用户重选**同一个**目录，
  /// `Db.open` 见到 `user_version = 0` 会**直接建一套空表** —— 他会在毫无提示
  /// 的情况下对着一本空账簿继续开单（审计报告 #1：误删 `.db` 是常见事故，
  /// 标记文件还在，软件却「照常可用」）。
  ///
  /// 处置：停在错误页，把「从备份恢复」的办法摆出来，并给一个明确的
  /// 「新建一本空账」出口 —— **由人选**，不替他决定（备份恢复 UI 仍是 v1
  /// 有意不做的，所以这里只给指引，不做自动恢复）。
  missingDatabase,

  /// 配置**读不懂**，但从原始文本里**抢救**出了原位置、且它可用
  /// ⇒ 直接进主界面（用户甚至察觉不到出过问题）。
  salvageConfig,

  /// 真·第一次启动（配置文件**不存在**），且默认位置**没有**已有数据
  /// ⇒ 首启向导（可以正常说「欢迎使用」）。
  welcome,

  /// 真·第一次启动，但**默认位置已经有神算子的数据** ⇒ **先询问**
  /// 「继续使用这份数据 / 选一个新位置」（§审查 OBS-11 前半）。
  ///
  /// 为什么必须问：默认位置在同一台机器上每次都是同一个，而「重装软件 /
  /// 解压到别处 / 双击第二份 exe」都会走到这里 —— 直接点「开始使用」
  /// 就挂到同一份数据上了（且用户以为「换了个文件夹就是新数据」）。
  firstRunWithData,

  /// 位置记不住了 / 上次用的文件夹现在用不了 ⇒ 仍走向导，
  /// 但**不说「第一次启动」**，而是说清「数据没丢、原来在哪」。
  recoverLocation,
}

/// 启动判定结果：[scenario] + 这个场景需要的上下文。
class StartupDecision {
  const StartupDecision({
    required this.scenario,
    this.location,
    this.defaultPath,
    this.previousPath,
  });

  /// 有可用位置可开（`openExisting` / `salvageConfig`），
  /// 或**打不开的那个位置**（`brokenDatabase`，错误页要显示它的路径）。
  const StartupDecision.withLocation(
    StartupScenario scenario,
    DataLocation location,
  ) : this(scenario: scenario, location: location);

  const StartupDecision.openExisting(DataLocation location)
    : this.withLocation(StartupScenario.openExisting, location);

  const StartupDecision.brokenDatabase(DataLocation location)
    : this.withLocation(StartupScenario.brokenDatabase, location);

  /// [missingDatabase]：**哪个目录里缺库文件**（提示里要说出路径）。
  const StartupDecision.missingDatabase(DataLocation location)
    : this.withLocation(StartupScenario.missingDatabase, location);

  const StartupDecision.salvageConfig(DataLocation location)
    : this.withLocation(StartupScenario.salvageConfig, location);

  const StartupDecision.welcome() : this(scenario: StartupScenario.welcome);

  /// [firstRunWithData] 的默认位置（**已有数据**的那个目录）。
  const StartupDecision.firstRunWithData(String defaultPath)
    : this(scenario: StartupScenario.firstRunWithData, defaultPath: defaultPath);

  /// [recoverLocation]：能读出「上次用的是哪个路径」就带上（用于文案）；
  /// 配置损坏得读不出路径时为 `null`。
  const StartupDecision.recoverLocation({String? previousPath})
    : this(
        scenario: StartupScenario.recoverLocation,
        previousPath: previousPath,
      );

  final StartupScenario scenario;

  /// 见 [StartupDecision.withLocation]。
  final DataLocation? location;

  /// 见 [StartupDecision.firstRunWithData]。
  final String? defaultPath;

  /// 见 [StartupDecision.recoverLocation]。
  final String? previousPath;

  @override
  String toString() =>
      'StartupDecision(${scenario.name}'
      '${location == null ? '' : ', ${location!.directory}'}'
      '${defaultPath == null ? '' : ', default=$defaultPath'}'
      '${previousPath == null ? '' : ', previous=$previousPath'})';
}
