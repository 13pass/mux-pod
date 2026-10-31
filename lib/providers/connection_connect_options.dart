import '../l10n/app_localizations.dart';
import '../l10n/l10n_lookup.dart';
import '../services/keychain/secure_storage.dart';
import '../services/ssh/ssh_client.dart';
import '../services/ssh/ssh_proxy_options_resolver.dart';
import 'connection.dart';

/// 保存済み [Connection] から ad-hoc SSH 接続（Remote UI 等）の
/// [SshConnectOptions] を構築する共有ヘルパー。
///
/// 認証情報（パスワード/秘密鍵+パスフレーズ）は [SecureStorageService] から解決し、
/// ジャンプホストは [SshProxyOptionsResolver] で解決する。keepalive は
/// 「接続個別 > 全体設定」で解決する（[settingsKeepAliveTimeoutSeconds] が
/// null なら transport 側の自動式）。
///
/// 解決失敗（鍵読み取り不可・jump パスワード欠落等）は呼出元の
/// per-connection try 内で捕捉して処理を継続すること。
Future<SshConnectOptions> buildConnectionConnectOptions(
  Connection connection, {
  int? settingsKeepAliveTimeoutSeconds,
  SecureStorageService? storage,
  AppLocalizations? l10n,
}) async {
  final store = storage ?? SecureStorageService();
  final loc = l10n ?? lookupL10n();
  final proxyOptions = await const SshProxyOptionsResolver().resolve(
    connection.proxy,
    connectionId: connection.id,
    targetHost: connection.host,
    targetPort: connection.port,
    l10n: loc,
  );
  final keepAliveTimeoutSeconds =
      connection.keepAliveTimeoutSeconds ?? settingsKeepAliveTimeoutSeconds;
  if (connection.authMethod == 'key' && connection.keyId != null) {
    final privateKey = await store.getPrivateKey(connection.keyId!);
    final passphrase = await store.getPassphrase(connection.keyId!);
    return SshConnectOptions(
      privateKey: privateKey,
      passphrase: passphrase,
      multiplexer: connection.multiplexer,
      proxy: proxyOptions,
      keepAliveTimeoutSeconds: keepAliveTimeoutSeconds,
    );
  }
  final password = await store.getPassword(connection.id);
  return SshConnectOptions(
    password: password,
    multiplexer: connection.multiplexer,
    proxy: proxyOptions,
    keepAliveTimeoutSeconds: keepAliveTimeoutSeconds,
  );
}
