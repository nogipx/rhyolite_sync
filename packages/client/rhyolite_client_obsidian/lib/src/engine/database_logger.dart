import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:uuid/uuid.dart';

class DatabaseLogOutput extends LogOutput {
  DatabaseLogOutput(this.name, this._client);

  final String name;
  final IDataClient _client;

  @override
  void write(LogRecord record) {
    if (record is! LogEvent) return;
    _writeLog(record.level, record.message, record.error, record.data);
  }

  void _writeLog(
    RpcLogLevel level,
    String message,
    Object? error,
    Map<String, Object>? data,
  ) {
    try {
      print(message);
      _client.create(
        collection: 'logs',
        id: const Uuid().v4(),
        payload: {
          'timestamp': DateTime.now().toIso8601String(),
          'level': level.name,
          'logger': name,
          'message': message,
          if (error != null) 'error': error.toString(),
          if (data != null) ...data,
        },
      );
    } catch (e) {
      // Ignore log write errors (collection constraints, etc)
      // Silent fail for logging to not break the app
    }
  }
}