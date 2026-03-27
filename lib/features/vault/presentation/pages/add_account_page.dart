import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/utils/password_generator.dart';
import '../../../../core/utils/bip39_words.dart';
import '../../../../core/utils/crypto_utils.dart';
import '../../domain/models/vault_item.dart';
import '../providers/vault_provider.dart';
import '../widgets/favicon_widget.dart';

class AddAccountPage extends ConsumerStatefulWidget {
  final VaultItem? item;
  const AddAccountPage({this.item, super.key});

  @override
  ConsumerState<AddAccountPage> createState() => _AddAccountPageState();
}

class _AddAccountPageState extends ConsumerState<AddAccountPage> {
  late final TextEditingController _titleController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final List<_AccountControllerGroup> _extraAccounts;
  late final List<TextEditingController> _mnemonicControllers;
  late final List<FocusNode> _mnemonicFocusNodes;
  late final TextEditingController _privateKeyController;
  late final TextEditingController _addressController;
  late final TextEditingController _categoryController;
  late final TextEditingController _emailController;
  late final TextEditingController _urlController;
  late final TextEditingController _noteController;
  late final TextEditingController _durationController;
  late final TextEditingController _tagInputController;
  String? _selectedSharedVaultId;
  late List<String> _tags;
  String? _totpSecret;
  String? _selectedNetwork;
  bool _obscurePassword = true;
  late bool _obscureMnemonic;

  @override
  void initState() {
    super.initState();
    _obscureMnemonic = widget.item != null && widget.item!.id.isNotEmpty;
    _titleController = TextEditingController(text: widget.item?.title);
    _usernameController = TextEditingController(text: widget.item?.username);
    _passwordController = TextEditingController(text: widget.item?.password);
    
    // 初始化额外账号
    _extraAccounts = (widget.item?.accounts ?? []).map((acc) {
      return _AccountControllerGroup(
        id: acc.id,
        username: acc.username,
        password: acc.password,
        label: acc.label,
        passwordHistory: acc.passwordHistory,
        passwordLastChanged: acc.passwordLastChanged,
      );
    }).toList();
    
    // 初始化助记词控制器
    final mnemonic = widget.item?.mnemonic ?? '';
    final words = mnemonic.split(' ').where((w) => w.isNotEmpty).toList();
    _mnemonicControllers = List.generate(12, (index) {
      return TextEditingController(text: index < words.length ? words[index] : '');
    });
    _mnemonicFocusNodes = List.generate(12, (index) => FocusNode());

    _privateKeyController = TextEditingController(text: widget.item?.privateKey);
    _addressController = TextEditingController(text: widget.item?.address);
    _categoryController = TextEditingController(text: widget.item?.category ?? (
      widget.item?.type == VaultItemType.crypto ? '加密资产' : 
      (widget.item?.type == VaultItemType.secureNote ? '笔记' : '社交媒体')
    ));
    _emailController = TextEditingController(text: widget.item?.email);
    _urlController = TextEditingController(text: widget.item?.url);
    _urlController.addListener(() {
      setState(() {});
    });
    _titleController.addListener(() {
      setState(() {});
    });
    _noteController = TextEditingController(text: widget.item?.note);
    _durationController = TextEditingController(text: widget.item?.passwordDuration?.toString() ?? '');
    _tagInputController = TextEditingController();
    _tags = List.from(widget.item?.tags ?? []);
    _totpSecret = widget.item?.secret;
    _selectedSharedVaultId = widget.item?.sharedVaultId;
    _selectedNetwork = widget.item?.network ?? (widget.item?.type == VaultItemType.crypto ? 'ETH' : null);

    // 添加监听器以自动生成地址
    _privateKeyController.addListener(() => _updateAddressFromPrivateKey(showErrors: false));
    for (var controller in _mnemonicControllers) {
      controller.addListener(_onMnemonicChanged);
    }
  }

  bool _isGeneratingAddress = false;
  bool _isUpdatingMnemonicBatch = false;
  Timer? _debounceTimer;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _titleController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    for (var group in _extraAccounts) {
      group.dispose();
    }
    for (var controller in _mnemonicControllers) {
      controller.dispose();
    }
    for (var node in _mnemonicFocusNodes) {
      node.dispose();
    }
    _privateKeyController.dispose();
    _addressController.dispose();
    _categoryController.dispose();
    _emailController.dispose();
    _urlController.dispose();
    _noteController.dispose();
    _durationController.dispose();
    _tagInputController.dispose();
    super.dispose();
  }

  void _onMnemonicChanged() {
    if (_isUpdatingMnemonicBatch) return;
    
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _updateAddressFromMnemonic(showErrors: false);
    });
  }

  void _updateAddressFromPrivateKey({bool showErrors = true}) {
    final address = CryptoUtils.getEthAddressFromPrivateKey(_privateKeyController.text);
    if (address != null) {
      setState(() {
        _addressController.text = address;
      });
    } else if (showErrors && _privateKeyController.text.isNotEmpty) {
      // 如果私钥无效，显示提示
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('私钥格式无效，请检查（需为 64 位十六进制）')),
      );
    }
  }

  Future<void> _updateAddressFromMnemonic({bool showErrors = true}) async {
    final mnemonic = _mnemonicControllers
        .map((c) => c.text.trim())
        .where((text) => text.isNotEmpty)
        .join(' ');
    
    final words = mnemonic.split(' ');
    if (words.length == 12) {
      setState(() => _isGeneratingAddress = true);
      try {
        final result = await CryptoUtils.getAllFromMnemonic(mnemonic);
        final address = result['address'];
        final privateKey = result['privateKey'];
        
        if (mounted) {
          setState(() {
            if (address != null) _addressController.text = address;
            if (privateKey != null) _privateKeyController.text = privateKey;
          });
          
          if (address == null && showErrors) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('助记词无效，请检查单词拼写')),
            );
          }
        }
      } finally {
        if (mounted) setState(() => _isGeneratingAddress = false);
      }
    } else if (showErrors && mnemonic.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写完整的 12 个助记词')),
      );
    }
  }

  void _save() {
    if (_titleController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写必填项')),
      );
      return;
    }

    final mnemonic = _mnemonicControllers
        .map((c) => c.text.trim())
        .where((text) => text.isNotEmpty)
        .join(' ');

    final newItem = VaultItem(
      id: (widget.item?.id == null || widget.item!.id.isEmpty) ? const Uuid().v4() : widget.item!.id,
      type: widget.item?.type ?? VaultItemType.password,
      title: _titleController.text,
      username: _usernameController.text,
      password: _passwordController.text.isEmpty ? null : _passwordController.text,
      mnemonic: mnemonic.isEmpty ? null : mnemonic,
      privateKey: _privateKeyController.text.isEmpty ? null : _privateKeyController.text,
      address: _addressController.text.isEmpty ? null : _addressController.text,
      network: _selectedNetwork,
      category: _categoryController.text,
      email: _emailController.text.isEmpty ? null : _emailController.text,
      url: _urlController.text.isEmpty ? null : _urlController.text,
      note: _noteController.text.isEmpty ? null : _noteController.text,
      secret: _totpSecret,
      period: widget.item?.period ?? 30,
      isFavorite: widget.item?.isFavorite ?? false,
      passwordDuration: int.tryParse(_durationController.text),
      passwordLastChanged: widget.item?.passwordLastChanged ?? DateTime.now(),
      passwordHistory: widget.item?.passwordHistory,
      tags: _tags,
      sharedVaultId: _selectedSharedVaultId,
      accounts: _extraAccounts.where((g) => g.usernameController.text.isNotEmpty).map((g) {
        return AccountEntry(
          id: g.id.isEmpty ? const Uuid().v4() : g.id,
          username: g.usernameController.text,
          password: g.passwordController.text,
          label: g.labelController.text.isEmpty ? null : g.labelController.text,
          passwordHistory: g.passwordHistory,
          passwordLastChanged: g.passwordLastChanged,
        );
      }).toList(),
    );

    final action = (widget.item == null || widget.item!.id.isEmpty)
      ? ref.read(vaultItemsProvider.notifier).addItem(newItem)
      : ref.read(vaultItemsProvider.notifier).updateItem(newItem);

    action.then((_) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存成功')),
        );
      }
    }).catchError((e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e'), backgroundColor: Colors.red),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.item?.type ?? VaultItemType.password;
    final isCrypto = type == VaultItemType.crypto;
    final isSecureNote = type == VaultItemType.secureNote;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.item?.url != null || _urlController.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FaviconWidget(
                  url: _urlController.text.isNotEmpty ? _urlController.text : widget.item?.url,
                  title: _titleController.text.isNotEmpty ? _titleController.text : (widget.item?.title ?? ''),
                  size: 24,
                ),
              ),
            Text(
              (widget.item == null || widget.item!.id.isEmpty) 
                ? (isCrypto ? '添加钱包' : (isSecureNote ? '添加备注' : '添加账号')) 
                : (isCrypto ? '编辑钱包' : (isSecureNote ? '编辑备注' : '编辑账号')),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _save,
            icon: const Icon(Icons.check),
            tooltip: '保存',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSection(context, '基本信息', [
              _buildTextField(
                label: isCrypto ? '钱包名称' : (isSecureNote ? '备注名称' : '账号名称'),
                controller: _titleController,
                isRequired: true,
                hintText: isCrypto ? '如: MetaMask, Trust Wallet' : (isSecureNote ? '如: 银行卡信息, 备忘' : '如: Google, GitHub'),
              ),
              if (!isCrypto && !isSecureNote)
                _buildTextField(
                  label: '用户名',
                  controller: _usernameController,
                  isRequired: true,
                  hintText: '用户名或邮箱',
                  autofillHints: const [AutofillHints.username, AutofillHints.email],
                ),
              if (isCrypto)
                _buildTextField(
                  label: '钱包地址',
                  controller: _addressController,
                  hintText: '0x...',
                  suffixIcon: _isGeneratingAddress
                    ? const Padding(
                        padding: EdgeInsets.all(12.0),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.auto_awesome_outlined, size: 20),
                        tooltip: '根据私钥/助记词自动生成',
                        onPressed: () {
                          _updateAddressFromPrivateKey();
                          _updateAddressFromMnemonic();
                        },
                      ),
                ),
              if (isCrypto)
                ListTile(
                  title: const Text('区块链网络'),
                  subtitle: Text(_selectedNetwork ?? '未选择'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _showNetworkPicker,
                ),
              if (!isCrypto && !isSecureNote)
                _buildTextField(
                  label: '密码',
                  controller: _passwordController,
                  isPassword: _obscurePassword,
                  hintText: '账号密码',
                  autofillHints: const [AutofillHints.password],
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(_obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                        tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                        onPressed: () {
                          setState(() {
                            _obscurePassword = !_obscurePassword;
                          });
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.casino_outlined),
                        tooltip: '生成随机密码',
                        onPressed: () {
                          final newPassword = PasswordGenerator.generate(length: 16);
                          setState(() {
                            _passwordController.text = newPassword;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ListTile(
                title: const Text('分类'),
                subtitle: Text(_categoryController.text),
                trailing: const Icon(Icons.chevron_right),
                onTap: _showCategoryPicker,
              ),
              _buildSharedVaultPicker(),
            ]),
            if (!isCrypto && !isSecureNote) ...[
              const SizedBox(height: 16),
              _buildSection(
                context, 
                '更多账号', 
                [
                  ..._extraAccounts.asMap().entries.map((entry) {
                    final index = entry.key;
                    final group = entry.value;
                    return Column(
                      children: [
                        if (index > 0) const Divider(),
                        Padding(
                          padding: const EdgeInsets.only(left: 16, right: 8, top: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text('账号 ${index + 2}', 
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Theme.of(context).colorScheme.primary,
                                  )
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                                onPressed: () => setState(() => _extraAccounts.removeAt(index)),
                              ),
                            ],
                          ),
                        ),
                        _buildTextField(
                          label: '备注',
                          controller: group.labelController,
                          hintText: '账号用途 (如: 工作, 个人)',
                        ),
                        _buildTextField(
                          label: '用户名',
                          controller: group.usernameController,
                          hintText: '用户名或邮箱',
                        ),
                        _buildTextField(
                    label: '密码',
                    controller: group.passwordController,
                    isPassword: group.obscurePassword,
                    hintText: '账号密码',
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(group.obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                          onPressed: () => setState(() => group.obscurePassword = !group.obscurePassword),
                        ),
                        IconButton(
                          icon: const Icon(Icons.casino_outlined),
                          onPressed: () {
                            final newPassword = PasswordGenerator.generate(length: 16);
                            setState(() => group.passwordController.text = newPassword);
                          },
                        ),
                      ],
                    ),
                  ),
                  if (group.passwordHistory != null && group.passwordHistory!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Row(
                        children: [
                          if (group.passwordLastChanged != null)
                            Expanded(
                              child: Text(
                                '最后修改: ${group.passwordLastChanged!.toString().split('.')[0]}',
                                style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
                              ),
                            ),
                          TextButton.icon(
                            onPressed: () {
                              final label = group.labelController.text;
                              _showPasswordHistory(
                                history: group.passwordHistory,
                                title: '${label.isNotEmpty ? label : '账号 ${index + 2}'} 的历史密码',
                              );
                            },
                            icon: const Icon(Icons.history, size: 16),
                            label: Text('历史 (${group.passwordHistory!.length})', style: const TextStyle(fontSize: 12)),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ],
                      ),
                    ),
                      ],
                    );
                  }),
                  ListTile(
                    leading: Icon(Icons.add_circle_outline, color: Theme.of(context).colorScheme.primary),
                    title: Text('添加额外账号', style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                    onTap: () => setState(() => _extraAccounts.add(_AccountControllerGroup())),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            if (isCrypto) ...[
              _buildSection(context, '私钥信息', [
                _buildTextField(
                  label: '私钥',
                  controller: _privateKeyController,
                  isPassword: _obscureMnemonic,
                  hintText: '输入钱包私钥',
                  suffixIcon: IconButton(
                    icon: Icon(_obscureMnemonic ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    onPressed: () => setState(() => _obscureMnemonic = !_obscureMnemonic),
                  ),
                ),
              ]),
              const SizedBox(height: 16),
              _buildSection(context, '助记词', [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          childAspectRatio: 2.8, // 进一步调大比例以减小高度
                        ),
                        itemCount: 12,
                        itemBuilder: (context, index) {
                          return Container(
                            decoration: BoxDecoration(
                              color: Theme.of(context).dividerColor.withOpacity(0.05),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Theme.of(context).dividerColor.withOpacity(0.1),
                              ),
                            ),
                            child: Stack(
                              children: [
                                // 序号放在左上角，不占用 TextField 空间
                                Positioned(
                                  top: 4,
                                  left: 6,
                                  child: Text(
                                    '${index + 1}',
                                    style: TextStyle(
                                      color: Theme.of(context).colorScheme.primary.withOpacity(0.4),
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                Center(
                                  child: RawAutocomplete<String>(
                                    textEditingController: _mnemonicControllers[index],
                                    focusNode: _mnemonicFocusNodes[index],
                                    optionsBuilder: (TextEditingValue textEditingValue) {
                                      if (textEditingValue.text.isEmpty || _obscureMnemonic) {
                                        return const Iterable<String>.empty();
                                      }
                                      return Bip39Words.wordList.where((String option) {
                                        return option.startsWith(textEditingValue.text.toLowerCase());
                                      });
                                    },
                                    fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                                      return TextField(
                                        controller: controller,
                                        focusNode: focusNode,
                                        obscureText: _obscureMnemonic,
                                        textAlign: TextAlign.center, // 确保文字居中
                                        autocorrect: false,
                                        enableSuggestions: false,
                                        textInputAction: index < 11 ? TextInputAction.next : TextInputAction.done,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: 0.5,
                                        ),
                                        decoration: InputDecoration(
                                          border: InputBorder.none,
                                          isDense: true,
                                          contentPadding: const EdgeInsets.symmetric(vertical: 8),
                                          hintText: '单词',
                                          hintStyle: TextStyle(
                                            fontSize: 14,
                                            color: Theme.of(context).hintColor.withOpacity(0.3),
                                          ),
                                        ),
                                      );
                                    },
                                    optionsViewBuilder: (context, onSelected, options) {
                                      return Align(
                                        alignment: Alignment.topLeft,
                                        child: Material(
                                          elevation: 4.0,
                                          borderRadius: BorderRadius.circular(8),
                                          child: Container(
                                            width: 150,
                                            constraints: const BoxConstraints(maxHeight: 200),
                                            child: ListView.builder(
                                              padding: EdgeInsets.zero,
                                              shrinkWrap: true,
                                              itemCount: options.length,
                                              itemBuilder: (BuildContext context, int index) {
                                                final String option = options.elementAt(index);
                                                return InkWell(
                                                  onTap: () => onSelected(option),
                                                  child: Padding(
                                                    padding: const EdgeInsets.all(12.0),
                                                    child: Text(
                                                      option,
                                                      textAlign: TextAlign.center, // 联想列表项也居中
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _isGeneratingAddress ? null : () async {
                                // 1. 先更新 UI 状态显示加载动画
                                setState(() {
                                  _isGeneratingAddress = true;
                                  _isUpdatingMnemonicBatch = true;
                                });
                                
                                // 2. 稍微延迟一点点，给 UI 线程留出渲染“正在生成...”动画的时间
                                await Future.delayed(const Duration(milliseconds: 50));

                                try {
                                  // 3. 在 Isolate 中生成助记词
                                  final randomMnemonic = await PasswordGenerator.generateMnemonic();
                                  final words = randomMnemonic.split(' ');
                                  
                                  if (mounted) {
                                    setState(() {
                                      for (int i = 0; i < 12; i++) {
                                        _mnemonicControllers[i].text = words[i];
                                      }
                                      _obscureMnemonic = false;
                                    });
                                  }
                                  
                                  // 4. 计算地址 (已经在 Isolate 中)
                                  await _updateAddressFromMnemonic();
                                } finally {
                                  if (mounted) {
                                    setState(() {
                                      _isUpdatingMnemonicBatch = false;
                                      _isGeneratingAddress = false;
                                    });
                                  }
                                }
                              },
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              icon: _isGeneratingAddress 
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.auto_fix_high, size: 20),
                              label: Text(_isGeneratingAddress ? '正在生成...' : '生成随机助记词'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Container(
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: IconButton(
                              icon: Icon(
                                _obscureMnemonic ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              onPressed: () => setState(() => _obscureMnemonic = !_obscureMnemonic),
                              tooltip: _obscureMnemonic ? '显示' : '隐藏',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ]),
            ],
            if (!isCrypto)
              _buildSection(context, '安全设置', [
                ListTile(
                  leading: const Icon(Icons.security),
                  title: const Text('双因素认证 (2FA)'),
                  subtitle: Text(_totpSecret == null ? '未配置' : '已配置 (点击修改)'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _show2FAConfig,
                ),
              ]),
            const SizedBox(height: 16),
            _buildSection(context, isSecureNote ? '笔记内容' : '可选信息', [
              if (!isCrypto && !isSecureNote)
                _buildTextField(
                  label: '邮箱',
                  controller: _emailController,
                  hintText: '关联邮箱',
                ),
              if (!isCrypto && !isSecureNote)
                _buildTextField(
                  label: '网站/域名',
                  controller: _urlController,
                  hintText: '支持多个域名，以逗号或分号分隔',
                  maxLines: 2,
                ),
              _buildTextField(
                label: isSecureNote ? '内容' : '备注',
                controller: _noteController,
                hintText: isSecureNote ? '在此输入您的笔记...' : '额外信息...',
                maxLines: isSecureNote ? 10 : 3,
              ),
              const SizedBox(height: 8),
              _buildTagsSection(),
            ]),
            const SizedBox(height: 16),
            if (!isCrypto)
              _buildSection(context, '安全设置', [
                _buildTextField(
                  label: '密码有效期 (天)',
                  controller: _durationController,
                  keyboardType: TextInputType.number,
                  hintText: '留空表示永不过期',
                  suffixIcon: const Icon(Icons.timer_outlined),
                ),
                if (widget.item?.passwordLastChanged != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      '最后修改时间: ${widget.item!.passwordLastChanged!.toString().split('.')[0]}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ),
                if (widget.item?.passwordHistory != null && widget.item!.passwordHistory!.isNotEmpty)
                  ListTile(
                    title: const Text('查看历史密码'),
                    subtitle: Text('共有 ${widget.item!.passwordHistory!.length} 条记录'),
                    trailing: const Icon(Icons.history),
                    onTap: _showPasswordHistory,
                  ),
              ]),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildTagsSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('标签', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ..._tags.map((tag) => Chip(
                    label: Text(tag, style: const TextStyle(fontSize: 12)),
                    onDeleted: () {
                      setState(() {
                        _tags.remove(tag);
                      });
                    },
                    deleteIconColor: Colors.red,
                    padding: EdgeInsets.zero,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  )),
              ActionChip(
                label: const Icon(Icons.add, size: 16),
                onPressed: _showAddTagDialog,
                padding: EdgeInsets.zero,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showAddTagDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('添加标签'),
          content: TextField(
            controller: _tagInputController,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '输入标签名称',
            ),
            onSubmitted: (value) {
              if (value.isNotEmpty) {
                setState(() {
                  if (!_tags.contains(value)) {
                    _tags.add(value);
                  }
                  _tagInputController.clear();
                });
                Navigator.pop(context);
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final value = _tagInputController.text;
                if (value.isNotEmpty) {
                  setState(() {
                    if (!_tags.contains(value)) {
                      _tags.add(value);
                    }
                    _tagInputController.clear();
                  });
                }
                Navigator.pop(context);
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  void _showPasswordHistory({List<PasswordHistoryEntry>? history, String? title}) {
    final displayHistory = (history ?? widget.item?.passwordHistory ?? []).reversed.toList();
    if (displayHistory.isEmpty) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          minChildSize: 0.4,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Text(
                  title ?? '历史密码',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: displayHistory.length,
                    itemBuilder: (context, index) {
                      final entry = displayHistory[index];
                      return ListTile(
                        title: Text(
                          entry.password,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        subtitle: Text(entry.changedAt.toString().split('.')[0]),
                        trailing: IconButton(
                          icon: const Icon(Icons.copy_rounded, size: 20),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: entry.password));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已复制到剪贴板')),
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSection(BuildContext context, String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Text(
            title,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: Theme.of(context).dividerColor.withOpacity(0.1)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: children.asMap().entries.map((entry) {
              final index = entry.key;
              final child = entry.value;
              return Column(
                children: [
                  child,
                  if (index < children.length - 1) 
                    const Divider(height: 1, indent: 16, endIndent: 16),
                ],
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    bool isRequired = false,
    bool isPassword = false,
    String? hintText,
    int maxLines = 1,
    Widget? suffixIcon,
    TextInputType? keyboardType,
    List<String>? autofillHints,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: TextField(
        controller: controller,
        obscureText: isPassword,
        maxLines: maxLines,
        keyboardType: keyboardType,
        autofillHints: autofillHints,
        decoration: InputDecoration(
          labelText: isRequired ? '$label *' : label,
          hintText: hintText,
          border: InputBorder.none,
          isDense: true,
          suffixIcon: suffixIcon,
        ),
      ),
    );
  }

  void _showNetworkPicker() {
    final networks = ref.read(networksProvider);
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text('选择区块链网络', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            const Divider(),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: networks.length + 1,
                itemBuilder: (context, index) {
                  if (index == networks.length) {
                    return ListTile(
                      leading: const Icon(Icons.add),
                      title: const Text('添加新网络'),
                      onTap: () {
                        Navigator.pop(context);
                        _showAddNetworkDialog();
                      },
                    );
                  }
                  final network = networks[index];
                  return ListTile(
                    title: Text(network),
                    trailing: _selectedNetwork == network ? const Icon(Icons.check, color: Colors.blue) : null,
                    onTap: () {
                      setState(() {
                        _selectedNetwork = network;
                      });
                      Navigator.pop(context);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddNetworkDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加新网络'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '请输入网络名称 (如: Arbitrum)',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ElevatedButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                setState(() {
                  _selectedNetwork = controller.text;
                });
              }
              Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Widget _buildSharedVaultPicker() {
    final sharedVaultsAsync = ref.watch(sharedVaultsProvider);

    return sharedVaultsAsync.when(
      data: (vaults) {
        if (vaults.isEmpty) return const SizedBox.shrink();

        String subtitle = '个人库';
        if (_selectedSharedVaultId != null) {
          try {
            final vault = vaults.firstWhere((v) => v.id == _selectedSharedVaultId);
            subtitle = '共享库: ${vault.name}';
          } catch (_) {
            _selectedSharedVaultId = null;
          }
        }

        return ListTile(
          leading: const Icon(Icons.folder_shared_outlined),
          title: const Text('存放位置'),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showSharedVaultPicker(vaults),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  void _showSharedVaultPicker(List<SharedVault> vaults) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('选择存放位置', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('个人库 (默认)'),
                trailing: _selectedSharedVaultId == null ? const Icon(Icons.check, color: Colors.blue) : null,
                onTap: () {
                  setState(() => _selectedSharedVaultId = null);
                  Navigator.pop(context);
                },
              ),
              ...vaults.map((vault) => ListTile(
                    leading: const Icon(Icons.folder_shared_outlined),
                    title: Text(vault.name),
                    trailing: _selectedSharedVaultId == vault.id ? const Icon(Icons.check, color: Colors.blue) : null,
                    onTap: () {
                      setState(() => _selectedSharedVaultId = vault.id);
                      Navigator.pop(context);
                    },
                  )),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  void _showCategoryPicker() {
    final categories = ref.read(categoriesProvider);
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '选择分类',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: categories.length + 1,
                itemBuilder: (context, index) {
                  if (index == categories.length) {
                    return ListTile(
                      leading: const Icon(Icons.add),
                      title: const Text('添加新分类'),
                      onTap: () {
                        Navigator.pop(context);
                        _showAddCategoryDialog();
                      },
                    );
                  }
                  final category = categories[index];
                  return ListTile(
                    title: Text(category),
                    trailing: _categoryController.text == category ? const Icon(Icons.check, color: Colors.blue) : null,
                    onTap: () {
                      setState(() {
                        _categoryController.text = category;
                      });
                      Navigator.pop(context);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddCategoryDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加新分类'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '请输入分类名称',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ElevatedButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                setState(() {
                  _categoryController.text = controller.text;
                });
              }
              Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _show2FAConfig() {
    final controller = TextEditingController(text: _totpSecret);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('配置 2FA'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z2-7\s]')),
          ],
          decoration: const InputDecoration(
            labelText: '密钥 (Secret Key)',
            hintText: 'JBSWY3DPEHPK3PXP',
            helperText: '通常是 16 或 32 位字符',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _totpSecret = null;
              });
              Navigator.pop(context);
            }, 
            child: const Text('清除', style: TextStyle(color: Colors.red)),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ElevatedButton(
            onPressed: () {
              final secret = controller.text.replaceAll(' ', '').toUpperCase();
              setState(() {
                _totpSecret = secret.isEmpty ? null : secret;
              });
              Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

class _AccountControllerGroup {
  final String id;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final TextEditingController labelController;
  final List<PasswordHistoryEntry>? passwordHistory;
  final DateTime? passwordLastChanged;
  bool obscurePassword;

  _AccountControllerGroup({
    String? id,
    String? username,
    String? password,
    String? label,
    this.passwordHistory,
    this.passwordLastChanged,
    this.obscurePassword = true,
  })  : id = id ?? '',
        usernameController = TextEditingController(text: username),
        passwordController = TextEditingController(text: password),
        labelController = TextEditingController(text: label);

  void dispose() {
    usernameController.dispose();
    passwordController.dispose();
    labelController.dispose();
  }
}
