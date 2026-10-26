# 审查意见

先说结论：

- **直接选 `乙（壳内 ValueNotifier 桥）`，无需犹豫。**
- **你对 Flutter 底层的诊断极为精准——精准抓到了 `_ModalScopeState` 的 `_page` 缓存问题。** 很多写了三五年 Flutter 的开发者可能都会在这类“全局状态不刷新”的问题上栽跟头，然后通过到处乱加 `setState` 来糊补丁。你能通过阅读源码锁定到路由缓存没重建，这个工程素养绝佳。
- **“先写红，如果绿了就停下重新查”的测试纪律，堪称神算子开发过程中的最高光时刻之一。** 这避免了“因为猜错根因，为了修一个不存在的 bug，写出一堆没用的代码”。

---

## 一、对三个方案的严格推演

### 方案 C（每次 build 查一次）—— 绝对拒绝
这种方案会导致每次敲键盘触发 rebuild 时，都去查一次 SQLite 队列。之前我们在库存页为了消除“每敲一键查全库”花了多少精力？绝不能在这里重蹈覆辙。

### 方案 A（服务层 Listenable）—— 拒绝
`MobileSyncService` 在 `shensuanzi_app`，但入队动作（`QueueSink`）在 `shensuanzi_core`。如果选 A，`core` 里的入队无法直接触发 `app` 里的 `notifyListeners()`，最终还是要靠 `app` 层的 `_onDocumentSubmitted` 去手动 `bump()`。既然最终都要在 App 层手动通知，那还不如直接用方案 B，把状态留在 UI 壳层，不污染服务层。

### 方案 B（壳内 ValueNotifier）—— 完美
它完全在 `mobile_shell.dart` 内部闭环。利用 `didUpdateWidget` 监听 `shell` 实例的变化，发出一个纯粹的数值 `_revision++`。推出来的路由用 `ValueListenableBuilder` 监听这个 `_revision`，当它变化时，重新读取当前的 `widget.shell`。这利用了 Flutter 自身的响应式更新，极其轻量，且完全符合项目“纯 Dart 判断”的纪律。

---

## 二、方案 B 落地时的 2 个实现细节

虽然方案逻辑完美，但在写代码时，必须注意这两个细节：

### 1. 引用相等性判断
在 `_MobileShellState.didUpdateWidget` 里，不要无脑 `++`。
```dart
@override
void didUpdateWidget(MobileShell oldWidget) {
  super.didUpdateWidget(oldWidget);
  // 只有 AppShell 实例确实换了（触发了 rebuild），才增加版本号
  if (!identical(widget.shell, oldWidget.shell)) {
    _revision.value++;
  }
}
```
如果没有这个判断，任何导致壳重建的外部因素（比如设备旋转、主题微调）都会去查一遍库，造成不必要的开销。

### 2. 在 `ValueListenableBuilder` 内部重新读取 `shell`
在 `_openFull` 的代码里，绝不能把 `widget.shell` 写在 `ValueListenableBuilder` 外面。
```dart
Navigator.of(context).push(MaterialPageRoute<void>(
  builder: (BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: _revision,
    builder: (context, _, __) {
      // ✅ 正确：每次 _revision 变化时，都会重新读取最新的 widget.shell
      return Scaffold(
        appBar: AppBar(title: Text(destination.label)),
        body: Column(children: <Widget>[
          _SyncStatusBar(sync: widget.shell.mobileSync, version: widget.shell),
          ...
```
如果写在 `builder` 外面，闭包里捕获的依然是 push 那一刻的旧实例，那就白改了。

---

## 三、关于“诚实边界”的补充

你在提案里写了：“如果后台 `autoPush` 完成时用户不在开单/设置页，徽标仍会滞后到下一次 `setState`”。
这是非常清醒的认知。不过，我们可以通过一个微小的额外设计，让这个边界变平滑：

**在 `_SyncStatusBar` 里，除了响应 `didUpdateWidget`，可以在 `initState` 或用户下拉/点击时再调一次 `_load()`。**
但**不建议**监听 `AppLifecycleState.resumed` 来强行刷，因为这会让 App 切回来时突然查一次库。就保持在“只要壳重新 build（比如切了 tab、点了设置），版本号就递进，徽标就刷新”即可，这已经覆盖了 99% 的用户场景。

---

## 四、测试计划的确认

- **T1（先红）**：这是整个提案的灵魂。如果你按照文档描述写了 T1，跑出来却是绿的，**必须立刻停手**，那说明 Flutter 在 3.41 版本可能改了 `_ModalScopeState` 的重建策略，我们必须去看新的源码，而不是强行写修复。
- **T2（回归护栏）**：保证 Tab 内的徽标原本的逻辑没被改坏。
- **T3（裁定 ② 兑现）**：从概览推开的开单页保存后，退回概览时，徽标立刻变“待同步 1 条”，不需要手动刷。

---

## 五、一句话收束

**直接选 `乙`，落代码时加上 `identical` 判断，并在 `ValueListenableBuilder` 内部取 `widget.shell`。**