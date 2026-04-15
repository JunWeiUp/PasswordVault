import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../providers/master_key_provider.dart';

class SharePublicKeyPage extends ConsumerStatefulWidget {
  const SharePublicKeyPage({super.key});

  @override
  ConsumerState<SharePublicKeyPage> createState() => _SharePublicKeyPageState();
}

class _SharePublicKeyPageState extends ConsumerState<SharePublicKeyPage> {
  @override
  void initState() {
    super.initState();
    // 页面加载时确保密钥对已生成
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterPasswordProvider.notifier).ensureUserKeyPair();
    });
  }

  @override
  Widget build(BuildContext context) {
    final userKeyPairAsync = ref.watch(userKeyPairProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的共享公钥'),
      ),
      body: userKeyPairAsync.when(
        data: (keyPair) {
          if (keyPair == null) {
            return const Center(child: Text('公钥生成中...'));
          }

          return FutureBuilder(
            future: keyPair.extractPublicKey(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final publicKey = snapshot.data!;
              final publicKeyBase64 = base64.encode(publicKey.bytes);

              return SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: Column(
                  children: [
                    const Icon(Icons.share_outlined, size: 64, color: Colors.blue),
                    const SizedBox(height: 24),
                    const Text(
                      '扫描或复制公钥以加入共享库',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '公钥是安全的，可以公开分享。它用于其他成员为您加密共享库的访问密钥。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[600], fontSize: 14),
                    ),
                    const SizedBox(height: 40),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 10,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: QrImageView(
                        data: publicKeyBase64,
                        version: QrVersions.auto,
                        size: 240.0,
                        backgroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 40),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '公钥 (Base64)',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey[300]!),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              publicKeyBase64,
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: publicKeyBase64));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('公钥已复制到剪贴板')),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, stack) => Center(child: Text('加载失败: $err')),
      ),
    );
  }
}
