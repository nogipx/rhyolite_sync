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

  /// Non-secret backend discriminator (`s3` / `webdav`). Persisted locally as
  /// [VaultConfig.externalStorageKind] so a device knows it is BYO even though
  /// the secret config lives only on the (E2EE) server — used to pause sync
  /// rather than fall back to the managed backend when the fetch fails.
  String get kind;

  /// Creates blob storage. Pass [httpClient] to override the default
  /// HTTP client (e.g. to bypass CORS in Obsidian/Electron).
  IBlobStorage createBlobStorage({
    required String vaultId,
    http.Client? httpClient,
  });
}
