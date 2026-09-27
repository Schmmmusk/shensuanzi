/// 往来方的**最小建档服务**（开单主路径上的免死锁口子）。
///
/// ## 为什么这一层存在（Z-4 裁定：`docs/reply_review.md` §Z 一）
///
/// 个体工商户最常见的场景之一 —— **老王既供货给你，也从你这里进货**。
/// `parties.roles` 是 JSON 数组，就是为这个设计的。如果客户/供应商两个
/// 选择器各自「新建」而不查重，会造出**两条同名 party**：往来账分流，
/// 对账时分不清哪个是哪个 —— 这是将来最难修的一类数据问题。
///
/// 所以**新建入口的唯一实现在这里**，采购页与销售页共用：
///
/// | 匹配情况 | 行为 |
/// |---|---|
/// | 无同名（启用中） | 新建（roles = [role]） |
/// | 同名且已有该 role | 直接返回已有（**不新建**） |
/// | 同名但没有该 role | **追加 role**（不新建，其余字段不动） |
library;

import '../dao/party_dao.dart';
import '../models/party.dart';
import '../util/ids.dart';

/// `ensureParty` 的结果：除了拿到 party，还要让界面知道**发生了什么**
/// （「已新建」和「已把老王加为你的客户」是两种不同的提示）。
enum PartyMutationAction {
  /// 新建了一条往来方
  created,

  /// 已有同名往来方，本次给它**追加**了一个 role
  roleAppended,

  /// 已有同名且 role 齐全，直接返回（什么都没改）
  existing,
}

/// [PartyService.ensureParty] 的返回值。
class PartyMutation {
  const PartyMutation({required this.party, required this.action});

  final Party party;
  final PartyMutationAction action;
}

/// 往来方最小建档服务。**只管「新建 or 追加 role」这一件事**；
/// 列表 / 编辑 / 对账在完整的往来方页（后续阶段）。
class PartyService {
  PartyService(this._dao);

  final PartyDao _dao;

  /// 按名称取回（启用中的）；同名取**最早建的**（用户的「老朋友」）。
  Party? findByName(String name) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final List<Party> matches = _dao
        .findAll(active: true, limit: 500)
        .where((Party party) => party.name == trimmed)
        .toList();
    if (matches.isEmpty) return null;
    // findAll 按建档顺序返回，取第一条 = 最早建的
    return matches.first;
  }

  /// 「没有就建；有就加 role；role 也齐了就原样返回」。
  ///
  /// - [name] 必填（空或全空格抛 [StateError]，调用方的 UI 先拦）
  /// - [phone] **只在新建时写入**；对已有往来方不做修改（本次没给的
  ///   信息不该抹掉或猜测）
  PartyMutation ensureParty({
    required String name,
    required PartyRole role,
    String? phone,
    int? now,
  }) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw StateError('往来方名称不能为空');
    }
    final int stamp = now ?? DateTime.now().millisecondsSinceEpoch;

    final Party? existing = findByName(trimmed);
    if (existing == null) {
      final Party party = Party(
        id: newId(),
        name: trimmed,
        phone: (phone == null || phone.trim().isEmpty) ? null : phone.trim(),
        roles: <PartyRole>[role],
        createdAt: stamp,
        updatedAt: stamp,
      );
      _dao.insert(party);
      return PartyMutation(party: party, action: PartyMutationAction.created);
    }

    if (existing.roles.contains(role)) {
      return PartyMutation(party: existing, action: PartyMutationAction.existing);
    }

    // 同名但没有这个 role → 追加（保持 roles 去重、顺序稳定）
    final Party merged = Party(
      id: existing.id,
      name: existing.name,
      phone: existing.phone,
      address: existing.address,
      roles: <PartyRole>[...existing.roles, role],
      creditLimit: existing.creditLimit,
      isActive: existing.isActive,
      remark: existing.remark,
      createdAt: existing.createdAt,
      updatedAt: stamp,
      syncVersion: existing.syncVersion + 1,
    );
    _dao.update(merged);
    return PartyMutation(
      party: merged,
      action: PartyMutationAction.roleAppended,
    );
  }
}
