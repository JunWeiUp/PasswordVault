import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/vault_provider.dart';
import '../../providers/master_key_provider.dart';
import '../../../../sync/presentation/providers/sync_provider.dart';
import '../../../../sync/domain/local_sync_service.dart';
import '../../../domain/models/vault_item.dart';
import '../../widgets/password_item_card.dart';
import '../../widgets/crypto_item_card.dart';
import '../../widgets/secure_note_item_card.dart';
import '../../../../totp/presentation/widgets/totp_item_card.dart';

class SharedVaultDetailsPage extends ConsumerWidget {
  final String vaultId;
  final SharedVault? vault;

  const SharedVaultDetailsPage({
    super.key,
    required this.vaultId,
    this.vault,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vaultAsync = ref.watch(sharedVaultByIdProvider(vaultId));
    final membersAsync = ref.watch(vaultMembersProvider(vaultId));
    final items = ref.watch(vaultItemsBySharedVaultProvider(vaultId));

    final displayVault = vault ?? vaultAsync.valueOrNull;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(displayVault?.name ?? '共享库详情'),
          actions: [
            IconButton(
              icon: const Icon(Icons.person_add_outlined),
              onPressed: () => context.push('/sharing/add-member/$vaultId'),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '项目', icon: Icon(Icons.inventory_2_outlined)),
              Tab(text: '成员', icon: Icon(Icons.people_outline)),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // 项目选项卡
            _buildItemsTab(context, ref, items),
            // 成员选项卡
            membersAsync.when(
              data: (members) => _buildMembersTab(context, ref, members),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, stack) => Center(child: Text('加载失败: $err')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItemsTab(BuildContext context, WidgetRef ref, List<VaultItem> items) {
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inventory_2_outlined, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('该共享库暂无项目', style: TextStyle(color: Colors.grey[600])),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                // 默认跳转到添加账号，并预设共享库 ID
                context.push('/add-account', extra: VaultItem(
                  id: '',
                  type: VaultItemType.password,
                  title: '',
                  username: '',
                  sharedVaultId: vaultId,
                ));
              },
              icon: const Icon(Icons.add),
              label: const Text('添加项目'),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: items.length,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemBuilder: (context, index) {
        final item = items[index];
        switch (item.type) {
          case VaultItemType.totp:
            return TotpItemCard(item: item);
          case VaultItemType.password:
            return PasswordItemCard(item: item);
          case VaultItemType.crypto:
            return CryptoItemCard(item: item);
          case VaultItemType.secureNote:
            return SecureNoteItemCard(item: item);
        }
      },
    );
  }

  Widget _buildMembersTab(BuildContext context, WidgetRef ref, List<SharedMember> members) {
    final joinRequestsAsync = ref.watch(lanJoinRequestsProvider);

    return Column(
      children: [
        _buildVaultHeader(context, ref, members),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: [
              // 待处理申请
              joinRequestsAsync.when(
                data: (requests) {
                  final vaultRequests = requests.where((r) => r.vaultId == vaultId || r.vaultId == null).toList();
                  if (vaultRequests.isEmpty) return const SizedBox.shrink();

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            const Icon(Icons.notifications_active_outlined, size: 20, color: Colors.orange),
                            const SizedBox(width: 8),
                            Text(
                              '待处理加入申请 (${vaultRequests.length})',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.orange),
                            ),
                          ],
                        ),
                      ),
                      ...vaultRequests.map((req) => ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: Colors.orange,
                          child: Icon(Icons.person_add, color: Colors.white, size: 20),
                        ),
                        title: Text(req.deviceName),
                        subtitle: Text(req.vaultId == null ? '申请加入任何库' : '申请加入此库'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.check, color: Colors.green),
                              onPressed: () => _handleApproveRequest(context, ref, req),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, color: Colors.red),
                              onPressed: () => ref.read(localSyncServiceProvider).rejectJoinRequest(req),
                            ),
                          ],
                        ),
                      )),
                      const Divider(),
                    ],
                  );
                },
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
              ),

              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(Icons.people_outline, size: 20, color: Colors.grey),
                    const SizedBox(width: 8),
                    Text(
                      '成员 (${members.length})',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ],
                ),
              ),
              ...members.map((member) => ListTile(
                leading: CircleAvatar(
                  backgroundColor: _getRoleColor(member.role).withOpacity(0.1),
                  child: Icon(_getRoleIcon(member.role), size: 20, color: _getRoleColor(member.role)),
                ),
                title: Text(member.name ?? '未知用户'),
                subtitle: Text(
                  member.userPublicKey.substring(0, 12) + '...',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: _getRoleColor(member.role).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _getRoleColor(member.role).withOpacity(0.3)),
                      ),
                      child: Text(
                        _getRoleName(member.role),
                        style: TextStyle(
                          color: _getRoleColor(member.role),
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (member.role != SharedMemberRole.owner)
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert, size: 20),
                        onSelected: (value) async {
                          if (value == 'remove') {
                            _handleRemoveMember(context, ref, member);
                          } else if (value == 'role_editor') {
                            _handleUpdateRole(context, ref, member, SharedMemberRole.editor);
                          } else if (value == 'role_viewer') {
                            _handleUpdateRole(context, ref, member, SharedMemberRole.viewer);
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'role_editor',
                            child: Text('设为可编辑'),
                          ),
                          const PopupMenuItem(
                            value: 'role_viewer',
                            child: Text('设为仅查看'),
                          ),
                          const PopupMenuDivider(),
                          const PopupMenuItem(
                            value: 'remove',
                            child: Text('移除成员', style: TextStyle(color: Colors.red)),
                          ),
                        ],
                      ),
                  ],
                ),
              )),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _handleApproveRequest(BuildContext context, WidgetRef ref, LanJoinRequest request) async {
    try {
      await ref.read(localSyncServiceProvider).approveJoinRequest(request, vaultId, vault?.name ?? '共享库');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已通过 ${request.deviceName} 的加入申请')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('通过申请失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _handleRemoveMember(BuildContext context, WidgetRef ref, SharedMember member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认移除'),
        content: Text('确定要移除成员 "${member.name ?? '未知用户'}" 吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('移除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final repository = ref.read(vaultRepositoryProvider);
        final userKeyPair = await ref.read(userKeyPairProvider.future);
        if (userKeyPair == null) return;

        await repository.removeMemberFromSharedVault(
          vaultId: vaultId,
          memberId: member.id,
          currentUserKeyPair: userKeyPair,
        );
        ref.invalidate(vaultMembersProvider(vaultId));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('成员已移除')));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('移除失败: $e')));
        }
      }
    }
  }

  Future<void> _handleUpdateRole(BuildContext context, WidgetRef ref, SharedMember member, SharedMemberRole newRole) async {
    try {
      final repository = ref.read(vaultRepositoryProvider);
      final userKeyPair = await ref.read(userKeyPairProvider.future);
      if (userKeyPair == null) return;

      await repository.updateMemberRole(
        vaultId: vaultId,
        memberId: member.id,
        newRole: newRole,
        currentUserKeyPair: userKeyPair,
      );
      ref.invalidate(vaultMembersProvider(vaultId));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('权限已更新')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('更新失败: $e')));
      }
    }
  }

  Widget _buildVaultHeader(BuildContext context, WidgetRef ref, List<SharedMember> members) {
    return Container(
      padding: const EdgeInsets.all(24),
      color: Theme.of(context).primaryColor.withOpacity(0.05),
      child: Column(
        children: [
          const CircleAvatar(
            radius: 32,
            child: Icon(Icons.folder_shared, size: 32),
          ),
          const SizedBox(height: 16),
          Text(
            vault?.name ?? '共享库',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'ID: $vaultId',
            style: TextStyle(color: Colors.grey[600], fontSize: 12, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildHeaderAction(
                context,
                icon: Icons.list_alt,
                label: '查看项',
                onTap: () {
                  context.go('/', extra: {'filterVaultId': vaultId});
                },
              ),
              _buildHeaderAction(
                context,
                icon: Icons.refresh,
                label: '轮转密钥',
                onTap: () => _handleRotateKey(context, ref),
              ),
              _buildHeaderAction(
                context,
                icon: Icons.settings_outlined,
                label: '删除',
                onTap: () {
                  _handleDeleteVault(context, ref);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _handleRotateKey(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('轮转共享库密钥'),
        content: const Text('密钥轮转将生成新的加密密钥，并重新加密库中所有的密码项。此操作可确保已移除的成员无法访问新项，但如果库中项较多，可能需要一点时间。确定要继续吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      // 显示进度对话框
      if (!context.mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在轮转密钥并重新加密项...'),
                ],
              ),
            ),
          ),
        ),
      );

      try {
        final repository = ref.read(vaultRepositoryProvider);
        
        // 确保密钥对已生成
        await ref.read(masterPasswordProvider.notifier).ensureUserKeyPair();
        
        final userKeyPair = await ref.read(userKeyPairProvider.future);
        if (userKeyPair == null) throw Exception('您的密钥对尚未就绪');

        await repository.rotateSharedVaultKey(
          vaultId: vaultId,
          currentUserKeyPair: userKeyPair,
        );

        if (context.mounted) {
          Navigator.pop(context); // 关闭进度对话框
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('密钥轮转成功')));
        }
      } catch (e) {
        if (context.mounted) {
          Navigator.pop(context); // 关闭进度对话框
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('轮转失败: $e'), backgroundColor: Colors.red));
        }
      }
    }
  }

  Future<void> _handleDeleteVault(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除共享库'),
        content: const Text('确定要删除这个共享库吗？此操作不可撤销，库中的成员将失去访问权限。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final repository = ref.read(vaultRepositoryProvider);
        
        // 确保密钥对已生成
        await ref.read(masterPasswordProvider.notifier).ensureUserKeyPair();
        
        final userKeyPair = await ref.read(userKeyPairProvider.future);
        if (userKeyPair == null) return;

        await repository.deleteSharedVault(
          vaultId: vaultId,
          currentUserKeyPair: userKeyPair,
        );
        ref.invalidate(sharedVaultsProvider);
        if (context.mounted) {
          context.pop(); // 返回列表页
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('共享库已删除')));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败: $e')));
        }
      }
    }
  }

  Widget _buildHeaderAction(BuildContext context, {required IconData icon, required String label, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            Icon(icon, color: Theme.of(context).primaryColor),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: Theme.of(context).primaryColor, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  String _getRoleName(SharedMemberRole role) {
    switch (role) {
      case SharedMemberRole.owner:
        return '管理员';
      case SharedMemberRole.editor:
        return '可编辑';
      case SharedMemberRole.viewer:
        return '仅查看';
    }
  }

  IconData _getRoleIcon(SharedMemberRole role) {
    switch (role) {
      case SharedMemberRole.owner:
        return Icons.admin_panel_settings;
      case SharedMemberRole.editor:
        return Icons.edit;
      case SharedMemberRole.viewer:
        return Icons.visibility;
    }
  }

  Color _getRoleColor(SharedMemberRole role) {
    switch (role) {
      case SharedMemberRole.owner:
        return Colors.amber[800]!;
      case SharedMemberRole.editor:
        return Colors.blue[600]!;
      case SharedMemberRole.viewer:
        return Colors.grey[600]!;
    }
  }
}
