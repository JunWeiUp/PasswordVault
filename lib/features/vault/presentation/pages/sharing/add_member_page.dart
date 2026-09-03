import 'package:password/core/l10n/l10n.dart';
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
          SnackBar(content: Text(tr.pasteThePublicKeyManuallyInThe)),
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
          SnackBar(content: Text(tr.noQrCodeFoundChooseAnotherImage)),
        );
        return;
      }
      setState(() => _publicKeyController.text = text);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr.couldNotReadQrCode(e)),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isDecodingQr = false);
    }
  }

  Future<void> _handleAddMember() async {
    if (_publicKeyController.text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr.enterAPublicKeyOrReadOne)));
      return;
    }

    if (_nameController.text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr.enterAMemberName)));
      return;
    }

    setState(() => _isAdding = true);

    try {
      final repository = ref.read(vaultRepositoryProvider);

      // 确保密钥对已生成
      await ref.read(masterPasswordProvider.notifier).ensureUserKeyPair();

      final userKeyPair = await ref.read(userKeyPairProvider.future);

      if (userKeyPair == null) {
        throw Exception(tr.yourKeyPairIsNotReady);
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr.memberAdded)));
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr.couldNotAddMember(e)),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isAdding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr.addMember)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (kIsWeb)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  tr.pasteThePublicKeyInTheField,
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
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
                label: Text(
                  _isDecodingQr ? tr.readingImage : tr.chooseAPublicKeyQrImage,
                ),
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
              decoration: InputDecoration(
                labelText: tr.publicKeyBase,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.vpn_key_outlined),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: tr.memberDisplayName,
                hintText: tr.eGAlexSam,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              tr.permissions,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<SharedMemberRole>(
              value: _selectedRole,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: [
                DropdownMenuItem(
                  value: SharedMemberRole.viewer,
                  child: Row(
                    children: [
                      Icon(Icons.visibility_outlined, color: Colors.grey[600]),
                      const SizedBox(width: 12),
                      Text(tr.viewer),
                    ],
                  ),
                ),
                DropdownMenuItem(
                  value: SharedMemberRole.editor,
                  child: Row(
                    children: [
                      Icon(Icons.edit_outlined, color: Colors.blue[600]),
                      const SizedBox(width: 12),
                      Text(tr.editor),
                    ],
                  ),
                ),
                DropdownMenuItem(
                  value: SharedMemberRole.owner,
                  child: Row(
                    children: [
                      Icon(
                        Icons.admin_panel_settings_outlined,
                        color: Colors.amber[800],
                      ),
                      const SizedBox(width: 12),
                      Text(tr.owner),
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
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _isAdding
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      tr.addMemberAndShareKey,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
            const SizedBox(height: 16),
            Text(
              tr.theAppDecryptsTheVaultKeyLocally,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
