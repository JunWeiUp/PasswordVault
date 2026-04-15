import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/local_sync_service.dart';
import '../../../vault/presentation/providers/vault_provider.dart';

final localSyncServiceProvider = ChangeNotifierProvider<LocalSyncService>((ref) {
  final service = LocalSyncService(ref);
  return service;
});

final syncDevicesProvider = StreamProvider<List<SyncDevice>>((ref) {
  return ref.watch(localSyncServiceProvider).devicesStream;
});

final discoverableVaultsProvider = StreamProvider<List<DiscoverableVault>>((ref) {
  return ref.watch(localSyncServiceProvider).discoverableVaultsStream;
});

final syncStatusProvider = StreamProvider<bool>((ref) {
  final stream = ref.watch(localSyncServiceProvider).syncStatusStream;
  stream.listen((_) {
    // When sync completes, refresh vault items
    ref.read(vaultItemsProvider.notifier).refresh();
  });
  return stream;
});

final lanJoinRequestsProvider = StreamProvider<List<LanJoinRequest>>((ref) {
  return ref.watch(localSyncServiceProvider).joinRequestsStream;
});

final sentJoinRequestsProvider = StreamProvider<List<SentJoinRequest>>((ref) {
  return ref.watch(localSyncServiceProvider).sentRequestsStream;
});
