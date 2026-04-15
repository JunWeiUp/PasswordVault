import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:nsd/nsd.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../vault/presentation/providers/vault_provider.dart';
import '../../vault/presentation/providers/master_key_provider.dart';
import '../../vault/domain/models/vault_item.dart';

class SyncDevice {
  final String id;
  final String name;
  final String host;
  final int port;
  final String? userPublicKey;
  final DateTime lastSeen;

  SyncDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    this.userPublicKey,
    required this.lastSeen,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'userPublicKey': userPublicKey,
    'lastSeen': lastSeen.toIso8601String(),
  };

  SyncDevice copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? userPublicKey,
    DateTime? lastSeen,
  }) {
    return SyncDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      userPublicKey: userPublicKey ?? this.userPublicKey,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}

class LanJoinRequest {
  final String deviceId;
  final String deviceName;
  final String userPublicKey; // Base64
  final String? vaultId; // If null, it's a general request
  final String? vaultName;
  final int? senderPort; // 申请者的服务端口
  final String? senderHost; // 申请者的 IP
  final DateTime timestamp;

  LanJoinRequest({
    required this.deviceId,
    required this.deviceName,
    required this.userPublicKey,
    this.vaultId,
    this.vaultName,
    this.senderPort,
    this.senderHost,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'deviceName': deviceName,
    'userPublicKey': userPublicKey,
    'vaultId': vaultId,
    'vaultName': vaultName,
    'senderPort': senderPort,
    'senderHost': senderHost,
    'timestamp': timestamp.toIso8601String(),
  };

  factory LanJoinRequest.fromJson(Map<String, dynamic> json) => LanJoinRequest(
    deviceId: json['deviceId'] ?? '',
    deviceName: json['deviceName'] ?? 'Unknown',
    userPublicKey: json['userPublicKey'] ?? '',
    vaultId: json['vaultId'],
    vaultName: json['vaultName'],
    senderPort: json['senderPort'],
    senderHost: json['senderHost'],
    timestamp: json['timestamp'] != null ? DateTime.parse(json['timestamp']) : DateTime.now(),
  );
}

enum JoinRequestStatus { pending, approved, rejected }

class SentJoinRequest {
  final String deviceId;
  final String deviceName;
  final String? vaultId;
  final String? vaultName;
  JoinRequestStatus status;
  final DateTime timestamp;

  SentJoinRequest({
    required this.deviceId,
    required this.deviceName,
    this.vaultId,
    this.vaultName,
    this.status = JoinRequestStatus.pending,
    required this.timestamp,
  });
}

class DiscoverableVault {
  final String id;
  final String name;
  final SyncDevice device;

  DiscoverableVault({
    required this.id,
    required this.name,
    required this.device,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'deviceId': device.id,
  };
}

class LocalSyncService extends ChangeNotifier {
  final Ref _ref;
  static const String _serviceType = '_password-vault._tcp';
  static const String _deviceIdKey = 'sync_device_id';
  static const String _deviceNameKey = 'sync_device_name';
  static const String _syncEnabledKey = 'sync_enabled';
  static const String _syncTokenKey = 'sync_auth_token';

  HttpServer? _server;
  Discovery? _discovery;
  Registration? _registration;
  
  final _devicesController = StreamController<List<SyncDevice>>.broadcast();
  Stream<List<SyncDevice>> get devicesStream {
    Timer.run(() => _devicesController.add(_discoveredDevices.values.toList()));
    return _devicesController.stream;
  }

  final _discoverableVaultsController = StreamController<List<DiscoverableVault>>.broadcast();
  Stream<List<DiscoverableVault>> get discoverableVaultsStream {
    Timer.run(() => _refreshDiscoverableVaults());
    return _discoverableVaultsController.stream;
  }

  final _syncStatusController = StreamController<bool>.broadcast();
  Stream<bool> get syncStatusStream => _syncStatusController.stream;
  
  final Map<String, SyncDevice> _discoveredDevices = {};
  final Map<String, List<DiscoverableVault>> _deviceVaults = {};
  final _joinRequestsController = StreamController<List<LanJoinRequest>>.broadcast();
  Stream<List<LanJoinRequest>> get joinRequestsStream {
    // Emit current state immediately when a new listener joins
    Timer.run(() => _joinRequestsController.add(List.from(_pendingJoinRequests)));
    return _joinRequestsController.stream;
  }

  final _sentRequestsController = StreamController<List<SentJoinRequest>>.broadcast();
  Stream<List<SentJoinRequest>> get sentRequestsStream {
    // Emit current state immediately when a new listener joins
    Timer.run(() => _sentRequestsController.add(List.from(_sentJoinRequests)));
    return _sentRequestsController.stream;
  }

  final List<LanJoinRequest> _pendingJoinRequests = [];
  final List<SentJoinRequest> _sentJoinRequests = [];
  final Set<String> _syncingDevices = {};

  String? _myDeviceId;
  String? _myDeviceName;
  bool _isEnabled = false;
  String? _syncToken;

  int? get port => _server?.port;
  String? get syncToken => _syncToken;

  Future<List<String>> getLocalIps() async {
    if (kIsWeb) return [];
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      return interfaces
          .expand((interface) => interface.addresses)
          .map((address) => address.address)
          .toList();
    } catch (e) {
      debugPrint('Error getting local IPs: $e');
      return [];
    }
  }

  LocalSyncService(this._ref) {
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _myDeviceId = prefs.getString(_deviceIdKey);
    if (_myDeviceId == null) {
      _myDeviceId = const Uuid().v4();
      await prefs.setString(_deviceIdKey, _myDeviceId!);
    }
    
    String defaultName = 'Unknown Device';
    if (!kIsWeb) {
      try {
        defaultName = Platform.localHostname;
      } catch (e) {
        // Fallback for some platforms
      }
    }
    
    _myDeviceName = prefs.getString(_deviceNameKey) ?? defaultName;
    _isEnabled = prefs.getBool(_syncEnabledKey) ?? false;

    _syncToken = prefs.getString(_syncTokenKey);
    if (_syncToken == null) {
      _syncToken = const Uuid().v4();
      await prefs.setString(_syncTokenKey, _syncToken!);
    }

    // Set repository callback
    _ref.read(vaultRepositoryProvider).onItemChanged = (sharedVaultId) {
      if (_isEnabled) {
        broadcastVaultUpdate(sharedVaultId);
      }
    };

    if (_isEnabled) {
      start();
    }
  }

  Future<void> broadcastVaultUpdate(String? sharedVaultId) async {
    if (sharedVaultId == null) return;

    debugPrint('📢 Broadcasting update for shared vault: $sharedVaultId');
    
    // Find members of this vault to only sync with them
    final repository = _ref.read(vaultRepositoryProvider);
    final members = await repository.getVaultMembers(sharedVaultId);
    final memberPublicKeys = members.map((m) => m.userPublicKey).toSet();
    
    for (final device in _discoveredDevices.values) {
      // If we don't have the device's public key yet, try to fetch it first
      if (device.userPublicKey == null) {
        await _fetchDeviceDetails(device);
      }
      
      // Re-get device from map in case it was updated by _fetchDeviceDetails
      final updatedDevice = _discoveredDevices[device.id] ?? device;

      // Only sync if the device's public key matches a member of the vault
      if (updatedDevice.userPublicKey != null && memberPublicKeys.contains(updatedDevice.userPublicKey)) {
        debugPrint('  - Syncing with member device: ${updatedDevice.name}');
        syncWithDevice(updatedDevice).catchError((e) {
          debugPrint('Broadcast sync failed for ${updatedDevice.name}: $e');
        });
      }
    }
  }

  bool get isEnabled => _isEnabled;
  String get deviceName => _myDeviceName ?? 'Unknown';

  Future<void> setEnabled(bool enabled) async {
    if (_isEnabled == enabled) return;
    _isEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_syncEnabledKey, _isEnabled);
    
    if (_isEnabled) {
      await start();
    } else {
      await stop();
    }
    notifyListeners();
  }

  Future<void> setDeviceName(String name) async {
    _myDeviceName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_deviceNameKey, name);
    if (_isEnabled) {
      // Restart to update advertisement
      await stop();
      await start();
    }
  }

  Future<void> refreshDiscovery() async {
    if (!_isEnabled || kIsWeb) return;
    
    debugPrint('🔄 Refreshing discovery...');
    
    // 1. Restart NSD discovery if it's running
    if (_discovery != null) {
      // Re-trigger discovery by starting it again if nsd supports it, 
      // or just re-fetch details for all known devices.
      // nsd doesn't have a direct 'refresh', but we can re-fetch details.
    }
    
    // 2. Re-fetch details for all known devices
    final devices = _discoveredDevices.values.toList();
    for (final device in devices) {
      _fetchDeviceDetails(device);
    }
    
    notifyListeners();
  }

  Future<void> start() async {
    if (kIsWeb) {
      // Web can only act as a client, no need to start server or discovery
      return;
    }

    await stop();

    // 1. Start HTTP Server
    final router = Router();

    bool _checkAuth(Request request) {
      final token = request.headers['x-sync-token'] ?? request.url.queryParameters['token'];
      return token == _syncToken;
    }
    
    // Check sync status (public, but does not expose secrets)
    router.get('/status', (Request request) {
      return Response.ok(jsonEncode({
        'id': _myDeviceId,
        'name': _myDeviceName,
        'version': '1.0.0',
      }), headers: {'content-type': 'application/json'});
    });

    // Get all items (encrypted with sync key, requires auth token)
    router.get('/pull', (Request request) async {
      if (!_checkAuth(request)) return Response.forbidden('Invalid sync token');
      try {
        final masterKey = await _ref.read(masterKeyProvider.future);
        final fallbacks = await _ref.read(fallbackKeysProvider.future);
        final userKeyPair = await _ref.read(userKeyPairProvider.future);
        if (masterKey == null) return Response.forbidden('Master key not ready');
        
        final repository = _ref.read(vaultRepositoryProvider);
        final items = await repository.getAllItems(masterKey, includeDeleted: true, fallbacks: fallbacks, userKeyPair: userKeyPair);
        
        final encryptedPayload = await _encryptPayload(items);
        return Response.ok(jsonEncode({
          'payload': encryptedPayload,
          'deviceId': _myDeviceId,
        }), headers: {'content-type': 'application/json'});
      } catch (e) {
        return Response.internalServerError(body: e.toString());
      }
    });

    // Push items to this device (requires auth token)
    router.post('/push', (Request request) async {
      if (!_checkAuth(request)) return Response.forbidden('Invalid sync token');
      try {
        final payload = await request.readAsString();
        final Map<String, dynamic> body = jsonDecode(payload);
        final encryptedData = body['payload'] as String;
        
        final items = await _decryptPayload(encryptedData);
        await _mergeVaultItems(items);
        return Response.ok('OK');
      } catch (e) {
        return Response.internalServerError(body: e.toString());
      }
    });

    // Share: Get Public Key
    router.get('/share/info', (Request request) async {
      final masterState = _ref.read(masterPasswordProvider);
      return Response.ok(jsonEncode({
        'deviceId': _myDeviceId,
        'deviceName': _myDeviceName,
        'userPublicKey': masterState.userPublicKey,
      }), headers: {'content-type': 'application/json'});
    });

    // Share: Receive Join Request
    router.post('/share/join-request', (Request request) async {
      try {
        final payload = await request.readAsString();
        debugPrint('📥 Received join request: $payload');
        
        final Map<String, dynamic> json = jsonDecode(payload);
        
        // 记录申请方的来源 IP，确保回调能送达
        final connectionInfo = request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
        final remoteIp = connectionInfo?.remoteAddress.address;
        
        if (json['senderHost'] == null && remoteIp != null) {
          json['senderHost'] = remoteIp;
        }
        
        final req = LanJoinRequest.fromJson(json);
        
        // Add to pending requests
        _pendingJoinRequests.removeWhere((r) => r.deviceId == req.deviceId);
        _pendingJoinRequests.add(req);
        _joinRequestsController.add(List.from(_pendingJoinRequests));
        
        // 如果是发送方通过轮询来检查状态，这里可以先记录请求
        return Response.ok(jsonEncode({'status': 'pending', 'remoteIp': remoteIp}), 
          headers: {'content-type': 'application/json'});
      } catch (e) {
        return Response.internalServerError(body: e.toString());
      }
    });

    // 新增：申请方主动检查申请状态的接口（防止被动通知失败）
    router.get('/share/check-status', (Request request) async {
      try {
        final deviceId = request.url.queryParameters['deviceId'];
        final vaultId = request.url.queryParameters['vaultId'];
        
        if (deviceId == null) return Response.badRequest(body: 'Missing deviceId');

        // 检查该设备是否有已通过但未通知成功的申请
        final repository = _ref.read(vaultRepositoryProvider);
        final members = await repository.getAllSharedMembers();
        
        // 查找该设备作为成员且角色不是 owner 的记录（说明是申请者）
        final member = members.firstWhere(
          (m) => m.userPublicKey != _ref.read(masterPasswordProvider).userPublicKey && 
                 (vaultId == null || vaultId.isEmpty || m.vaultId == vaultId),
          orElse: () => throw Exception('Not found'),
        );

        final userKeyPair = await _ref.read(userKeyPairProvider.future);
        if (userKeyPair == null) return Response.forbidden('User key pair not ready');
        final vaults = await repository.getSharedVaults(userKeyPair);
        final vault = vaults.firstWhere((v) => v.id == member.vaultId);

        return Response.ok(jsonEncode({
          'status': 'approved',
          'vaultId': vault.id,
          'vaultName': vault.name,
          'encryptedVaultKey': member.encryptedVaultKey,
          'ownerPublicKey': _ref.read(masterPasswordProvider).userPublicKey!,
          'ownerName': _myDeviceName,
          'ownerDeviceId': _myDeviceId,
        }), headers: {'content-type': 'application/json'});
      } catch (e) {
        return Response.ok(jsonEncode({'status': 'pending'}), headers: {'content-type': 'application/json'});
      }
    });

    // Share: Receive Approval (Guest side)
    router.post('/share/join-approve', (Request request) async {
      try {
        final payload = await request.readAsString();
        debugPrint('📥 Received approval notification: $payload');
        final body = jsonDecode(payload);
        
        await _handleApproval(body);
        
        return Response.ok('OK');
      } catch (e) {
        return Response.internalServerError(body: e.toString());
      }
    });

    // Share: Get Discoverable Vaults
    router.get('/share/discoverable-vaults', (Request request) async {
      try {
        final repository = _ref.read(vaultRepositoryProvider);
        final userKeyPair = await _ref.read(userKeyPairProvider.future);
        if (userKeyPair == null) return Response.forbidden('User key pair not ready');
        
        final vaults = await repository.getSharedVaults(userKeyPair);
        final discoverableVaults = vaults.where((v) => v.isDiscoverable).map((v) => {
          'id': v.id,
          'name': v.name,
        }).toList();
        
        return Response.ok(jsonEncode(discoverableVaults), headers: {'content-type': 'application/json'});
      } catch (e) {
        return Response.internalServerError(body: e.toString());
      }
    });

    final handler = const Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(_corsMiddleware())
        .addHandler(router.call);

    try {
      // 优先尝试使用 8080 端口，方便手动连接
      _server = await io.serve(handler, InternetAddress.anyIPv4, 8080);
    } catch (e) {
      // 如果 8080 被占用，则使用随机端口
      _server = await io.serve(handler, InternetAddress.anyIPv4, 0);
    }
    debugPrint('Sync server running on port ${_server!.port}');

    // 2. Register Service
    // Use a unique name to avoid collisions on the network
    final uniqueName = '$_myDeviceName (${_myDeviceId!.substring(0, 4)})';
    _registration = await register(Service(
      name: uniqueName,
      type: _serviceType,
      port: _server!.port,
      txt: {'id': Uint8List.fromList(utf8.encode(_myDeviceId!))},
    ));

    // 3. Start Discovery
    _discovery = await startDiscovery(_serviceType);
    _discovery!.addListener(() {
      _updateDevices(_discovery!.services);
    });
  }

  Future<void> stop() async {
    if (_registration != null) {
      await unregister(_registration!);
      _registration = null;
    }
    
    if (_discovery != null) {
      await stopDiscovery(_discovery!);
      _discovery = null;
    }
    
    await _server?.close(force: true);
    _server = null;
    
    _discoveredDevices.clear();
    _devicesController.add([]);
    _deviceVaults.clear();
    _discoverableVaultsController.add([]);
  }

  Future<void> sendJoinRequest(SyncDevice device, {String? vaultId, String? vaultName}) async {
    final masterState = _ref.read(masterPasswordProvider);
    if (masterState.userPublicKey == null) throw Exception('请先设置主密码以生成密钥对');

    final localIps = await getLocalIps();

    final req = LanJoinRequest(
      deviceId: _myDeviceId!,
      deviceName: _myDeviceName!,
      userPublicKey: masterState.userPublicKey!,
      vaultId: vaultId,
      vaultName: vaultName,
      senderPort: _server?.port,
      senderHost: localIps.isNotEmpty ? localIps.first : null,
      timestamp: DateTime.now(),
    );

    debugPrint('🚀 Sending join request to http://${device.host}:${device.port}/share/join-request');
    final response = await http.post(
      Uri.parse('http://${device.host}:${device.port}/share/join-request'),
      body: jsonEncode(req.toJson()),
    );

    if (response.statusCode != 200) {
      throw Exception('发送加入请求失败: ${response.body}');
    }

    // 添加到已发送请求列表
    final sentReq = SentJoinRequest(
      deviceId: device.id,
      deviceName: device.name,
      vaultId: vaultId,
      vaultName: vaultName,
      timestamp: DateTime.now(),
    );
    
    _sentJoinRequests.removeWhere((r) => r.deviceId == device.id && r.vaultId == vaultId);
    _sentJoinRequests.add(sentReq);
    _sentRequestsController.add(List.from(_sentJoinRequests));

    // 启动轮询检查状态，以防被动通知失败
    _startPollingStatus(device, sentReq);
  }

  // 新增轮询状态方法
  void _startPollingStatus(SyncDevice ownerDevice, SentJoinRequest sentReq) {
    Timer.periodic(const Duration(seconds: 5), (timer) async {
      // 如果状态已经是已通过，或者请求被手动清除，停止轮询
      if (sentReq.status == JoinRequestStatus.approved || !_sentJoinRequests.contains(sentReq)) {
        timer.cancel();
        return;
      }

      try {
        debugPrint('🔍 Polling status from http://${ownerDevice.host}:${ownerDevice.port}/share/check-status');
        final response = await http.get(
          Uri.parse('http://${ownerDevice.host}:${ownerDevice.port}/share/check-status?deviceId=$_myDeviceId&vaultId=${sentReq.vaultId ?? ""}'),
        ).timeout(const Duration(seconds: 3));

        if (response.statusCode == 200) {
          final body = jsonDecode(response.body);
          if (body['status'] == 'approved') {
            timer.cancel();
            debugPrint('✅ Polling: Request approved!');
            
            // 模拟收到批准通知的处理逻辑
            await _handleApproval(body);
          }
        }
      } catch (e) {
        // 轮询失败可能是对方暂时离线，继续尝试
        debugPrint('Polling failed (retrying): $e');
      }
    });
  }

  // 将批准处理逻辑抽取出来复用
  Future<void> _handleApproval(Map<String, dynamic> body) async {
    final vaultId = body['vaultId'] as String;
    final vaultName = body['vaultName'] as String;
    final encryptedVaultKey = body['encryptedVaultKey'] as String;
    final ownerPublicKey = body['ownerPublicKey'] as String;
    final ownerName = body['ownerName'] as String;

    final repository = _ref.read(vaultRepositoryProvider);
    final userKeyPair = await _ref.read(userKeyPairProvider.future);
    if (userKeyPair == null) return;

    final publicKey = await userKeyPair.extractPublicKey();
    final myPublicKeyBase64 = base64.encode(publicKey.bytes);

    // 检查是否已经存在该库，避免重复添加
    final existingVaults = await repository.getSharedVaults(userKeyPair);
    if (existingVaults.any((v) => v.id == vaultId)) {
      debugPrint('ℹ️ Vault $vaultId already exists, skipping creation');
    } else {
      // 1. 保存库信息
      await repository.addSharedVaults([
        SharedVault(
          id: vaultId,
          name: vaultName,
          encryptedVaultKey: encryptedVaultKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        )
      ]);

      // 2. 保存成员信息（自己）
      await repository.addSharedMembers([
        SharedMember(
          id: const Uuid().v4(),
          vaultId: vaultId,
          userPublicKey: myPublicKeyBase64,
          encryptedVaultKey: encryptedVaultKey,
          role: SharedMemberRole.editor,
          name: _myDeviceName,
        )
      ]);

      // 3. 保存房主信息
      await repository.addSharedMembers([
        SharedMember(
          id: const Uuid().v4(),
          vaultId: vaultId,
          userPublicKey: ownerPublicKey,
          encryptedVaultKey: '',
          role: SharedMemberRole.owner,
          name: ownerName,
        )
      ]);
    }

    // Refresh vault items
    _ref.invalidate(sharedVaultsProvider);
    _ref.read(vaultItemsProvider.notifier).refresh();

    // 如果可能，触发一次同步以拉取数据
    final ownerDeviceId = body['ownerDeviceId'];
    final ownerDevice = _discoveredDevices.values.firstWhere(
      (d) => d.id == ownerDeviceId || d.name.contains(ownerName),
      orElse: () => SyncDevice(id: '', name: ownerName, host: '', port: 0, lastSeen: DateTime.now()),
    );
    if (ownerDevice.host.isNotEmpty) {
      syncWithDevice(ownerDevice).catchError((e) => debugPrint('Initial sync failed: $e'));
    }

    // 更新已发送请求的状态
    for (var req in _sentJoinRequests) {
      if (req.vaultId == vaultId || (req.vaultId == null && vaultId.isNotEmpty)) {
        req.status = JoinRequestStatus.approved;
      }
    }
    _sentRequestsController.add(List.from(_sentJoinRequests));
    notifyListeners();
  }

  Future<void> approveJoinRequest(LanJoinRequest request, String vaultId, String vaultName) async {
    final userKeyPair = await _ref.read(userKeyPairProvider.future);
    if (userKeyPair == null) throw Exception('无法获取当前用户的密钥对');

    // 1. 获取 VaultKey
    final repository = _ref.read(vaultRepositoryProvider);
    final vaultKey = await repository.getSharedVaultKey(vaultId, userKeyPair);
    if (vaultKey == null) throw Exception('无法获取共享库密钥');

    // 2. 用申请者的公钥加密 VaultKey
    final encryptionService = _ref.read(encryptionServiceProvider);
    final requesterPublicKeyBytes = base64.decode(request.userPublicKey);
    
    final vaultKeyBase64 = base64.encode(await vaultKey.extractBytes());
    final encryptedVaultKeyForRequester = await encryptionService.encryptWithPublicKey(
      utf8.encode(vaultKeyBase64),
      requesterPublicKeyBytes,
    );

    // 3. 将申请者添加为成员
    await repository.addSharedMembers([
      SharedMember(
        id: "${vaultId}_${request.deviceId}",
        vaultId: vaultId,
        userPublicKey: request.userPublicKey,
        encryptedVaultKey: base64.encode(encryptedVaultKeyForRequester),
        role: SharedMemberRole.editor,
        name: request.deviceName,
      )
    ]);

    // 4. 通知申请者已通过
    var device = _discoveredDevices[request.deviceId];
    String? targetHost = device?.host ?? request.senderHost;
    int? targetPort = device?.port ?? request.senderPort;

    if (targetHost != null && targetPort != null) {
      try {
        debugPrint('🚀 Sending approval to http://$targetHost:$targetPort/share/join-approve');
        final notifyResponse = await http.post(
          Uri.parse('http://$targetHost:$targetPort/share/join-approve'),
          body: jsonEncode({
            'vaultId': vaultId,
            'vaultName': vaultName,
            'encryptedVaultKey': base64.encode(encryptedVaultKeyForRequester),
            'ownerPublicKey': _ref.read(masterPasswordProvider).userPublicKey!,
            'ownerName': _myDeviceName,
            'ownerDeviceId': _myDeviceId,
          }),
        ).timeout(const Duration(seconds: 10));
        
        if (notifyResponse.statusCode == 200) {
          debugPrint('✅ Requester notified successfully');
        } else {
          debugPrint('❌ Failed to notify requester: ${notifyResponse.statusCode} ${notifyResponse.body}');
        }
      } catch (e) {
        debugPrint('❌ Error notifying requester at $targetHost:$targetPort: $e');
      }
    } else {
      debugPrint('⚠️ Cannot notify requester: Target host/port unknown. Host: $targetHost, Port: $targetPort');
    }

    // 从待处理列表中移除
    _pendingJoinRequests.removeWhere((r) => r.deviceId == request.deviceId);
    _joinRequestsController.add(List.from(_pendingJoinRequests));
  }

  void rejectJoinRequest(LanJoinRequest request) {
    _pendingJoinRequests.removeWhere((r) => r.deviceId == request.deviceId);
    _joinRequestsController.add(List.from(_pendingJoinRequests));
  }

  void clearSentRequests() {
    _sentJoinRequests.clear();
    _sentRequestsController.add([]);
  }

  void _updateDevices(List<Service> services) {
    final now = DateTime.now();
    final Map<String, SyncDevice> newDiscoveredDevices = {};
    final Set<String> currentServiceIds = {};
    
    debugPrint('🔍 Found ${services.length} services on network');
    
    for (final service in services) {
      final txt = service.txt;
      final idBytes = txt?['id'];
      if (idBytes == null) {
        debugPrint('  - Service ${service.name} has no ID in TXT records');
        continue;
      }
      final id = utf8.decode(idBytes);
      if (id == _myDeviceId) continue;
      
      currentServiceIds.add(id);
      final host = service.host;
      final port = service.port;
      
      if (host == null || port == null) {
        debugPrint('  - Service ${service.name} ($id) host or port is null, waiting for resolution...');
        continue;
      }
      
      debugPrint('  - Device discovered: ${service.name} at $host:$port');
      
      // Keep existing device to preserve public key if already fetched
      final existingDevice = _discoveredDevices[id];
      final device = SyncDevice(
        id: id,
        name: service.name ?? 'Unknown Device',
        host: host,
        port: port,
        userPublicKey: existingDevice?.userPublicKey,
        lastSeen: now,
      );
      
      newDiscoveredDevices[id] = device;

      // Fetch discoverable vaults if we don't have them or they might have changed
      _fetchDeviceDetails(device);

      // Auto sync if enabled
      if (_isEnabled) {
        syncWithDevice(device).catchError((e) {
          // ignore: avoid_print
          print('Auto-sync failed with ${device.name}: $e');
        });
      }
    }

    // Remove devices that are no longer present
    _discoveredDevices.clear();
    _discoveredDevices.addAll(newDiscoveredDevices);
    
    final deviceIdsToRemove = _deviceVaults.keys.where((id) => !currentServiceIds.contains(id)).toList();
    for (final id in deviceIdsToRemove) {
      _deviceVaults.remove(id);
    }
    
    _devicesController.add(_discoveredDevices.values.toList());
    _refreshDiscoverableVaults();
  }

  Future<SecretKey?> _getSyncKey() async {
    final password = _ref.read(masterPasswordProvider).password;
    if (password == null) return null;
    final encryptionService = _ref.read(encryptionServiceProvider);
    final salt = utf8.encode('PasswordVault_LAN_Sync_Salt_v1');
    return await encryptionService.deriveKey(password, salt, iterations: 2, memory: 32 * 1024, parallelism: 1);
  }

  Future<String> _encryptPayload(List<VaultItem> items) async {
    final syncKey = await _getSyncKey();
    if (syncKey == null) throw Exception('未设置主密码');
    
    final encryptionService = _ref.read(encryptionServiceProvider);
    final jsonString = jsonEncode(items.map((e) => e.toJson()).toList());
    final encryptedBytes = await encryptionService.encrypt(jsonString, syncKey);
    return base64.encode(encryptedBytes);
  }

  Future<List<VaultItem>> _decryptPayload(String payload) async {
    final syncKey = await _getSyncKey();
    if (syncKey == null) throw Exception('未设置主密码');
    
    final encryptionService = _ref.read(encryptionServiceProvider);
    final encryptedBytes = base64.decode(payload);
    try {
      final decryptedJson = await encryptionService.decrypt(encryptedBytes, syncKey);
      final List<dynamic> list = jsonDecode(decryptedJson);
      return list.map((e) => VaultItem.fromJson(e)).toList();
    } catch (e) {
      if (e.toString().contains('MAC') || e.toString().contains('authentication')) {
        throw Exception('同步失败：对方设备的主密码与本地不一致');
      }
      rethrow;
    }
  }

  void _refreshDiscoverableVaults() {
    final allVaults = _deviceVaults.values.expand((v) => v).toList();
    _discoverableVaultsController.add(allVaults);
  }

  Future<void> _fetchDeviceDetails(SyncDevice device) async {
    try {
      // Handle IPv6 addresses by wrapping them in square brackets for the URI
      final String host = device.host.contains(':') ? '[${device.host}]' : device.host;
      
      // 1. Fetch Device Info (Public Key)
      if (device.userPublicKey == null) {
        final infoResponse = await http.get(
          Uri.parse('http://$host:${device.port}/share/info'),
        ).timeout(const Duration(seconds: 3));

        if (infoResponse.statusCode == 200) {
          final info = jsonDecode(infoResponse.body);
          final publicKey = info['userPublicKey'] as String?;
          if (publicKey != null) {
            _discoveredDevices[device.id] = device.copyWith(userPublicKey: publicKey);
            _devicesController.add(_discoveredDevices.values.toList());
          }
        }
      }

      // 2. Fetch Discoverable Vaults
      final response = await http.get(
        Uri.parse('http://$host:${device.port}/share/discoverable-vaults'),
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        final vaults = data.map((v) => DiscoverableVault(
          id: v['id'],
          name: v['name'],
          device: _discoveredDevices[device.id] ?? device,
        )).toList();

        _deviceVaults[device.id] = vaults;
        _refreshDiscoverableVaults();
      }
    } catch (e) {
      debugPrint('Failed to fetch details for ${device.name}: $e');
    }
  }

  Future<void> syncWithDevice(SyncDevice device) async {
    if (_syncingDevices.contains(device.id)) return;
    _syncingDevices.add(device.id);
    
    try {
      // 1. 从远程拉取并合并
      final pullUrl = Uri.http('${device.host}:${device.port}', '/pull');
      final pullResponse = await http.get(pullUrl, headers: {
        if (_syncToken != null) 'x-sync-token': _syncToken!,
      }).timeout(const Duration(seconds: 10));
      
      if (pullResponse.statusCode == 200) {
        final dynamic decoded = jsonDecode(pullResponse.body);
        if (decoded is! Map) {
          throw Exception('无效的响应格式：期望 Map');
        }
        final Map<String, dynamic> body = Map<String, dynamic>.from(decoded);
        final encryptedData = body['payload']?.toString();
        if (encryptedData == null) {
          throw Exception('无效的响应数据：payload 为空');
        }
        final remoteItems = await _decryptPayload(encryptedData);
        await _mergeVaultItems(remoteItems);
      } else {
        throw Exception('从远程拉取失败: ${pullResponse.statusCode}');
      }

      // 2. 推送本地到远程
      final masterKey = await _ref.read(masterKeyProvider.future);
      if (masterKey == null) throw Exception('主密钥尚未就绪');

      final repository = _ref.read(vaultRepositoryProvider);
      final items = await repository.getAllItems(masterKey, includeDeleted: true);
      final encryptedPayload = await _encryptPayload(items);
      
      final pushUrl = Uri.http('${device.host}:${device.port}', '/push');
      final pushResponse = await http.post(
        pushUrl,
        headers: {
          'Content-Type': 'application/json',
          if (_syncToken != null) 'x-sync-token': _syncToken!,
        },
        body: jsonEncode({
          'payload': encryptedPayload,
          'deviceId': _myDeviceId,
        }),
      ).timeout(const Duration(seconds: 10));
      
      if (pushResponse.statusCode != 200) {
        throw Exception('推送到远程失败: ${pushResponse.statusCode}');
      }
      
      _syncStatusController.add(true);
    } catch (e) {
      debugPrint('Sync error: $e');
      rethrow;
    } finally {
      _syncingDevices.remove(device.id);
    }
  }

  Future<void> connectToAddress(String host, int port) async {
    try {
      debugPrint('Attempting manual connection to $host:$port');
      
      // 在 Web 端，Uri.http 可能需要特殊处理或检查
      final statusUrl = Uri.http('$host:$port', '/status');
      
      final response = await http.get(statusUrl).timeout(const Duration(seconds: 5));
      
      debugPrint('Manual connection response: ${response.statusCode}');
      if (response.statusCode == 200) {
        final dynamic decoded = jsonDecode(response.body);
        if (decoded is! Map) {
          throw Exception('无效的响应格式');
        }
        final Map<String, dynamic> status = Map<String, dynamic>.from(decoded);
        
        final device = SyncDevice(
          id: status['id']?.toString() ?? 'unknown_id',
          name: status['name']?.toString() ?? '未知设备',
          host: host,
          port: port,
          lastSeen: DateTime.now(),
        );
        
        await syncWithDevice(device);
      } else {
        throw Exception('无法连接到设备: HTTP ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Manual connection error: $e');
      
      if (e is TimeoutException) {
        throw Exception('连接超时，请确保设备在同一局域网并已开启同步。注意：部分浏览器可能拦截跨域请求 (CORS)。');
      }
      
      final errorStr = e.toString();
      if (errorStr.contains('XMLHttpRequest error') || errorStr.contains('CORS')) {
        throw Exception('网络连接错误或跨域拦截。请确保对方设备已开启“同步”并允许来自此地址的访问。');
      }
      
      if (errorStr.contains('Connection refused') || errorStr.contains('Failed host lookup')) {
        throw Exception('无法连接到目标地址，请检查 IP 和端口是否正确。');
      }
      
      throw Exception('连接失败: $e');
    }
  }

  Future<void> _mergeVaultItems(List<VaultItem> remoteItems) async {
    final masterKey = await _ref.read(masterKeyProvider.future);
    if (masterKey == null) throw Exception('主密钥尚未就绪');
    
    final repository = _ref.read(vaultRepositoryProvider);
    
    // 获取本地所有项（包括已删除的）以便进行比较
    final localItems = await repository.getAllItems(masterKey, includeDeleted: true);
    final localMap = {for (var item in localItems) item.id: item};

    for (final remote in remoteItems) {
      final local = localMap[remote.id];
      
      // 如果本地没有，或者远程更新时间更晚，则更新本地
      bool shouldUpdate = false;
      if (local == null) {
        shouldUpdate = true;
      } else if (remote.updatedAt != null && local.updatedAt != null) {
        if (remote.updatedAt!.isAfter(local.updatedAt!)) {
          shouldUpdate = true;
        }
      } else if (remote.updatedAt != null && local.updatedAt == null) {
        shouldUpdate = true;
      }

      if (shouldUpdate) {
        if (local == null) {
          await repository.addItem(remote, masterKey);
        } else {
          await repository.updateItem(remote, masterKey);
        }
      }
    }
  }

  Middleware _corsMiddleware() {
    return (Handler innerHandler) {
      return (Request request) async {
        if (request.method == 'OPTIONS') {
          return Response.ok('', headers: {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Origin, Content-Type, Accept, Authorization',
            'Access-Control-Allow-Private-Network': 'true',
          });
        }
        
        final response = await innerHandler(request);
        return response.change(headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
          'Access-Control-Allow-Headers': 'Origin, Content-Type, Accept, Authorization',
        });
      };
    };
  }

  @override
  void dispose() {
    stop();
    _devicesController.close();
    _discoverableVaultsController.close();
    _syncStatusController.close();
    _joinRequestsController.close();
    _sentRequestsController.close();
    super.dispose();
  }
}
