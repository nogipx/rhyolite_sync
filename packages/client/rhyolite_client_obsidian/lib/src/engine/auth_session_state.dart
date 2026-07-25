import 'package:rhyolite_client_account/rhyolite_client_account.dart'
    hide VaultInfo;
import 'package:rhyolite_sync/rhyolite_sync.dart';

import '../vault/managed_vault_directory.dart';
import '../vault/vault_directory.dart';

/// Single source of truth for "who is signed in" for one plugin session.
///
/// Everything that depends on the session — the engine's bearer token, the
/// vault directory behind the picker, the external-blob meta store — is
/// derived here and read back through this object, never copied into
/// caller-local variables.
///
/// That rule exists because both halves of it were broken at once, and a
/// re-sign-in silently failed to reach the engine:
///
///  1. The account client was passed *by value* into the settings
///     registrar, so the browser-auth callback updated only the
///     registrar's copy. Every other consumer — above all the
///     auth-recovery listener — kept reading its own `null` and treated
///     the fresh session as absent, so it cleared the just-saved session
///     and re-prompted for sign-in.
///  2. The bearer provider was rebuilt per sign-in and written into
///     `engine.config`, but a live connection captures its provider once
///     at connect time, so the socket kept sending unauthenticated calls.
///
/// Hence: one instance, held by reference, carrying one
/// [MutableTokenProvider] that is created once and mutated in place.
class AuthSessionState {
  AuthSessionState({required this.selfHost});

  /// Self-host edition: the token is a static shared secret and there is
  /// no account client at all. Kept here so [bindAccount] can't quietly
  /// unbind a self-host token from a managed code path.
  final bool selfHost;

  /// The one provider the engine's config ever holds. Handed out
  /// unconditionally — even signed out — so a call made without a session
  /// fails locally with [MissingAuthTokenException] instead of going to
  /// the server with no Authorization header (which comes back as a plain
  /// `unauthenticated` and reads exactly like a dead session).
  final MutableTokenProvider tokenProvider = MutableTokenProvider();

  RpcAccountClient? _client;
  IVaultDirectory? _directory;
  IVaultMetaStorage? _metaStorage;

  /// Live account client (managed edition), or null when signed out.
  RpcAccountClient? get client => _client;

  /// Vault source behind the picker: account service (managed) or the
  /// sync server's registry (self-host).
  IVaultDirectory? get directory => _directory;

  /// Backing store for the engine's encrypted external-blob config.
  IVaultMetaStorage? get metaStorage => _metaStorage;

  /// True when a token can currently be produced. Self-host is bound from
  /// boot; managed only once a session exists.
  bool get hasToken => tokenProvider.isBound;

  /// Managed edition: adopt [client] (sign-in / refresh) or drop it
  /// (sign-out). Rebinds the token provider **in place**, so connections
  /// opened before this call authenticate on their next request.
  void bindAccount(RpcAccountClient? client) {
    if (selfHost) return;
    _client = client;
    tokenProvider.delegate = client == null
        ? null
        : RpcAccountClientTokenProvider(client);
    _directory = client == null ? null : ManagedVaultDirectory(client);
    _metaStorage = client == null ? null : AccountVaultMetaStorage(client);
  }

  /// Self-host edition: bind the shared-secret token. The registry
  /// connection that backs [directory] is established separately (and may
  /// fail), so it arrives later via [bindSelfHostRegistry].
  void bindSelfHostToken(String token) {
    tokenProvider.delegate = StaticTokenProvider(token);
  }

  /// Self-host edition: adopt the vault registry once its connection is up.
  void bindSelfHostRegistry({
    required IVaultDirectory directory,
    required IVaultMetaStorage metaStorage,
  }) {
    _directory = directory;
    _metaStorage = metaStorage;
  }
}
