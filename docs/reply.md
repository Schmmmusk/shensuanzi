# §V 三 待裁定项：裁定

## 一、问题确认

分析准确。两个后果都是真实的、阻塞性的，而且**互相独立**：

| 后果 | 触发场景 | 为什么必然发生 |
|---|---|---|
| 测试读真实配置 | 「没有配置过 → 弹对话框」 | 开发机上的 `%APPDATA%\神算子\config.json` 已指向 `D:\神算子数据`，`existing()` 返回非空，对话框**永远不会弹** |
| 测试写真实配置 | 任何走「确认」路径的用例 | `bootstrap.prepare()` 会 `configStore.save(...)`，把真实配置**改写成测试的临时目录** |

第二条更危险，因为它**不可逆**——开发者的下次真机启动会直接开到沙箱目录，而沙箱已被清理。这与 `docs/testing.md §K` 的沙箱纪律直接冲突。

## 二、接受建议方案

**`configStore` 可选参数**。理由有三条，第二条最重：

**1. 它是已有的接缝。**

`AppBootstrap.prepare` 早就接受 `configStore` 参数（`configStore = configStore ?? AppConfigStore.forEnvironment(environment)`）。现在只是把它**从 `ShensuanziApp` 往上提一层**，让调用方能传进来。不是发明新概念。

**2. `AppEnvironment` 必须保持真实。**

这一点你拒绝了注入 `AppEnvironment`，但理由可以更具体。测试里 `DataDirectoryPolicy` 要判断的是**「系统盘是哪盘」「D 盘有没有 100G」「这个路径是不是 OneDrive」**——全都来自 `detect()`。

如果连 `AppEnvironment` 也伪造，测试就变成「在假机器上跑假配置」，每个场景都要自己造一套盘符。而真正想测的**不是「机器是不是假的」，是「真实机器 + 假配置」下启动流程的行为**。

**3. 粒度与 `pickDirectory` 对称。**

两者都是「系统交互」，两者都是可选参数，两者都在生产路径上保持默认值。只有一个 `pickDirectory` 时，注入是「一个开洞」；加上 `configStore` 之后，启动流程的**全部外部交互**就被这两个参数收拢了——再多一个都嫌多。

## 三、备选方案不采纳

**注入 `AppEnvironment`**——代价可以量化：

测试必须伪造 `home` / `appData` / `systemLetter` / `disks`（每个盘的字母、类型、剩余空间）。前三个能写死，第四个必须为每个场景单独构造。**造机器的工作量会盖过测启动流程本身。**

**注入 `DataDirectoryService`**——更糟。它把「环境 + 配置 + 策略」捆成一团，测试要关心的是**启动流程**，不是数据目录服务本身（那个已经有 `DataDirectoryService` 的纯 Dart 测试）。

**注入 `AppBootstrap`**——最糟。`AppBootstrap` 是一个**流程**，不是一个依赖。注入它，测的就不是「启动流程对不对」，而是「我传给它的假 bootstrap 会不会按我想的返回」——**测的是 mock**。

## 四、一个落地细节

`configStore` 的默认值是 `null`，`pickDirectory` 的默认值是一个具体函数——**形状不同，但这是一致的**：

| 参数 | 为什么这样 |
|---|---|
| `pickDirectory = pickFolderFromSystem` | 函数引用是编译期常量，能内联为默认值 |
| `configStore` = `null` | 它依赖**运行时环境**（`AppEnvironment.detect()`），无法在编译期构造，所以用 `null` 表示「用默认值」，在 `_prepare` 里用 `??` 解析 |

两者表达的是同一件事：**不传就用生产行为**。写法上：

```dart
const ShensuanziApp({
  super.key,
  this.pickDirectory = pickFolderFromSystem,
  this.configStore,       // null = 用 %APPDATA% 下的默认位置
});

final AppConfigStore? configStore;
```

`_prepare` 里：

```dart
final environment = AppEnvironment.detect();
final store = widget.configStore ?? AppConfigStore.forEnvironment(environment);
```

`const ShensuanziApp()` 一个字不用改。

## 五、五个场景都能测了

注入后，逐条核对：

| # | 场景 | 需要什么 |
|---|---|---|
| 1 | 没有配置过 → 弹对话框 | `configStore` 指向空沙箱；`pickDirectory` 不被调用 |
| 2 | 配置过且目录可用 → 不弹 | 沙箱里预先写好配置 + 带标记的目录 |
| 3 | 选了目录 → 对话框消失，进入主界面 | 沙箱配置 + `pickDirectory` 返回沙箱路径 |
| 4 | 取消（`null`）→ 对话框仍在，不崩 | 沙箱配置 + `pickDirectory` 返回 `null` |
| 5 | 开库失败 → 错误页 | 沙箱里放一个**标记有效但数据库损坏**的目录 |

**第 5 个场景**尤其值得——它抓的是「数据目录能建但库打不开」这条路径，正是 `app.dart` 里那个 `errorPage` 存在的理由。今天没有断言。

## 六、连带文档

| 位置 | 改动 |
|---|---|
| `docs/testing.md` §K | 沙箱纪律补一句：**`ShensuanziApp` 的 `configStore` 必须注入到沙箱**（与 `AppBootstrap` 的已有纪律同源） |
| `docs/reply_review.md` §V 三 | 裁定项标记为已裁定；本节内容迁进 §W 或直接追加在 §V 后 |
| `docs/reply_review.md` §T 四 | 「可选的补救」那句改为「已裁定：注入 `configStore`」 |
| `Agents.md` §四 | 补一行：**启动流程两个注入点**（`pickDirectory` + `configStore`），全部系统交互收拢在这两个参数 |
| `docs/ui_principles.md` §6 | 如涉及测试原则，同步一句「判断在纯 Dart，Flutter 只摆放 + 两个注入点」 |

## 七、判断

**采纳。** 一个可选参数，默认 `null`，在 `_prepare` 里用 `??` 解析。两个注入点（`pickDirectory` + `configStore`）正好覆盖启动流程的全部系统交互，其余全部走真实路径。

**顺带一个观察**：这个缺口暴露了「沙箱纪律已写、但接缝未开」的脱节。`docs/testing.md §K` 早就写了「绝不能碰真实 `%APPDATA%`」，但从 `ShensuanziApp` 外面看**根本没有地方能指到沙箱**。这条纪律因此在 `ShensuanziApp` 这一层**无法被遵守**——只是暂时没人去触碰而已。补上 `configStore` 参数，纪律和代码才对齐。

---
