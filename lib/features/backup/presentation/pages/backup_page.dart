import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../providers/backup_provider.dart';
import '../../domain/models/backup_history.dart';

final encryptBackupToggleProvider = StateProvider<bool>((ref) => true);

class BackupPage extends ConsumerWidget {
  const BackupPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backupHistory = ref.watch(backupHistoryProvider);
    final config = ref.watch(webDavConfigProvider);
    final shouldEncrypt = ref.watch(encryptBackupToggleProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('数据备份'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/webdav-config'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              elevation: 0,
              color: Colors.blue.withOpacity(0.05),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.cloud_upload, color: Colors.blue),
                        ),
                        const SizedBox(width: 12),
                        const Text(
                          '手动备份',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('使用主密码加密', style: TextStyle(fontWeight: FontWeight.w500)),
                            Text('推荐开启，保护备份文件安全', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                          ],
                        ),
                        Switch(
                          value: shouldEncrypt,
                          onChanged: (v) => ref.read(encryptBackupToggleProvider.notifier).state = v,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: config.isValid 
                          ? () async {
                              try {
                                await ref.read(backupServiceProvider).performBackup(encrypt: shouldEncrypt);
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('备份成功')),
                                  );
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('备份失败: $e'), backgroundColor: Colors.red),
                                  );
                                }
                              }
                            }
                          : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text('立即备份'),
                      ),
                    ),
                    if (!config.isValid)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '请先配置 WebDAV',
                          style: TextStyle(color: Colors.red[300], fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                const Icon(Icons.cloud_done, color: Colors.blue, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'WebDAV备份文件',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            const SizedBox(height: 12),
            backupHistory.when(
              data: (history) => history.isEmpty
                  ? _buildEmptyHistory()
                  : ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: history.length,
                      separatorBuilder: (context, index) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final item = history[index];
                        return _buildHistoryItem(context, ref, item);
                      },
                    ),
              loading: () => const Center(child: Padding(
                padding: EdgeInsets.all(20.0),
                child: CircularProgressIndicator(),
              )),
              error: (err, stack) => Center(child: Text('加载失败: $err')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyHistory() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 40),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Center(
        child: Text(
          '暂无备份历史',
          style: TextStyle(color: Colors.grey[400], fontSize: 16),
        ),
      ),
    );
  }

  Widget _buildHistoryItem(BuildContext context, WidgetRef ref, BackupHistory item) {
    final dateFormat = DateFormat('yyyy-MM-dd HH:mm');
    final sizeStr = (item.size / 1024).toStringAsFixed(1) + ' KB';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: ListTile(
        leading: const Icon(Icons.insert_drive_file_outlined, color: Colors.blue),
        title: Text(item.fileName, style: const TextStyle(fontSize: 14)),
        subtitle: Text('${dateFormat.format(item.createdAt)}  ($sizeStr)', 
          style: TextStyle(fontSize: 12, color: Colors.grey[500])),
        trailing: PopupMenuButton<String>(
          onSelected: (value) async {
            if (value == 'restore') {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('恢复备份'),
                  content: const Text('恢复备份将导入备份中的所有数据，可能会产生重复项。确定继续吗？'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('确定')),
                  ],
                ),
              );
              if (confirmed == true) {
                try {
                  await ref.read(backupServiceProvider).restoreBackup(item);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('恢复成功')));
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('恢复失败: $e'), backgroundColor: Colors.red));
                  }
                }
              }
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'restore', child: Text('恢复此备份')),
          ],
        ),
      ),
    );
  }
}
