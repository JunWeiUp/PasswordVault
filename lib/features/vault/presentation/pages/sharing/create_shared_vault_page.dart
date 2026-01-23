import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/vault_provider.dart';
import '../../providers/master_key_provider.dart';

class CreateSharedVaultPage extends ConsumerStatefulWidget {
  const CreateSharedVaultPage({super.key});

  @override
  ConsumerState<CreateSharedVaultPage> createState() => _CreateSharedVaultPageState();
}

class _CreateSharedVaultPageState extends ConsumerState<CreateSharedVaultPage> {
  final _nameController = TextEditingController();
  final _ownerNameController = TextEditingController();
  bool _isCreating = false;

  @override
  void dispose() {
    _nameController.dispose();
    _ownerNameController.dispose();
    super.dispose();
  }

  Future<void> _handleCreate() async {
    if (_nameController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入共享库名称')),
      );
      return;
    }

    if (_ownerNameController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入您的显示名称')),
      );
      return;
    }

    setState(() => _isCreating = true);

    try {
      final repository = ref.read(vaultRepositoryProvider);
      
      // 确保密钥对已生成
      await ref.read(masterPasswordProvider.notifier).ensureUserKeyPair();
      
      final userKeyPair = await ref.read(userKeyPairProvider.future);

      if (userKeyPair == null) {
        throw Exception('无法获取用户密钥对，请重试');
      }

      await repository.createSharedVault(
        name: _nameController.text,
        ownerKeyPair: userKeyPair,
        ownerName: _ownerNameController.text,
      );

      // 刷新列表
      ref.invalidate(sharedVaultsProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('共享库创建成功')),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('创建失败: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('创建共享库'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.group_add_outlined, size: 80, color: Colors.blue),
            const SizedBox(height: 24),
            const Text(
              '创建一个加密的共享库',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '共享库中的所有项都将使用独立的密钥加密。只有受邀成员才能访问内容。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600]),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '共享库名称',
                hintText: '例如：家庭密码、开发团队',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.folder_shared),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ownerNameController,
              decoration: const InputDecoration(
                labelText: '您的显示名称',
                hintText: '其他成员将看到此名称',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _isCreating ? null : _handleCreate,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: _isCreating
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('立即创建', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}
