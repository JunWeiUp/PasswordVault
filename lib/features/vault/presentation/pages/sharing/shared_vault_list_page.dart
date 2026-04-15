import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/vault_provider.dart';
import '../../../../sync/presentation/providers/sync_provider.dart';
import '../../../../sync/domain/local_sync_service.dart';

class SharedVaultListPage extends ConsumerWidget {
  const SharedVaultListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sharedVaultsAsync = ref.watch(sharedVaultsProvider);
    final joinRequestsAsync = ref.watch(lanJoinRequestsProvider);
    final sentRequestsAsync = ref.watch(sentJoinRequestsProvider);
    final syncService = ref.watch(localSyncServiceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('共享库'),
        actions: [
          IconButton(
            icon: Icon(syncService.isEnabled ? Icons.wifi_tethering : Icons.wifi_tethering_off),
            tooltip: syncService.isEnabled ? '局域网同步已开启' : '局域网同步已关闭',
            onPressed: () => syncService.setEnabled(!syncService.isEnabled),
          ),
          IconButton(
            icon: const Icon(Icons.wifi_find),
            tooltip: '加入局域网共享库',
            onPressed: () => context.push('/sharing/lan-discovery'),
          ),
          IconButton(
            icon: const Icon(Icons.qr_code),
            tooltip: '我的公钥',
            onPressed: () => context.push('/sharing/public-key'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(sharedVaultsProvider);
          ref.invalidate(lanJoinRequestsProvider);
          // 如果开启了同步，顺便重新扫描一下设备
          if (syncService.isEnabled) {
            await syncService.start();
          }
          await Future.delayed(const Duration(milliseconds: 500));
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
          // 局域网申请提醒
          joinRequestsAsync.when(
            data: (requests) {
              if (requests.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
              return SliverToBoxAdapter(
                child: Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.notifications_active, color: Colors.orange, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '收到 ${requests.length} 个加入申请',
                              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orange),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '请进入具体的共享库详情页查看并处理申请。如果是申请加入新库，请点击下方申请项。',
                        style: TextStyle(fontSize: 12, color: Colors.orange),
                      ),
                      const SizedBox(height: 12),
                      ...requests.map((req) => ListTile(
                        dense: true,
                        leading: const CircleAvatar(radius: 12, child: Icon(Icons.person, size: 12)),
                        title: Text(req.deviceName),
                        subtitle: Text(req.vaultName != null ? '申请加入: ${req.vaultName}' : '通用加入申请'),
                        trailing: TextButton(
                          onPressed: () {
                            if (req.vaultId != null) {
                              context.push('/sharing/details/${req.vaultId}');
                            } else {
                              // 如果是通用申请，引导用户去库详情页
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('请进入您想让其加入的共享库详情页进行通过')),
                              );
                            }
                          },
                          child: const Text('去处理'),
                        ),
                      )),
                    ],
                  ),
                ),
              );
            },
            loading: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
            error: (_, __) => const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),

          // 已发送申请的状态提醒
          sentRequestsAsync.when(
            data: (requests) {
              final pendingOrRecentlyApproved = requests.where((r) => 
                r.status == JoinRequestStatus.pending || 
                (r.status == JoinRequestStatus.approved && 
                 DateTime.now().difference(r.timestamp).inMinutes < 60)
              ).toList();

              if (pendingOrRecentlyApproved.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
              
              return SliverToBoxAdapter(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.info_outline, color: Colors.blue, size: 20),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              '已发送的申请',
                              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.clear_all, size: 18, color: Colors.blue),
                            onPressed: () => syncService.clearSentRequests(),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            tooltip: '清除记录',
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ...pendingOrRecentlyApproved.map((req) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('申请加入: ${req.deviceName}'),
                        subtitle: Text(req.vaultName ?? '通用库'),
                        trailing: req.status == JoinRequestStatus.approved 
                          ? const Chip(
                              label: Text('已通过', style: TextStyle(color: Colors.white, fontSize: 10)),
                              backgroundColor: Colors.green,
                              padding: EdgeInsets.zero,
                            )
                          : const Chip(
                              label: Text('申请中', style: TextStyle(color: Colors.white, fontSize: 10)),
                              backgroundColor: Colors.orange,
                              padding: EdgeInsets.zero,
                            ),
                      )),
                    ],
                  ),
                ),
              );
            },
            loading: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
            error: (_, __) => const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),

          // 共享库列表
          sharedVaultsAsync.when(
            data: (vaults) {
              if (vaults.isEmpty) {
                return SliverFillRemaining(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.group_work_outlined, size: 64, color: Colors.grey[400]),
                        const SizedBox(height: 16),
                        Text('暂无共享库', style: TextStyle(color: Colors.grey[600])),
                        const SizedBox(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ElevatedButton.icon(
                              onPressed: () => context.push('/sharing/create'),
                              icon: const Icon(Icons.add),
                              label: const Text('创建共享库'),
                            ),
                            const SizedBox(width: 16),
                            OutlinedButton.icon(
                              onPressed: () => context.push('/sharing/lan-discovery'),
                              icon: const Icon(Icons.wifi_find),
                              label: const Text('加入局域网库'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }

              return SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final vault = vaults[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        child: ListTile(
                          leading: const CircleAvatar(
                            child: Icon(Icons.folder_shared),
                          ),
                          title: Text(vault.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text('创建于 ${vault.createdAt.toString().split('.')[0]}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => context.push('/sharing/details/${vault.id}', extra: vault),
                        ),
                      );
                    },
                    childCount: vaults.length,
                  ),
                ),
              );
            },
            loading: () => const SliverToBoxAdapter(child: Center(child: CircularProgressIndicator())),
            error: (err, stack) => SliverToBoxAdapter(child: Center(child: Text('加载失败: $err'))),
          ),
        ],
      ),
    ),
    floatingActionButton: sharedVaultsAsync.valueOrNull?.isNotEmpty == true
          ? FloatingActionButton(
              onPressed: () => context.push('/sharing/create'),
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}
