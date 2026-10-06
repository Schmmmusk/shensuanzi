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

import 'dart:collection';

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

  /// 同名往来方**原来是停用的** —— 本次把它恢复使用并确保 role 齐全
  /// （§审查 OBS-05：不恢复就会造出第二条同名、把往来账分流）
  revived,
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

  /// 按名称取回（**含停用**）；同名取最早建的。
  ///
  /// §审查 OBS-05：停用行也可能是「还欠着钱的同名客户」——
  /// 创建前必须能看到它，否则会造出第二条同名把往来账分流。
  Party? findByNameIncludingInactive(String name) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final List<Party> matches = _dao
        .findAll(active: null, limit: 500)
        .where((Party party) => party.name == trimmed)
        .toList();
    if (matches.isEmpty) return null;
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
      // §审查 OBS-05：启用中找不到，但**停用里可能有一个同名的**
      // （可能还欠着钱）—— 恢复它并确保 role，而不是造第二条同名
      final Party? inactive = findByNameIncludingInactive(trimmed);
      if (inactive != null) {
        final List<PartyRole> roles = inactive.roles.contains(role)
            ? inactive.roles
            : <PartyRole>[...inactive.roles, role];
        // Party 没有 copyWith（模型是「显式构造」风格）—— 逐字段重建，
        // 除 roles / isActive / updatedAt 外**原样保留**（含余额、备注）
        final Party revived = Party(
          id: inactive.id,
          name: inactive.name,
          phone: inactive.phone,
          address: inactive.address,
          roles: roles,
          creditLimit: inactive.creditLimit,
          isActive: true,
          remark: inactive.remark,
          createdAt: inactive.createdAt,
          updatedAt: stamp,
          syncVersion: inactive.syncVersion,
        );
        _dao.update(revived);
        return PartyMutation(party: revived, action: PartyMutationAction.revived);
      }
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
  /// - [roles] 至少一个（新建时定角色；之后可用 [updateProfile] **随时改**）
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

  /// 编辑**资料与角色**（名称 / 电话 / 地址 / 角色）。`id` 不存在抛 [StateError]。
  ///
  /// ## §审查 OBS-05 后半：角色为什么可以随时改
  ///
  /// 角色是 party 的**属性**，**不参与任何流水计算** —— 库存 / 资金 / 往来
  /// 全部按 `party_id` 汇总，与 `roles` 无关。所以：
  ///
  /// - **任何时候都能加 / 减角色**，历史交易**不受影响**（流水里存的是
  ///   `party_id`，不是角色快照）。
  /// - 这正是「想给老王加供应商角色」的正路。此前编辑不给碰角色，用户只能
  ///   **停用 + 重建**，而那会造出第二条同名把往来账分流（真隐患）。
  ///
  /// [roles] 传 `null` = **不改角色**（只改资料）；传空列表 = 角色清空
  /// （UI 会给提示：没有角色的往来方不会出现在开单选择器里）。
  Party updateProfile(
    String id, {
    required String name,
    List<PartyRole>? roles,
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
      // 去重且保序（`LinkedHashSet`）—— 重复角色会让界面印出「客户 / 客户」
      roles: roles == null
          ? existing.roles
          : List<PartyRole>.unmodifiable(LinkedHashSet<PartyRole>.of(roles)),
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

  /// 某往来方当前的**余额**（分）：正 = 对方欠我（应收），负 = 我欠对方（应付）。
  ///
  /// §审查 OBS-05 后半：停用前要用它做校验 —— 「还有未结清的账就别停用」
  /// （停用后它不再出现在开单选择器里，但余额仍在，容易变成看不到的账）。
  /// 与 [partyBalances] **同一口径**（都从 `party_ledger` 算，无余额表）。
  int balanceOf(String id) => partyBalances()[id] ?? 0;

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

  /// 往来方页的**显示口径**（§审查 OBS-05 后半）：启用中的全部 +
  /// **停用但余额 ≠ 0** 的。
  ///
  /// ## 为什么停用但有余额的**还要显示**
  ///
  /// 停用只是「不再出现在开单选择器里」，**不是从账上消失**。若把它藏起来，
  /// 那笔应收 / 应付就成了看不见的「幽灵账」—— 用户按往来方页去催款时
  /// **会漏掉它**，对账永远差一笔（v0.1.0 审查点名的真隐患）。
  ///
  /// 用 `findAllForExport`（不分页）而不是 `findAll`（默认 200 条）——
  /// 显示口径不能因为条数上限漏掉欠款的往来方。
  List<Party> listVisible() {
    final Map<String, int> balances = partyBalances();
    return <Party>[
      ..._dao.findAllForExport(active: true),
      ..._dao.findAllForExport(active: false).where(
        (Party party) => (balances[party.id] ?? 0) != 0,
      ),
    ];
  }

  /// **导出用**：不分页、**默认含停用**（§AF-5）。
  ///
  /// 停用但还欠钱的客户必须在导出里 —— 否则会计对不上这笔应收。
  List<Party> listForExport({PartyRole? role, bool? active}) =>
      _dao.findAllForExport(role: role, active: active);

  /// 全部往来方的余额（正 = 对方欠我，负 = 我欠对方）。
  /// 实现委托 `QueryDao.partyBalances`（从流水算，无余额表）。
  Map<String, int> partyBalances() => QueryDao(_dao.db).partyBalances();
}
