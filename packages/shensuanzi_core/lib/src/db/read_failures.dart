/// 读路径的**坏数据兜底**（#42 甲 · L1 / L2 / L4，2026-10-14 裁定）。
///
/// ## 起因（真实缺陷）
///
/// `parties.roles` 里出现一个库外值（S9 验收用 `tool/seed_test_data.py --inject`
/// 注入 `"  　\t  "`）⇒ `PartyRole.fromWire` 抛（`orElse: throw`）⇒ `Party.fromRow`
/// → `PartyDao._select` → **页面 `build`** ⇒ build 失败 ⇒ `ErrorWidget`
/// （release 里是**灰块**）⇒ **整页不可用**。
///
/// ⚠️ **触发源不止注入**：手工改库 · **恢复旧备份** · **主机比客户端新**（新版本加了枚举值）
/// · 同步来的新值。⇒ 这不是防御性编程，是**必现**修复。
///
/// ## 分层（裁定 §二）
///
/// | 层 | 做什么 | 落点 |
/// |---|---|---|
/// | **L2 枚举降级** | 未知枚举值不再抛 ⇒ `fromWireOrNull()` 返回 `null` | 各枚举 + 各 `fromRow` |
/// | **L1 逐行保护** | 单行解码失败 ⇒ **跳过该行 + 记录**，不整页失败 | 本文件的 [decodeRows] + 各 DAO |
/// | **L4 不静默** | 计数外传 ⇒ UI 显示「有 N 条记录暂时显示不全」 | [ReadFailureLog] + [readFailureNotice] |
/// | L3 UI 错误边界 | `ErrorWidget.builder` 兜底（治**别的**未知抛穿） | Flutter 层（次批） |
///
/// ## 两种处置，由**解码点**决定（不是一刀切）
///
/// | 处置 | 手段 | 用在 |
/// |---|---|---|
/// | **兜底保留该行** | 取一个安全默认值 + `failures?.record(...)` | `Account.type` → `other` · `Document.status` → `confirmed` · `PartyRole` → 丢角色保行 |
/// | **跳过该行** | 抛 [RowDecodeException]，由 [decodeRows] 捕获 | `Document.doc_type`（类型决定一切，猜错比看不见更坏）· 队列的两个枚举 |
///
/// ⚠️ **两种都必须记录** ⇒ 否则就是**静默丢数据**（裁定：L4 是 L1 的前提）。
///
/// ## 🔐 日志纪律（与 `AppLog` 的「绝不记经营数据」一致）
///
/// - **枚举类失败**：记 `table` + `column` + **原值**。原值是**枚举 wire 值**
///   （`"supplier"` 这类固定字母表），**不是经营数据** —— 记它才能区分
///   「用户数据真坏了」与「我们自己枚举拼错了」（裁定 §二·④）。
/// - **其它失败**：只记 `table` + `column` + **错误类型**，**绝不记值**
///   （值可能是客户名 / 金额）。
library;

/// 一条读失败记录。
class ReadFailure {
  const ReadFailure({
    required this.table,
    required this.column,
    required this.reason,
    this.value,
    this.rowId,
  });

  /// 表名（如 `parties`）。**不是经营数据**。
  final String table;

  /// 列名；空串 = 无法定位到列（整行级失败）。
  final String column;

  /// 为什么读不出来（人可读的短句）。
  final String reason;

  /// **原值**：**只用于枚举类失败**（枚举 wire 值不是经营数据）。
  /// 其它失败一律 `null` —— 见文件头的日志纪律。
  final String? value;

  /// **行标识**（通常是主键 `id`）；`null` = 那一行/那个视图没带 id 列。
  final String? rowId;

  /// 去重键 = **表 + 行 + 列**（同一行的同一列反复读只算一条）。
  String get key => '$table|${rowId ?? '-'}|$column';

  /// 日志行（进 `AppLog`；**不进 UI**）。
  String get logLine {
    final String where = column.isEmpty ? table : '$table.$column';
    final String at = rowId == null ? '' : ' id=$rowId';
    final String shown = value == null ? '' : '，值=`$value`';
    return '读不出：$where$at（$reason）$shown';
  }

  @override
  String toString() => logLine;
}

/// 读失败的**去重计数**（L4 的计数通道）。
///
/// ## 生命周期与复位语义（裁定 §二·③ —— 必须写清）
///
/// | 问题 | 答案 |
/// |---|---|
/// | 每次查询后复位？ | **不**。累计到 [clear] |
/// | 会不会重复累加？ | **不会**：按 `表 + 行 + 列` 去重（同一行每次重读只算一条）⇒ N 不随重绘增长 |
/// | 谁复位？ | [clear]，**UI 在用户点「知道了」时调用**（不是每次 `build`） |
/// | 复位后坏行还在，会不会又冒出来？ | **不会**：[clear] 把当前这些键记进**已告知**集合 ⇒ **同一批坏行不再重复提醒**；而**新出现**的坏行（另一个 id / 另一列）照常提醒 |
/// | 跨启动？ | 进程退出即丢，**不落库**（运行期诊断信息，不是业务数据） |
/// | 并发？ | 多个 DAO 同时读只是往同一张表里写，**不会互相覆盖** |
///
/// ⚠️ 去重是**跑出来才发现的**：第一版是「事件计数」，`dart run tool/selfcheck.dart`
/// 立刻红 —— 同一张单据被 `listDocuments` 里的多个子查询各解一次，
/// N 会随查询次数（以及页面重绘）不断变大，那个数字就**没法看了**。
class ReadFailureLog {
  final Map<String, ReadFailure> _active = <String, ReadFailure>{};

  /// 用户已被告知的键 —— [clear] 之后同一批坏行**不再提醒**（但新坏行会）。
  final Set<String> _acknowledged = <String>{};

  /// [withRow] 期间的当前行上下文。
  String? _rowId;

  /// 累计条数（UI 的「N」）。
  int get count => _active.length;

  bool get isEmpty => _active.isEmpty;

  /// 只读快照（日志出口用）。
  List<ReadFailure> get items => List<ReadFailure>.unmodifiable(_active.values);

  /// 变化通知（[record] / [clear] 之后触发一次）。
  ///
  /// ⚠️ **不引 Flutter 的 `Listenable`** —— core 是**纯 Dart**（`Listenable` 在
  /// `flutter/foundation` 里，引进来 `dart test` 就跑不了了）。所以这里是一个
  /// 极小的回调表，语义与 `ChangeNotifier.addListener` 对齐。
  ///
  /// ⚠️ **监听回调必须自己推迟到帧末再 `setState`**：页面可能**在 `build` 里读库**
  /// （#42 的原始异常就是这么抛进 `build` 的）⇒ 那时 [record] 会在别人的 build 期间
  /// 触发通知，直接 `setState` 会被框架判错。见 `lib/src/ui/read_failure_banner.dart`。
  final List<void Function()> _listeners = <void Function()>[];

  void addListener(void Function() listener) {
    if (!_listeners.contains(listener)) _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void _notify() {
    for (final void Function() listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  /// 在「当前行」上下文里跑 [body] —— 期间 [record] 出来的记录会带上行标识。
  ///
  /// 为什么用上下文而不是层层传参：**兜底的记录点在 `fromRow` 内部**
  /// （它只知道「哪一列」，不知道「哪一行」，更不知道表名），
  /// 而这两样 [decodeRows] 都知道。传参会污染 4 个模型的解码签名，
  /// 上下文只在**一层**（[decodeRows]）设置，调用方一行不用改。
  T withRow<T>({required String rowId, required T Function() body}) {
    final String? previous = _rowId;
    _rowId = rowId;
    try {
      return body();
    } finally {
      _rowId = previous;
    }
  }

  /// 记一条。**永不抛**（记录失败不能拖垮读路径）。
  ///
  /// 去重键 = `表 + 行 + 列`；已在**已告知**集合里的直接丢弃。
  ///
  /// [rowId] 缺省用 [withRow] 的上下文；⚠️ **异常路径必须显式传**
  /// —— `withRow` 的 `finally` 已经复位了上下文（这条路踩过一次，selfcheck 抓到的）。
  void record({
    required String table,
    required String column,
    required String reason,
    String? value,
    String? rowId,
  }) {
    final String? row = rowId ?? _rowId;
    final String key = '$table|${row ?? '-'}|$column';
    if (_acknowledged.contains(key)) return;
    final int before = _active.length;
    _active[key] = ReadFailure(
      table: table,
      column: column,
      reason: reason,
      value: value,
      rowId: row,
    );
    // 去重后没变 ⇒ 不惊动 UI（否则同一批坏行每读一次都刷一次提示条）
    if (_active.length != before) _notify();
  }

  /// 用户已被告知 ⇒ 清空当前计数，并**记住这批键不再提醒**
  /// （新出现的坏行照常提醒）。
  void clear() {
    if (_active.isEmpty) return;
    _acknowledged.addAll(_active.keys);
    _active.clear();
    _notify();
  }
}

/// 「这一行读不出来」的**信号**：由解码点抛出，由 [decodeRows] 捕获并跳过该行。
///
/// 为什么用异常而不是返回值：解码点是**纯函数式的 `fromRow`**
/// （不能为了一个字段把整个签名改成结果对象 —— 那要动 ~30 处调用点）。
/// 异常在这里只走**一层**（`decodeRows` 立刻捕获），不会抛穿到页面。
class RowDecodeException implements Exception {
  const RowDecodeException({
    required this.column,
    required this.reason,
    this.value,
  });

  /// 出问题的列（空串 = 整行级）。
  final String column;

  final String reason;

  /// 枚举类失败带原值；其它为 `null`（见文件头日志纪律）。
  final String? value;

  @override
  String toString() =>
      'RowDecodeException($column: $reason${value == null ? '' : '，值=`$value`'})';
}

/// **逐行保护**：把 [rows] 逐行交给 [decode]，**单行失败只跳过那一行**
/// （记进 [failures]），不整页失败。
///
/// ⚠️ **兜底 catch 是刻意的**：除了 [RowDecodeException]，
/// 任何**其它**异常也不能让页面变灰（#42 的原始症状）。
/// 代价 = 会吞掉「本该发现的 bug」，所以**必须记进日志**（只记错误类型，不记值）——
/// 记了就不是静默。
List<T> decodeRows<T>(
  Iterable<Map<String, Object?>> rows,
  T Function(Map<String, Object?> row) decode, {
  required String table,
  required ReadFailureLog failures,
}) {
  final List<T> out = <T>[];
  for (final Map<String, Object?> row in rows) {
    final String rowId = rowIdentity(row);
    try {
      failures.withRow(rowId: rowId, body: () => out.add(decode(row)));
    } on RowDecodeException catch (error) {
      failures.record(
        table: table,
        column: error.column,
        reason: error.reason,
        value: error.value,
        rowId: rowId, // ⚠️ 显式传：withRow 的 finally 已复位上下文
      );
    } catch (error) {
      // 见上：只记**类型**，不记值（值可能是经营数据）
      failures.record(
        table: table,
        column: '',
        reason: '无法解析（${error.runtimeType}）',
        rowId: rowId,
      );
    }
  }
  return out;
}

/// 行标识：优先 `id`，其次 JOIN 视图常见的 `doc_id`；都没有 ⇒ `'-'`
/// （那种表的同列重复坏行会并成一条 —— 宁可少算，也不能让 N 随重绘长大）。
String rowIdentity(Map<String, Object?> row) {
  for (final String column in <String>['id', 'doc_id']) {
    final Object? value = row[column];
    if (value is String && value.isNotEmpty) return value;
  }
  return '-';
}

// ---------------------------------------------------------------- 用户可见文案
//
// **单一出处**：UI 只取值、不造句（`ui_principles.md` §五）。
// 用户可见文本三条通道里，这属「② 业务拒绝 ⇒ 写「怎么办」」——
// 用户**能做点什么**（恢复备份），所以第二句必须给动作。

/// 提示条主句（裁定 §二·接线 3 的定稿措辞）。
String readFailureNotice(int count) => '有 $count 条记录暂时显示不全。';

/// 可能的原因 —— **不给用户看表名列名**（禁止开发术语进用户文案）。
const String readFailureCause = '可能是一份旧备份或手工改过的数据。';

/// 「怎么办」（设置页那一页的正文）。
const String readFailureAdvice =
    '从「设置」里的「备份与恢复」恢复一份好的备份，再打开看看；'
    '仍然不行请联系支持。细节已经写进日志文件。';
