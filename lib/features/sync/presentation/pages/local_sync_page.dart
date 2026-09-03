import 'package:password/core/l10n/l10n.dart';
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
    AppLocalizations.of(context);
    final syncService = ref.watch(localSyncServiceProvider);
    final devicesAsync = ref.watch(syncDevicesProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr.localNetworkSync),
        actions: [
          if (!kIsWeb)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: tr.refreshDevices,
              onPressed: () async {
                if (syncService.isEnabled) {
                  await syncService.stop();
                  await syncService.start();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(tr.searchingForDevices),
                      duration: const Duration(seconds: 1),
                    ),
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
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Icon(Icons.info_outline, color: Colors.blue),
                    const SizedBox(height: 8),
                    Text(
                      tr.webLimitations,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tr.browsersCannotActAsSyncServersEnable,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          if (!kIsWeb) ...[
            _buildSectionTitle(tr.syncSettings),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    title: Text(tr.enableSync),
                    subtitle: Text(tr.allowDiscoveryAndSyncWithDevicesOn),
                    value: syncService.isEnabled,
                    onChanged: (value) async {
                      await syncService.setEnabled(value);
                      setState(() {});
                    },
                  ),
                  ListTile(
                    title: Text(tr.deviceName),
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
                          title: Text(tr.localAddress),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: ips.map((ip) {
                              final port = syncService.port;
                              return SelectableText(
                                '$ip:${port != null ? port.toString() : "8080"}',
                              );
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
              _buildSectionTitle(
                kIsWeb ? tr.connectManually : tr.discoveredDevices,
              ),
              if (!kIsWeb && syncService.isEnabled || kIsWeb)
                TextButton.icon(
                  icon: const Icon(Icons.add_link),
                  label: Text(tr.connectToADevice),
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
                    Icon(
                      Icons.phonelink_setup,
                      size: 64,
                      color: Colors.grey[400],
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: () => _showManualConnectDialog(syncService),
                      icon: const Icon(Icons.add_link),
                      label: Text(tr.enterADeviceAddressToSync),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            devicesAsync.when(
              data: (devices) => devices.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Text(
                          tr.noOtherDevicesFound,
                          style: const TextStyle(color: Colors.grey),
                        ),
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
                            leading: const CircleAvatar(
                              child: Icon(Icons.devices),
                            ),
                            title: Text(device.name),
                            subtitle: Text('${device.host}:${device.port}'),
                            trailing: ElevatedButton(
                              onPressed: () => _syncWithDevice(device),
                              child: Text(tr.syncNow),
                            ),
                          ),
                        );
                      },
                    ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text(tr.error(e.toString()))),
            ),
          const SizedBox(height: 16),
          Text(
            tr.vaultContentIsEncryptedForTransferBetween,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Future<void> _showManualConnectDialog(LocalSyncService syncService) async {
    final hostController = TextEditingController();
    final portController = TextEditingController(
      text: (syncService.port ?? 8080).toString(),
    );

    return showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr.connectToADevice),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: hostController,
              decoration: InputDecoration(
                labelText: tr.ipAddress,
                hintText: tr.eG,
              ),
              keyboardType: TextInputType.number,
              autofocus: true,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: portController,
              decoration: InputDecoration(
                labelText: tr.port,
                hintText: tr.labelDefault,
              ),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tr.cancel),
          ),
          TextButton(
            onPressed: () async {
              final host = hostController.text.trim();
              final port = int.tryParse(portController.text.trim());

              if (host.isEmpty || port == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(tr.enterAValidAddressAndPort)),
                );
                return;
              }

              Navigator.pop(dialogContext);

              // 显示加载中
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (_) =>
                    const Center(child: CircularProgressIndicator()),
              );

              try {
                await syncService.connectToAddress(host, port);
                if (!context.mounted) return;
                Navigator.pop(context); // 关闭加载
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(tr.syncComplete)));
                ref.read(vaultItemsProvider.notifier).refresh();
              } catch (e) {
                if (!context.mounted) return;
                Navigator.pop(context); // 关闭加载
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(tr.connectionFailed(e))));
              }
            },
            child: Text(tr.connect),
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
        title: Text(tr.setDeviceName),
        content: TextField(
          controller: _nameController,
          decoration: InputDecoration(hintText: tr.enterDeviceName),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tr.cancel),
          ),
          TextButton(
            onPressed: () async {
              if (_nameController.text.isNotEmpty) {
                await syncService.setDeviceName(_nameController.text);
                if (!dialogContext.mounted) return;
                setState(() {});
                Navigator.pop(dialogContext);
              }
            },
            child: Text(tr.save),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr.syncComplete)));
        // Refresh vault items
        ref.read(vaultItemsProvider.notifier).refresh();
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Close loading
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr.syncFailed(e)),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
