import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/sync_provider.dart';
import '../../domain/local_sync_service.dart';
import '../../../vault/presentation/providers/vault_provider.dart';

class LocalSyncPage extends ConsumerStatefulWidget {
  const LocalSyncPage({super.key});

  @override
  ConsumerState<LocalSyncPage> createState() => _LocalSyncPageState();
}

class _LocalSyncPageState extends ConsumerState<LocalSyncPage> {
  final _nameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _nameController.text = ref.read(localSyncServiceProvider).deviceName;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final syncService = ref.watch(localSyncServiceProvider);
    final devicesAsync = ref.watch(syncDevicesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('局域网同步'),
        actions: [
          if (!kIsWeb)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '刷新设备列表',
              onPressed: () async {
                if (syncService.isEnabled) {
                  await syncService.stop();
                  await syncService.start();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('正在重新搜索设备...'), duration: Duration(seconds: 1)),
                  );
                }
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (kIsWeb)
            Card(
              color: Colors.blue.withValues(alpha: 0.1),
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  children: [
                    Icon(Icons.info_outline, color: Colors.blue),
                    SizedBox(height: 8),
                    Text(
                      'Web 版提示',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '由于浏览器安全限制，Web 版无法作为同步服务器。请在手机或桌面客户端开启同步，并在此处手动输入其地址进行连接。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          if (!kIsWeb) ...[
            _buildSectionTitle('同步设置'),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('启用同步'),
                    subtitle: const Text('允许在同一局域网下的设备发现并同步数据'),
                    value: syncService.isEnabled,
                    onChanged: (value) async {
                      await syncService.setEnabled(value);
                      setState(() {});
                    },
                  ),
                  ListTile(
                  title: const Text('设备名称'),
                  subtitle: Text(syncService.deviceName),
                  trailing: IconButton(
                    icon: const Icon(Icons.edit),
                    onPressed: () {
                      _showNameDialog(syncService);
                    },
                  ),
                ),
                if (syncService.isEnabled) ...[
                  const Divider(),
                  FutureBuilder<List<String>>(
                    future: syncService.getLocalIps(),
                    builder: (context, snapshot) {
                      final ips = snapshot.data ?? [];
                      if (ips.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      return ListTile(
                        title: const Text('本机地址'),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: ips.map((ip) {
                            final port = syncService.port;
                            return SelectableText('$ip:${port != null ? port.toString() : "8080"}');
                          }).toList(),
                        ),
                        leading: const Icon(Icons.dns),
                      );
                    },
                  ),
                ],
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildSectionTitle(kIsWeb ? '手动连接同步' : '已发现的设备'),
              if (!kIsWeb && syncService.isEnabled || kIsWeb)
                TextButton.icon(
                  icon: const Icon(Icons.add_link),
                  label: const Text('连接到设备'),
                  onPressed: () => _showManualConnectDialog(syncService),
                ),
            ],
          ),
          if (kIsWeb)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Column(
                  children: [
                    Icon(Icons.phonelink_setup, size: 64, color: Colors.grey[400]),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: () => _showManualConnectDialog(syncService),
                      icon: const Icon(Icons.add_link),
                      label: const Text('输入设备地址并同步'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            devicesAsync.when(
            data: (devices) => devices.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Text('未发现其他设备', style: TextStyle(color: Colors.grey)),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: devices.length,
                    itemBuilder: (context, index) {
                      final device = devices[index];
                      return Card(
                        child: ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.devices)),
                          title: Text(device.name),
                          subtitle: Text('${device.host}:${device.port}'),
                          trailing: ElevatedButton(
                            onPressed: () => _syncWithDevice(device),
                            child: const Text('立即同步'),
                          ),
                        ),
                      );
                    },
                  ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('错误: ${e.toString()}')),
          ),
          const SizedBox(height: 16),
          const Text(
            '提示：数据在传输过程中保持加密状态，同步仅在设备间进行，不经过任何云端服务器。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Future<void> _showManualConnectDialog(LocalSyncService syncService) async {
    final hostController = TextEditingController();
    final portController = TextEditingController(text: (syncService.port ?? 8080).toString());

    return showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('连接到设备'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: hostController,
              decoration: const InputDecoration(
                labelText: 'IP 地址',
                hintText: '例如: 192.168.1.5',
              ),
              keyboardType: TextInputType.number,
              autofocus: true,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: portController,
              decoration: const InputDecoration(
                labelText: '端口',
                hintText: '默认: 8080',
              ),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              final host = hostController.text.trim();
              final port = int.tryParse(portController.text.trim());
              
              if (host.isEmpty || port == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入有效的地址和端口')),
                );
                return;
              }

              Navigator.pop(dialogContext);
              
              // 显示加载中
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (_) => const Center(child: CircularProgressIndicator()),
              );

              try {
                await syncService.connectToAddress(host, port);
                if (!context.mounted) return;
                Navigator.pop(context); // 关闭加载
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('同步成功')),
                );
                ref.read(vaultItemsProvider.notifier).refresh();
              } catch (e) {
                if (!context.mounted) return;
                Navigator.pop(context); // 关闭加载
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('连接失败: $e')),
                );
              }
            },
            child: const Text('连接'),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
      ),
    );
  }

  Future<void> _showNameDialog(LocalSyncService syncService) async {
    return showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('设置设备名称'),
        content: TextField(
          controller: _nameController,
          decoration: const InputDecoration(hintText: '输入设备名称'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              if (_nameController.text.isNotEmpty) {
                await syncService.setDeviceName(_nameController.text);
                if (!dialogContext.mounted) return;
                setState(() {});
                Navigator.pop(dialogContext);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _syncWithDevice(SyncDevice device) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      await ref.read(localSyncServiceProvider).syncWithDevice(device);
      if (mounted) {
        Navigator.pop(context); // Close loading
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('同步成功')),
        );
        // Refresh vault items
        ref.read(vaultItemsProvider.notifier).refresh();
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Close loading
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('同步失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }
}
