/// CSV 生成 —— **手写，不引依赖**（§AF-1：v1 只做 CSV）。
///
/// 三件事，每一件都有一个「不做就会挨骂」的理由：
///
/// 1. **UTF-8 with BOM**（坑 1）：中文 Windows 的 Excel 打开**纯 UTF-8** 的
///    CSV 会用 GBK 解码 → 中文全乱码。开头三字节 `EF BB BF` 是它认人的唯一标记。
/// 2. **RFC 4180 转义**（坑 2）：商品名里可能有逗号（`娃哈哈,矿泉水`）、
///    地址里可能有换行。不转义的 CSV 是「看起来能用，直到某天打开坏掉」。
/// 3. **公式注入防护**（遗漏 1）：字段以 `= + - @` 开头时前面加一个 `'`。
///    用户真会建一个叫「=赠品」的商品，Excel 会把它当公式 ——
///    轻则 `#NAME?`，重则执行宏。这**不是防攻击，是防误伤**。
///    ⚠️ **纯数字例外**（`-12.34`）：加了引号它就变文本，会计求和会漏数 ——
///    而流水的金额天生带负号。数字字面量本身不是注入向量。
library;

import 'dart:convert';
import 'dart:typed_data';

/// BOM 三字节（`\uFEFF` 的 UTF-8 编码）
const List<int> csvBom = <int>[0xEF, 0xBB, 0xBF];

/// 「看起来就是一个数字」的字段：`12` / `-12.34` / `0.00`
///
/// ⚠️ 与下面的注入防护配套：**数字不该被加前导单引号**。
/// 加了的话 `-12.34` 会变成**文本**，Excel 求和时被跳过 ——
/// 而流水的金额天生带负号（收款单是负数），会计一求和就漏，且看不出来。
/// 数字字面量本身不是注入向量，放行是安全的。
final RegExp _plainNumber = RegExp(r'^-?\d+(\.\d+)?$');

/// 单个字段 → CSV 单元格（注入防护 + RFC 4180 转义）
String csvEscape(String value) {
  String safe = value;
  // 遗漏 1：Excel 会把 `=SUM(...)` 当公式。前导单引号 Excel 会吃掉、显示原值。
  // ⚠️ **纯数字放行**（见 [_plainNumber]）—— 否则负金额变文本、求和漏数
  if (safe.isNotEmpty &&
      '=+-@'.contains(safe[0]) &&
      !_plainNumber.hasMatch(safe)) {
    safe = "'$safe";
  }
  // 坑 2：含分隔符 / 引号 / 换行的字段要整段加引号，内部引号双写
  if (safe.contains(',') ||
      safe.contains('"') ||
      safe.contains('\n') ||
      safe.contains('\r')) {
    return '"${safe.replaceAll('"', '""')}"';
  }
  return safe;
}

/// 一行（不含换行符）
String csvLine(List<String> fields) => fields.map(csvEscape).join(',');

/// 表头 + 行 → **可直接落盘的字节**。
///
/// 调用方**不用管编码**：BOM、UTF-8、行尾全在这里做完（`Uint8List` 而不是
/// `String`，正是为了让「写下 BOM 三字节」这件事有地方可做）。
///
/// - 行尾 `\r\n`：RFC 4180 与 Windows 记事本的一致要求（只写 `\n`
///   的话，记事本会连成一行 —— 用户会以为文件坏了）
/// - 用 `StringBuffer` 而不是 `text += …`：后者在几千行时是 O(n²)（遗漏 7）
///
/// ⚠️ **v1 是「一次成型」**：个体户一年的单据 ≈ 几千行 ≈ 几百 KB，
/// 一次编码没有压力（数据本身也是 DAO 一次查出来的，写的时候再「流式」
/// 省不了内存）。真到几万行再改 — 出口只有这一个函数，换实现不影响调用方。
Uint8List csvBytes(List<String> header, List<List<String>> rows) {
  final StringBuffer buffer = StringBuffer();
  buffer
    ..write(csvLine(header))
    ..write('\r\n');
  for (final List<String> row in rows) {
    buffer
      ..write(csvLine(row))
      ..write('\r\n');
  }
  return Uint8List.fromList(<int>[...csvBom, ...utf8.encode(buffer.toString())]);
}
