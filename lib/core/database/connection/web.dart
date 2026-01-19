import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

QueryExecutor connect() {
  return DatabaseConnection.delayed(() async {
    final result = await WasmDatabase.open(
      databaseName: 'secure_pass_db',
      sqlite3Uri: Uri.parse('sqlite3.wasm'),
      driftWorkerUri: Uri.parse('drift_worker.js'),
    );

    return result.resolvedExecutor;
  }());
}
