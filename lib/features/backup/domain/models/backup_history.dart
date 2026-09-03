class BackupHistory {
  final String fileName;
  final DateTime createdAt;
  final int size;

  BackupHistory({
    required this.fileName,
    required this.createdAt,
    required this.size,
  });

  factory BackupHistory.fromWebDav(String name, DateTime date, int size) {
    return BackupHistory(fileName: name, createdAt: date, size: size);
  }
}
