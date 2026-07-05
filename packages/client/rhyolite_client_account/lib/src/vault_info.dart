class VaultInfo {
  const VaultInfo({
    required this.vaultId,
    required this.vaultName,
    this.verificationToken,
  });

  final String vaultId;
  final String vaultName;

  /// Null if E2EE has not been set up for this vault yet.
  final String? verificationToken;

  factory VaultInfo.fromJson(Map<String, dynamic> json) => VaultInfo(
        vaultId: json['vault_id'] as String,
        vaultName: json['vault_name'] as String? ?? '',
        verificationToken: json['verification_token'] as String?,
      );
}
