/// Supabase-compatible auth session.
class Session {
  const Session({
    required this.accessToken,
    required this.tokenType,
    required this.expiresIn,
    this.expiresAt,
    this.refreshToken,
  });

  final String accessToken;
  final String tokenType;

  /// Lifetime of the access token in seconds (from issue time).
  final int expiresIn;

  /// Unix timestamp (seconds) when the token expires.
  final int? expiresAt;

  final String? refreshToken;

  bool get isExpired {
    final at = expiresAt;
    if (at == null) return false;
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 >= at;
  }

  factory Session.fromJson(Map<String, dynamic> json) => Session(
        accessToken: json['access_token'] as String,
        tokenType: (json['token_type'] as String?) ?? 'bearer',
        expiresIn: (json['expires_in'] as num?)?.toInt() ?? 3600,
        expiresAt: (json['expires_at'] as num?)?.toInt(),
        refreshToken: json['refresh_token'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'token_type': tokenType,
        'expires_in': expiresIn,
        if (expiresAt != null) 'expires_at': expiresAt,
        if (refreshToken != null) 'refresh_token': refreshToken,
      };
}
