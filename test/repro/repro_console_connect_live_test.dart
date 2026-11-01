// Live-network repro for the agent console connect hang.
//
// Connects to the REAL sshd (host/port from env) with a throwaway key,
// exercising the exact SshClient.connect path the console uses - first the
// old FULL connect (with persistent-shell startup), then the lightweight
// connect, then HerdrPaneIO.listPanes / paneInfoById over that connection.
//
// Run:
//   CONSOLE_SSH_HOST=127.0.0.1 CONSOLE_SSH_PORT=122 \
//   CONSOLE_SSH_KEY=/tmp/muxpod_probe_key \
//   flutter test test/repro/repro_console_connect_live_test.dart -t live-sshd
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' as ft;

import 'package:flutter_muxpod/services/agent/agent_transport.dart';
import 'package:flutter_muxpod/services/agent/pane_io.dart';
import 'package:flutter_muxpod/services/ssh/ssh_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real ed25519 host key fingerprint of the test target (sshd:122).
const _hostKeyFingerprint =
    'SHA256:OMfHrsAXjlrGBQz1P/UQpYeaxZ6tGW8cgYshJiY/X2A';

void _mockSecureStorage() {
  // mux-pod's host-key verification reads known fingerprints through
  // flutter_secure_storage; in the test VM there is no plugin backend, so
  // serve the real fingerprint for the host-key lookup.
  ft.TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  ft
      .TestWidgetsFlutterBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    if (call.method == 'read') {
      final key = call.arguments['key'] as String?;
      if (key != null && key.startsWith('host_key_')) {
        return _hostKeyFingerprint;
      }
      return null;
    }
    if (call.method == 'containsKey') return false;
    return null;
  });
}

void main() {
  _mockSecureStorage();
  final host = Platform.environment['CONSOLE_SSH_HOST'] ?? '127.0.0.1';
  final port = int.parse(Platform.environment['CONSOLE_SSH_PORT'] ?? '122');
  final keyPath =
      Platform.environment['CONSOLE_SSH_KEY'] ?? '/tmp/muxpod_probe_key';

  test('console connect path against the real sshd', tags: 'live-sshd',
      () async {
    final privateKey = File(keyPath).readAsStringSync();

    Future<void> tryConnect({required bool lightweight}) async {
      final client = SshClient();
      final sw = Stopwatch()..start();
      print('--- connect (lightweight=$lightweight) to $host:$port ...');
      await client
          .connect(
            host: host,
            port: port,
            username: 'vincent',
            options: SshConnectOptions(
              privateKey: privateKey,
              acceptNewHostKeys: true,
            ),
            lightweight: lightweight,
            l10n: null,
          )
          .timeout(const Duration(seconds: 30));
      print('    connected in ${sw.elapsedMilliseconds}ms '
          '(isConnected=${client.isConnected})');

      final transport = SshAgentTransport(client);
      final paneIO = HerdrPaneIO(transport, herdrBin: 'herdr');
      sw
        ..reset()
        ..start();
      final panes = await paneIO.listPanes();
      print('    listPanes: ${panes.length} panes in '
          '${sw.elapsedMilliseconds}ms; agent panes: '
          '${panes.where((p) => p.command != null && p.command!.isNotEmpty).map((p) => '${p.id}=${p.command}').take(6).join(', ')}');
      sw
        ..reset()
        ..start();
      final vibePane = panes.firstWhere(
        (p) => p.command == 'vibe',
        orElse: () => panes.first,
      );
      final info = await paneIO.paneInfoById(vibePane.id);
      print('    paneInfoById(${vibePane.id}) in ${sw.elapsedMilliseconds}ms: '
          'command=${info?.command} path=${info?.path}');

      // Live-pane send path (to a THROWAWAY pane id so we touch nothing):
      final out = await transport.exec('echo probe-ok');
      print('    exec probe: ${out.trim()}');
      await client.disconnect();
    }

    await tryConnect(lightweight: false);
    await tryConnect(lightweight: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
