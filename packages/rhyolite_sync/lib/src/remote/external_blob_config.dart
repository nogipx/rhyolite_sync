import 'package:http/http.dart' as http;
import 'package:rhyolite_sync/rhyolite_sync.dart';

/// External blob storage configuration.
/// When set in VaultConfig, blobs are stored directly in the user's
/// own storage instead of proxying through the sync server.
abstract class ExternalBlobConfig {
  const ExternalBlobConfig();

  static ExternalBlobConfig? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return switch (json['type'] as String?) {
      's3' => S3BlobConfig.fromJson(json),
      'webdav' => WebDavBlobConfig.fromJson(json),
      _ => null,
    };
  }

  Map<String, dynamic> toJson();

  /// Creates blob storage. Pass [httpClient] to override the default
  /// HTTP client (e.g. to bypass CORS in Obsidian/Electron).
  IBlobStorage createBlobStorage({
    required String vaultId,
    http.Client? httpClient,
  });
}
