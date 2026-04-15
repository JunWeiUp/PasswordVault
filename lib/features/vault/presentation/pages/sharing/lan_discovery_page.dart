import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../sync/presentation/providers/sync_provider.dart';
import '../../../../sync/domain/local_sync_service.dart';

class LanDiscoveryPage extends ConsumerStatefulWidget {
  const LanDiscoveryPage({super.key});

  @override
  ConsumerState<LanDiscoveryPage> createState() => _LanDiscoveryPageState();
}

class _LanDiscoveryPageState extends ConsumerState<LanDiscoveryPage> {
  bool _isSearching = false;
  final Set<String> _requestedDeviceIds = {};

  @override
  void initState() {
    super.initState();
    _startSearch();
  }

  Future<void> _startSearch() async {
    setState(() => _isSearching = true);
    final syncService = ref.read(localSyncServiceProvider);
    if (!syncService.isEnabled) {
      await syncService.setEnabled(true);
    } else {
      await syncService.refreshDiscovery();
    }
    // Discovery is started automatically when service starts
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _isSearching = false);
  }

  @override
  Widget build(BuildContext context) {
    final vaultsAsync = ref.watch(discoverableVaultsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('发现局域网共享库'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isSearching ? null : _startSearch,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isSearching)
            const LinearProgressIndicator(),
          Expanded(
            child: vaultsAsync.when(
              data: (vaults) {
                if (vaults.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.search_off_outlined, size: 64, color: Colors.grey[400]),
                        const SizedBox(height: 16),
                        const Text('未发现可用共享库'),
                        const SizedBox(height: 8),
                        const Text('请确保对方已开启“局域网发现”', style: TextStyle(color: Colors.grey, fontSize: 12)),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: vaults.length,
                  padding: const EdgeInsets.all(16),
                  itemBuilder: (context, index) {
                    final vault = vaults[index];
                    final isRequested = _requestedDeviceIds.contains('${vault.device.id}_${vault.id}');

                    return Card(
                      child: ListTile(
                        leading: const CircleAvatar(
                          child: Icon(Icons.folder_shared),
                        ),
                        title: Text(vault.name),
                        subtitle: Text('来自: ${vault.device.name} (${vault.device.host})'),
                        trailing: ElevatedButton(
                          onPressed: isRequested ? null : () => _handleJoin(vault),
                          child: Text(isRequested ? '已申请' : '申请加入'),
                        ),
                      ),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, stack) => Center(child: Text('搜索失败: $err')),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleJoin(DiscoverableVault vault) async {
    try {
      await ref.read(localSyncServiceProvider).sendJoinRequest(
        vault.device,
        vaultId: vault.id,
        vaultName: vault.name,
      );
      setState(() {
        _requestedDeviceIds.add('${vault.device.id}_${vault.id}');
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已向 ${vault.device.name} 发送加入 ${vault.name} 的申请')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('发送申请失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }
}
