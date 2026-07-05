import 'dart:convert';

import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

/// A single history record decrypted and ready for display.
class HistoryEntry {
  final String eventId;
  final String fileId;

  /// Relative path inside the vault at the time of this change. Recovered
  /// by decrypting the event's opaque metadata blob.
  final String path;
  final int sizeBytes;

  /// sha256 of the content version after this operation. Empty for
  /// deletions.
  final String blobRef;
  final HistoryOperation operation;
  final DateTime createdAt;
  final Hlc hlc;

  const HistoryEntry({
    required this.eventId,
    required this.fileId,
    required this.path,
    required this.sizeBytes,
    required this.blobRef,
    required this.operation,
    required this.createdAt,
    required this.hlc,
  });
}

/// Loads history events from the server, decrypts their per-event metadata
/// (path + sizeBytes), and returns ready-to-display [HistoryEntry] list.
///
/// Server stays opaque: it only sees fileId, hlc, op, blobRef in plain.
/// path/sizeBytes are only legible to clients holding the vault cipher.
class HistoryBrowser {
  HistoryBrowser({
    required this.historyCaller,
    required this.cipher,
    required this.vaultId,
  });

  final IHistoryContract historyCaller;
  final IVaultCipher cipher;
  final String vaultId;

  /// Fetch + decrypt events. [limit] caps the network and decryption cost
  /// — for typical vaults a few thousand events fit in milliseconds.
  Future<List<HistoryEntry>> list({
    String? fileId,
    int limit = 1000,
    bool ascending = false,
  }) async {
    final response = await historyCaller.getHistory(
      HistoryGetRequest(
        vaultId: vaultId,
        fileId: fileId,
        limit: limit,
        ascending: ascending,
      ),
    );
    final entries = <HistoryEntry>[];
    for (final event in response.events) {
      try {
        entries.add(await _decryptOne(event));
      } catch (_) {
        // Skip events we can't decrypt (corrupt encryptedMeta, key change).
      }
    }
    return entries;
  }

  Future<HistoryEntry> _decryptOne(HistoryEvent event) async {
    final encryptedBytes = base64Decode(event.encryptedMeta);
    final plain = await cipher.decrypt(encryptedBytes);
    final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    return HistoryEntry(
      eventId: event.eventId,
      fileId: event.fileId,
      path: json['path'] as String? ?? '<unknown>',
      sizeBytes: (json['sizeBytes'] as int?) ?? 0,
      blobRef: event.blobRef,
      operation: event.operation,
      createdAt: DateTime.fromMillisecondsSinceEpoch(event.createdAtMs),
      hlc: Hlc.unpack(event.hlcPacked),
    );
  }
}
