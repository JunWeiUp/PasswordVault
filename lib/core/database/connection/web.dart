import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';
import 'dart:html' as html;

QueryExecutor connect() {
  return DatabaseConnection.delayed(() async {
    // In Chrome extension, we need the full URL for WASM and worker
    String sqlite3Uri = 'sqlite3.wasm';
    String driftWorkerUri = 'drift_worker.js';

    // Try to detect if we are in a chrome extension and get the full URL
    final isExtension = html.window.location.protocol.startsWith('chrome-extension');
    
    final result = await WasmDatabase.open(
      databaseName: 'secure_pass_db',
      sqlite3Uri: Uri.parse(sqlite3Uri),
      driftWorkerUri: Uri.parse(driftWorkerUri),
    );

    return result.resolvedExecutor;
  }());
}
