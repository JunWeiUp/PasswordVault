import 'package:password/core/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/vault_provider.dart';
import '../../providers/master_key_provider.dart';

class CreateSharedVaultPage extends ConsumerStatefulWidget {
  const CreateSharedVaultPage({super.key});

  @override
  ConsumerState<CreateSharedVaultPage> createState() =>
      _CreateSharedVaultPageState();
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr.enterASharedVaultName)));
      return;
    }

    if (_ownerNameController.text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr.enterYourDisplayName)));
      return;
    }

    setState(() => _isCreating = true);

    try {
      final repository = ref.read(vaultRepositoryProvider);

      // 确保密钥对已生成
      await ref.read(masterPasswordProvider.notifier).ensureUserKeyPair();

      final userKeyPair = await ref.read(userKeyPairProvider.future);

      if (userKeyPair == null) {
        throw Exception(tr.couldNotLoadYourKeyPairTry);
      }

      await repository.createSharedVault(
        name: _nameController.text,
        ownerKeyPair: userKeyPair,
        ownerName: _ownerNameController.text,
      );

      // 刷新列表
      ref.invalidate(sharedVaultsProvider);

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr.sharedVaultCreated)));
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr.couldNotCreateVault(e)),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr.createSharedVault)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.group_add_outlined, size: 80, color: Colors.blue),
            const SizedBox(height: 24),
            Text(
              tr.createAnEncryptedSharedVault,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              tr.sharedVaultItemsUseASeparateEncryption,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600]),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: tr.sharedVaultName,
                hintText: tr.eGFamilyPasswordsDevelopmentTeam,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.folder_shared),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ownerNameController,
              decoration: InputDecoration(
                labelText: tr.yourDisplayName,
                hintText: tr.otherMembersWillSeeThisName,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _isCreating ? null : _handleCreate,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _isCreating
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      tr.createVault,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
