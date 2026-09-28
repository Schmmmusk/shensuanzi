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

import '../dao/ledger_dao.dart' show PartyFlowEntry, PartyLedgerDao;
import '../dao/party_dao.dart';
import '../dao/query_dao.dart';
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
  /// - [phone] / [address] **只在新建时写入**；对已有往来方不做修改
  ///   （本次没给的信息不该抹掉或猜测）
  PartyMutation ensureParty({
    required String name,
    required PartyRole role,
    String? phone,
    String? address,
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
        address:
            (address == null || address.trim().isEmpty) ? null : address.trim(),
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

  /// 往来方页的**完整新建**入口（§AA 遗漏 1：与开单页的应急入口互补）。
  ///
  /// - [roles] 至少一个（新建时定角色；**编辑不改角色**属 v1.1 ——
  ///   改角色会影响余额语义）
  /// - 内部按角色逐个走 [ensureParty]：**同名往来方自动复用并追加角色**，
  ///   与 Z-4「绝不出现两条同名 party」同一保证；[phone]/[address]
  ///   仍只在真正新建时写入
  Party createFull({
    required String name,
    required List<PartyRole> roles,
    String? phone,
    String? address,
    int? now,
  }) {
    if (roles.isEmpty) {
      throw StateError('至少要选一个角色（供应商 / 客户）');
    }
    for (final PartyRole role in roles) {
      ensureParty(
        name: name,
        role: role,
        phone: phone,
        address: address,
        now: now,
      );
    }
    return findByName(name)!;
  }

  /// 编辑**资料**（名称 / 电话 / 地址）。⚠️ 不改角色（会影响余额语义，
  /// §AA 遗漏 1：改角色属 v1.1）；`id` 不存在抛 [StateError]。
  Party updateProfile(
    String id, {
    required String name,
    String? phone,
    String? address,
    int? now,
  }) {
    final Party? existing = _dao.findById(id);
    if (existing == null) {
      throw StateError('往来方不存在或已删除，请刷新后重试');
    }
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw StateError('往来方名称不能为空');
    }
    final int stamp = now ?? DateTime.now().millisecondsSinceEpoch;
    final Party updated = Party(
      id: existing.id,
      name: trimmed,
      phone: (phone == null || phone.trim().isEmpty) ? null : phone.trim(),
      address:
          (address == null || address.trim().isEmpty) ? null : address.trim(),
      roles: existing.roles,
      creditLimit: existing.creditLimit,
      isActive: existing.isActive,
      remark: existing.remark,
      createdAt: existing.createdAt,
      updatedAt: stamp,
      syncVersion: existing.syncVersion + 1,
    );
    _dao.update(updated);
    return updated;
  }

  /// 停用 / 恢复（软删；不影响历史流水）。
  Party setActive(String id, {required bool active, int? now}) {
    final Party? existing = _dao.findById(id);
    if (existing == null) {
      throw StateError('往来方不存在或已删除，请刷新后重试');
    }
    final int stamp = now ?? DateTime.now().millisecondsSinceEpoch;
    final Party updated = Party(
      id: existing.id,
      name: existing.name,
      phone: existing.phone,
      address: existing.address,
      roles: existing.roles,
      creditLimit: existing.creditLimit,
      isActive: active,
      remark: existing.remark,
      createdAt: existing.createdAt,
      updatedAt: stamp,
      syncVersion: existing.syncVersion + 1,
    );
    _dao.update(updated);
    return updated;
  }

  /// 某往来方的**人可读流水**（流水页用，§AA 遗漏 6）。
  List<PartyFlowEntry> flowsOf(String partyId) =>
      PartyLedgerDao(_dao.db).ofParty(partyId);

  /// 列表。默认只看启用中的（[active] 传 `null` 看全部）。
  List<Party> list({bool? active = true}) => _dao.findAll(active: active);

  /// **导出用**：不分页、**默认含停用**（§AF-5）。
  ///
  /// 停用但还欠钱的客户必须在导出里 —— 否则会计对不上这笔应收。
  List<Party> listForExport({PartyRole? role, bool? active}) =>
      _dao.findAllForExport(role: role, active: active);

  /// 全部往来方的余额（正 = 对方欠我，负 = 我欠对方）。
  /// 实现委托 `QueryDao.partyBalances`（从流水算，无余额表）。
  Map<String, int> partyBalances() => QueryDao(_dao.db).partyBalances();
}
