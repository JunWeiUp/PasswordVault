import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/backup_provider.dart';
import '../../domain/models/webdav_config.dart';

class WebDavConfigPage extends ConsumerStatefulWidget {
  const WebDavConfigPage({super.key});

  @override
  ConsumerState<WebDavConfigPage> createState() => _WebDavConfigPageState();
}

class _WebDavConfigPageState extends ConsumerState<WebDavConfigPage> {
  late TextEditingController _urlController;
  late TextEditingController _userController;
  late TextEditingController _passController;
  late TextEditingController _dirController;
  bool _obscurePassword = true;
  bool _isTesting = false;

  @override
  void initState() {
    super.initState();
    final config = ref.read(webDavConfigProvider);
    _urlController = TextEditingController(text: config.url);
    _userController = TextEditingController(text: config.username);
    _passController = TextEditingController(text: config.password);
    _dirController = TextEditingController(text: config.backupDirectory);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passController.dispose();
    _dirController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    setState(() => _isTesting = true);
    final config = WebDavConfig(
      url: _urlController.text,
      username: _userController.text,
      password: _passController.text,
      backupDirectory: _dirController.text,
    );
    final success = await ref.read(backupServiceProvider).testConnection(config);
    setState(() => _isTesting = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '连接成功' : '连接失败，请检查配置'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  Future<void> _saveConfig() async {
    final config = WebDavConfig(
      url: _urlController.text,
      username: _userController.text,
      password: _passController.text,
      backupDirectory: _dirController.text,
    );
    await ref.read(webDavConfigProvider.notifier).saveConfig(config);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('配置已保存')),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WebDAV配置'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
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
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.cloud_queue, color: Colors.blue, size: 32),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'WebDAV 同步',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '配置 WebDAV 服务可以将您的密码数据备份到自己的云存储中，支持 NextCloud、Seafile、坚果云等服务。',
                            style: TextStyle(color: Colors.grey[600], fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              '服务器配置',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 16),
            _buildTextField(
              controller: _urlController,
              label: '服务器地址',
              icon: Icons.link,
            ),
            const SizedBox(height: 16),
            _buildTextField(
              controller: _userController,
              label: '用户名',
              icon: Icons.person_outline,
            ),
            const SizedBox(height: 16),
            _buildTextField(
              controller: _passController,
              label: '密码',
              icon: Icons.lock_outline,
              obscureText: _obscurePassword,
              suffixIcon: IconButton(
                icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            const SizedBox(height: 16),
            _buildTextField(
              controller: _dirController,
              label: '备份目录',
              icon: Icons.folder_open,
              helperText: '备份文件将保存在此目录下',
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _isTesting ? null : _testConnection,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                  backgroundColor: Colors.grey[100],
                  side: BorderSide.none,
                ),
                child: _isTesting
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('测试连接', style: TextStyle(color: Colors.black87)),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saveConfig,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
                child: const Text('保存配置'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscureText = false,
    Widget? suffixIcon,
    String? helperText,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey[300]!),
          ),
          child: TextField(
            controller: controller,
            obscureText: obscureText,
            decoration: InputDecoration(
              prefixIcon: Icon(icon, color: Colors.grey[600]),
              labelText: label,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              suffixIcon: suffixIcon,
            ),
          ),
        ),
        if (helperText != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(
              helperText,
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
          ),
      ],
    );
  }
}
