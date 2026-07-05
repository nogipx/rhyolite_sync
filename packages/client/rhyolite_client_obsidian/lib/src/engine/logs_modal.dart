import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rpc_data/rpc_data.dart';

Future<void> showLogsModal(
  PluginHandle plugin,
  IDataClient dataClient,
) async {
  return showModalWith<void>(
    plugin,
    build: (ctx) async {
      ctx.h3('Sync Logs');
      ctx.spaceVertical(px: 12);

      try {
        // Fetch logs and sort by timestamp DESC to get last 10000
        final response = await dataClient.list(
          collection: 'logs',
          options: const QueryOptions(limit: 10001),
        );

        final sorted = response.records.toList()
          ..sort((a, b) {
            final aTime = a.payload['timestamp'] as String? ?? '';
            final bTime = b.payload['timestamp'] as String? ?? '';
            return bTime.compareTo(aTime); // DESC
          });

        final logs = sorted.take(10000).toList();
        if (logs.isEmpty) {
          ctx.column((col) {
            col.createEl('p', text: 'No logs yet');
          });
        } else {
          for (final log in logs) {
            final data = log.payload;
            final timestamp = data['timestamp'] as String? ?? '';
            final level = data['level'] as String? ?? 'unknown';
            final logger = data['logger'] as String? ?? '';
            final message = data['message'] as String? ?? '';

            final lines = <String>[
              '${timestamp.substring(11, 19)} [${level.toUpperCase()}] [$logger] $message',
              if (data['error'] != null) '  Error: ${data['error']}',
            ];

            ctx.column((col) {
              col.createEl('p', text: lines.join('\n'));
            });
          }
        }
      } catch (e) {
        ctx.column((col) {
          col.createEl('p', text: 'Error loading logs: $e');
        });
      }

      ctx.spaceVertical(px: 16);
      ctx.buttonRow([
        ButtonSpec('Close', () => ctx.close(null)),
      ]);
    },
  );
}
