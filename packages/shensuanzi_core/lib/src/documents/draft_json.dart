/// 草稿的 JSON 编解码（**纯值对象、无 IO**）。
///
/// 用途：开单页「填一半退出」的自动保存（真实诉求批 ①，2026-10-24，§CV·一百零一）。
///
/// ## 三条设计约束
///
/// 1. **只存用户输入原文**（`quantity` / `unitPrice` / `discountAmount` 本来就是
///    `String`）—— 恢复后**一字不差**，不做任何金额/数量换算，也就不引入二次舍入。
/// 2. **不进主库**：草稿是脏数据，进 `documents` 会污染流水与对账，也不进备份。
/// 3. **`v` 是格式版本**：将来加字段时旧草稿能识别；不认识的版本一律返回 `null`
///    （宁可丢草稿，也不要把不认识的 JSON 硬塞进表单）。
///
/// ## 为什么三份草稿共用一个文件
///
/// `SaleDraft` / `PurchaseDraft` / `DeliveryDraft` 的字段几乎逐字相同
/// （只有送货单没有 `payments`）。三份 `toJson` 抄三遍 = 三处会漂。
/// 这里用一组共享的行/收付款编解码，三份草稿只做「形状适配」。
library;

import 'delivery_draft.dart';
import 'purchase_draft.dart';
import 'sale_draft.dart';

/// 当前草稿格式版本。**加字段时递增**；旧版本仍能读（缺的字段取默认值）。
const int draftJsonVersion = 1;

/// 草稿种类（同时是文件名：`<数据目录>/drafts/<kind>.json`）
enum DraftKind {
  sale('sale'),
  purchase('purchase'),
  delivery('delivery');

  const DraftKind(this.fileName);

  /// 文件名（不含扩展名）
  final String fileName;

  /// 从文件名反解（认不出 ⇒ `null`）
  static DraftKind? tryParse(String name) {
    for (final DraftKind kind in DraftKind.values) {
      if (kind.fileName == name) return kind;
    }
    return null;
  }
}

// ---------------------------------------------------------------- 行 / 收付款

/// 明细行的共享形状（三个 `*LineDraft` 的字段完全一致）。
typedef LineFields = ({
  String productId,
  String productName,
  String quantity,
  String unitPrice,
  String entryUnit,
  String discountAmount,
  String? baseUnit,
  String? packageUnit,
  int? packageSize,
});

Map<String, Object?> _lineToJson(LineFields line) => <String, Object?>{
  'productId': line.productId,
  'productName': line.productName,
  'quantity': line.quantity,
  'unitPrice': line.unitPrice,
  'entryUnit': line.entryUnit,
  'discountAmount': line.discountAmount,
  'baseUnit': line.baseUnit,
  'packageUnit': line.packageUnit,
  'packageSize': line.packageSize,
};

LineFields _saleLine(SaleLineDraft l) => (
  productId: l.productId,
  productName: l.productName,
  quantity: l.quantity,
  unitPrice: l.unitPrice,
  entryUnit: l.entryUnit,
  discountAmount: l.discountAmount,
  baseUnit: l.baseUnit,
  packageUnit: l.packageUnit,
  packageSize: l.packageSize,
);

LineFields _purchaseLine(PurchaseLineDraft l) => (
  productId: l.productId,
  productName: l.productName,
  quantity: l.quantity,
  unitPrice: l.unitPrice,
  entryUnit: l.entryUnit,
  discountAmount: l.discountAmount,
  baseUnit: l.baseUnit,
  packageUnit: l.packageUnit,
  packageSize: l.packageSize,
);

LineFields _deliveryLine(DeliveryLineDraft l) => (
  productId: l.productId,
  productName: l.productName,
  quantity: l.quantity,
  unitPrice: l.unitPrice,
  entryUnit: l.entryUnit,
  discountAmount: l.discountAmount,
  baseUnit: l.baseUnit,
  packageUnit: l.packageUnit,
  packageSize: l.packageSize,
);

LineFields _lineFromJson(Map<String, Object?> json) => (
  productId: _str(json['productId']),
  productName: _str(json['productName']),
  quantity: _str(json['quantity']),
  unitPrice: _str(json['unitPrice']),
  entryUnit: _str(json['entryUnit']),
  discountAmount: _str(json['discountAmount']),
  baseUnit: _strOrNull(json['baseUnit']),
  packageUnit: _strOrNull(json['packageUnit']),
  packageSize: _intOrNull(json['packageSize']),
);

/// 收付款行的共享形状（销售 / 采购有，送货没有）。
typedef PaymentFields = ({String accountId, String accountName, String amount});

Map<String, Object?> _paymentToJson(PaymentFields p) => <String, Object?>{
  'accountId': p.accountId,
  'accountName': p.accountName,
  'amount': p.amount,
};

PaymentFields _paymentFromJson(Map<String, Object?> json) => (
  accountId: _str(json['accountId']),
  accountName: _str(json['accountName']),
  amount: _str(json['amount']),
);

// ---------------------------------------------------------------- 销售

Map<String, Object?> saleDraftToJson(SaleDraft draft) => <String, Object?>{
  'v': draftJsonVersion,
  'kind': DraftKind.sale.fileName,
  'savedAt': DateTime.now().millisecondsSinceEpoch,
  'partyId': draft.partyId,
  'partyName': draft.partyName,
  'date': draft.date,
  'remark': draft.remark,
  'lines': <Object?>[
    for (final SaleLineDraft line in draft.lines) _lineToJson(_saleLine(line)),
  ],
  'payments': <Object?>[
    for (final SalePaymentDraft p in draft.payments)
      _paymentToJson((
        accountId: p.accountId,
        accountName: p.accountName,
        amount: p.amount,
      )),
  ],
};

/// 反序列化。**任何异常 / 版本不认识 ⇒ `null`**（调用方当作「没有草稿」）。
SaleDraft? saleDraftFromJson(Map<String, Object?>? json) {
  if (!_isReadable(json, DraftKind.sale)) return null;
  try {
    return SaleDraft(
      partyId: _strOrNull(json!['partyId']),
      partyName: _str(json['partyName']),
      date: _str(json['date']),
      remark: _str(json['remark']),
      lines: <SaleLineDraft>[
        for (final Map<String, Object?> line in _maps(json['lines']))
          () {
            final LineFields f = _lineFromJson(line);
            return SaleLineDraft(
              productId: f.productId,
              productName: f.productName,
              quantity: f.quantity,
              unitPrice: f.unitPrice,
              entryUnit: f.entryUnit,
              discountAmount: f.discountAmount,
              baseUnit: f.baseUnit,
              packageUnit: f.packageUnit,
              packageSize: f.packageSize,
            );
          }(),
      ],
      payments: <SalePaymentDraft>[
        for (final Map<String, Object?> p in _maps(json['payments']))
          () {
            final PaymentFields f = _paymentFromJson(p);
            return SalePaymentDraft(
              accountId: f.accountId,
              accountName: f.accountName,
              amount: f.amount,
            );
          }(),
      ],
    );
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------- 采购

Map<String, Object?> purchaseDraftToJson(PurchaseDraft draft) =>
    <String, Object?>{
      'v': draftJsonVersion,
      'kind': DraftKind.purchase.fileName,
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'partyId': draft.partyId,
      'partyName': draft.partyName,
      'date': draft.date,
      'remark': draft.remark,
      'lines': <Object?>[
        for (final PurchaseLineDraft line in draft.lines)
          _lineToJson(_purchaseLine(line)),
      ],
      'payments': <Object?>[
        for (final PurchasePaymentDraft p in draft.payments)
          _paymentToJson((
            accountId: p.accountId,
            accountName: p.accountName,
            amount: p.amount,
          )),
      ],
    };

PurchaseDraft? purchaseDraftFromJson(Map<String, Object?>? json) {
  if (!_isReadable(json, DraftKind.purchase)) return null;
  try {
    return PurchaseDraft(
      partyId: _strOrNull(json!['partyId']),
      partyName: _str(json['partyName']),
      date: _str(json['date']),
      remark: _str(json['remark']),
      lines: <PurchaseLineDraft>[
        for (final Map<String, Object?> line in _maps(json['lines']))
          () {
            final LineFields f = _lineFromJson(line);
            return PurchaseLineDraft(
              productId: f.productId,
              productName: f.productName,
              quantity: f.quantity,
              unitPrice: f.unitPrice,
              entryUnit: f.entryUnit,
              discountAmount: f.discountAmount,
              baseUnit: f.baseUnit,
              packageUnit: f.packageUnit,
              packageSize: f.packageSize,
            );
          }(),
      ],
      payments: <PurchasePaymentDraft>[
        for (final Map<String, Object?> p in _maps(json['payments']))
          () {
            final PaymentFields f = _paymentFromJson(p);
            return PurchasePaymentDraft(
              accountId: f.accountId,
              accountName: f.accountName,
              amount: f.amount,
            );
          }(),
      ],
    );
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------- 送货

Map<String, Object?> deliveryDraftToJson(DeliveryDraft draft) =>
    <String, Object?>{
      'v': draftJsonVersion,
      'kind': DraftKind.delivery.fileName,
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'partyId': draft.partyId,
      'partyName': draft.partyName,
      'date': draft.date,
      'remark': draft.remark,
      'lines': <Object?>[
        for (final DeliveryLineDraft line in draft.lines)
          _lineToJson(_deliveryLine(line)),
      ],
    };

DeliveryDraft? deliveryDraftFromJson(Map<String, Object?>? json) {
  if (!_isReadable(json, DraftKind.delivery)) return null;
  try {
    return DeliveryDraft(
      partyId: _strOrNull(json!['partyId']),
      partyName: _str(json['partyName']),
      date: _str(json['date']),
      remark: _str(json['remark']),
      lines: <DeliveryLineDraft>[
        for (final Map<String, Object?> line in _maps(json['lines']))
          () {
            final LineFields f = _lineFromJson(line);
            return DeliveryLineDraft(
              productId: f.productId,
              productName: f.productName,
              quantity: f.quantity,
              unitPrice: f.unitPrice,
              entryUnit: f.entryUnit,
              discountAmount: f.discountAmount,
              baseUnit: f.baseUnit,
              packageUnit: f.packageUnit,
              packageSize: f.packageSize,
            );
          }(),
      ],
    );
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------- 判空 / 工具

/// 草稿里**有没有值得恢复的东西**。
///
/// 页面 `dispose` 时会无脑写一次（用户可能直接关窗口）—— 但如果表单是空的，
/// 写下去只会让下次进页挂一个「发现空草稿」的橙条。所以写之前先问这里。
///
/// 判据：有任意一行**填了东西**（数量 / 单价 / 商品名任一非空），
/// 或者有客户 / 备注 / 收付款。
bool saleDraftHasContent(SaleDraft draft) =>
    draft.partyId != null ||
    draft.remark.trim().isNotEmpty ||
    // ⚠️ 只数**填了金额**的收付款行：开单页默认就有一条「现金」空行
    //（账户已选、金额空），拿 `payments.isNotEmpty` 判会把空表单当成有内容
    draft.payments.any((SalePaymentDraft p) => p.amount.trim().isNotEmpty) ||
    draft.lines.any((SaleLineDraft l) => _lineHasContent(_saleLine(l)));

bool purchaseDraftHasContent(PurchaseDraft draft) =>
    draft.partyId != null ||
    draft.remark.trim().isNotEmpty ||
    // 同销售：默认空行不算内容
    draft.payments.any(
      (PurchasePaymentDraft p) => p.amount.trim().isNotEmpty,
    ) ||
    draft.lines.any((PurchaseLineDraft l) => _lineHasContent(_purchaseLine(l)));

bool deliveryDraftHasContent(DeliveryDraft draft) =>
    draft.partyId != null ||
    draft.remark.trim().isNotEmpty ||
    draft.lines.any((DeliveryLineDraft l) => _lineHasContent(_deliveryLine(l)));

bool _lineHasContent(LineFields l) =>
    l.productId.trim().isNotEmpty ||
    l.productName.trim().isNotEmpty ||
    l.quantity.trim().isNotEmpty ||
    l.unitPrice.trim().isNotEmpty ||
    l.discountAmount.trim().isNotEmpty;

/// 草稿的「保存时间」（橙条文案用：「今天 14:32 的草稿」）。读不到 ⇒ `null`。
DateTime? draftSavedAt(Map<String, Object?>? json) {
  final Object? v = json?['savedAt'];
  if (v is! int) return null;
  return DateTime.fromMillisecondsSinceEpoch(v);
}

bool _isReadable(Map<String, Object?>? json, DraftKind kind) {
  if (json == null) return false;
  if (json['kind'] != kind.fileName) return false;
  final Object? v = json['v'];
  // 不认识的版本 ⇒ 当作没有草稿（宁可丢，也不要把不认识的形状塞进表单）
  return v is int && v >= 1 && v <= draftJsonVersion;
}

/// 读数组字段。`null` = 没这个字段（旧草稿）⇒ 空数组；
/// **类型不对 ⇒ 抛**（由调用方的 catch 变成 `null`）。
///
/// ⚠️ 这里必须严格：把 `lines: "not-a-list"` 当空数组，会给出一个
/// 「有草稿但没有明细」的橙条 —— 用户点恢复后看到一张空单，比丢草稿更困惑。
List<Map<String, Object?>> _maps(Object? raw) {
  if (raw == null) return const <Map<String, Object?>>[];
  if (raw is! List) {
    throw const FormatException('草稿字段不是数组');
  }
  return <Map<String, Object?>>[
    for (final Object? item in raw)
      if (item is Map) Map<String, Object?>.from(item),
  ];
}

String _str(Object? v) => v is String ? v : '';

String? _strOrNull(Object? v) => v is String && v.isNotEmpty ? v : null;

int? _intOrNull(Object? v) => v is int ? v : null;

/// 商品名归一化（草稿恢复与「同名匹配」共用）。
///
/// ⚠️ 与 `ProductDao.findByExactName` 的 SQL 口径**必须一致**：都按 `trim()` 后比。
/// 用户手打的名字常带首尾空格（尤其从别处复制），不 trim 就会匹配不到、
/// 然后多建一个同名商品。
String normalizeProductName(String raw) => raw.trim();
