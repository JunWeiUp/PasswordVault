import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'decode_qr_from_image.dart';
import '../../providers/vault_provider.dart';
import '../../providers/master_key_provider.dart';
import '../../../domain/models/vault_item.dart';

class AddMemberPage extends ConsumerStatefulWidget {
  final String vaultId;
  const AddMemberPage({super.key, required this.vaultId});

  @override
  ConsumerState<AddMemberPage> createState() => _AddMemberPageState();
}

class _AddMemberPageState extends ConsumerState<AddMemberPage> {
  final _publicKeyController = TextEditingController();
  final _nameController = TextEditingController();
  SharedMemberRole _selectedRole = SharedMemberRole.viewer;
  bool _isAdding = false;
  bool _isDecodingQr = false;

  @override
  void dispose() {
    _publicKeyController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickAndDecodeQr() async {
    if (kIsWeb) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('网页版请手动粘贴公钥')),
        );
      }
      return;
    }

    setState(() => _isDecodingQr = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      if (!mounted) return;
      if (result == null || result.files.isEmpty) return;

      final file = result.files.single;
      final text = await decodeQrFromImageFile(
        path: file.path,
        bytes: file.bytes,
      );
      if (!mounted) return;

      if (text == null || text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未在图片中识别到二维码，请换一张图或手动输入')),
        );
        return;
      }
      setState(() => _publicKeyController.text = text);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('识别失败: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isDecodingQr = false);
    }
  }

  Future<void> _handleAddMember() async {
    if (_publicKeyController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入或从图片识别公钥')),
      );
      return;
    }

    if (_nameController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入成员名称')),
      );
      return;
    }

    setState(() => _isAdding = true);

    try {
      final repository = ref.read(vaultRepositoryProvider);

      // 确保密钥对已生成
      await ref.read(masterPasswordProvider.notifier).ensureUserKeyPair();

      final userKeyPair = await ref.read(userKeyPairProvider.future);

      if (userKeyPair == null) {
        throw Exception('您的密钥对尚未就绪');
      }

      await repository.addMemberToSharedVault(
        vaultId: widget.vaultId,
        memberPublicKeyBase64: _publicKeyController.text.trim(),
        memberName: _nameController.text.trim(),
        role: _selectedRole,
        currentUserKeyPair: userKeyPair,
      );

      // 刷新成员列表
      ref.invalidate(vaultMembersProvider(widget.vaultId));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('成员添加成功')),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('添加失败: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isAdding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('添加成员'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (kIsWeb)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '网页版请在下方的公钥框中粘贴内容。',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
              )
            else
              ElevatedButton.icon(
                onPressed: _isDecodingQr ? null : _pickAndDecodeQr,
                icon: _isDecodingQr
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.image_outlined),
                label: Text(_isDecodingQr ? '正在识别…' : '从相册选择公钥二维码图片'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Colors.blue.withValues(alpha: 0.1),
                  foregroundColor: Colors.blue,
                  elevation: 0,
                ),
              ),
            const SizedBox(height: 24),
            TextField(
              controller: _publicKeyController,
              decoration: const InputDecoration(
                labelText: '公钥 (Base64)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.vpn_key_outlined),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '成员显示名称',
                hintText: '如：张三、小王',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              '赋予权限',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<SharedMemberRole>(
              value: _selectedRole,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(
                  value: SharedMemberRole.viewer,
                  child: Row(
                    children: [
                      Icon(Icons.visibility_outlined, color: Colors.grey[600]),
                      const SizedBox(width: 12),
                      const Text('仅查看'),
                    ],
                  ),
                ),
                DropdownMenuItem(
                  value: SharedMemberRole.editor,
                  child: Row(
                    children: [
                      Icon(Icons.edit_outlined, color: Colors.blue[600]),
                      const SizedBox(width: 12),
                      const Text('可编辑'),
                    ],
                  ),
                ),
                DropdownMenuItem(
                  value: SharedMemberRole.owner,
                  child: Row(
                    children: [
                      Icon(Icons.admin_panel_settings_outlined, color: Colors.amber[800]),
                      const SizedBox(width: 12),
                      const Text('管理员'),
                    ],
                  ),
                ),
              ],
              onChanged: (val) {
                if (val != null) setState(() => _selectedRole = val);
              },
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _isAdding ? null : _handleAddMember,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: _isAdding
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('添加并分发密钥', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 16),
            const Text(
              '注意：添加成员时，系统会使用您的私钥解密库密钥，并用新成员的公钥重新加密。这是一个零知识过程。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
