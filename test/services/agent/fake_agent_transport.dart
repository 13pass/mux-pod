import 'dart:async';
import 'dart:convert';

import 'package:flutter_muxpod/services/agent/agent_transport.dart';
import 'package:flutter_muxpod/services/agent/pane_io.dart';
import 'package:flutter_muxpod/services/command/command_result.dart';
import 'package:flutter_muxpod/services/agent/agent_config_service.dart';

/// Hand-written fake of [AgentTransport] for agent adapter tests.
///
/// Records every command sent through [sendKeysCommand] and emulates a
/// tiny remote filesystem for the two command shapes
/// [AgentConfigService] issues through [execWithExitCode]:
///
/// - `cat -- "<path>"` reads a file (exit code 1 when missing).
/// - The atomic-write pipeline (`printf ... | base64 -d > tmp && mv -f`)
///   writes a file and keeps a one-time `.muxpod-bak` backup.
class FakeAgentTransport implements AgentTransport {
  /// Emulated remote filesystem: absolute path -> file content.
  final Map<String, String> files;

  /// Every command passed to [execWithExitCode]/[exec]/[execPersistent],
  /// in order.
  final List<String> execCommands = [];

  /// Every command passed to [sendKeysCommand], in order.
  final List<String> sentKeyCommands = [];

  /// Optional factory for [execStream] output (headless session tests).
  Stream<String> Function(String command)? onExecStream;

  /// Backend-agnostic pane fake shared with the adapter tests.
  final FakePaneIO paneIO = FakePaneIO();

  FakeAgentTransport({Map<String, String>? files}) : files = files ?? {};

  @override
  bool get isConnected => true;

  /// Optional hook to serve canned stdout for arbitrary commands
  /// (herdr CLI fakes). Checked before the filesystem emulation.
  String Function(String command)? onExec;

  CommandResult _emulate(String command) {
    execCommands.add(command);
    final hook = onExec;
    if (hook != null) {
      return CommandResult(
        stdout: hook(command),
        stderr: '',
        exitCode: 0,
        outputSeparation: CommandOutputSeparation.separated,
        actualTransport: CommandTransport.ephemeral,
      );
    }
    final catMatch = RegExp(r'^cat -- "([^"]+)"$').firstMatch(command);
    if (catMatch != null) {
      final path = catMatch.group(1)!;
      final content = files[path];
      if (content == null) {
        return CommandResult(
          stdout: '',
          stderr: 'cat: $path: No such file or directory',
          exitCode: 1,
          outputSeparation: CommandOutputSeparation.separated,
          actualTransport: CommandTransport.ephemeral,
        );
      }
      return CommandResult(
        stdout: content,
        stderr: '',
        exitCode: 0,
        outputSeparation: CommandOutputSeparation.separated,
        actualTransport: CommandTransport.ephemeral,
      );
    }
    if (command.contains('base64 -d') && command.contains('mv -f --')) {
      _emulateAtomicWrite(command);
      return CommandResult(
        stdout: '',
        stderr: '',
        exitCode: 0,
        outputSeparation: CommandOutputSeparation.separated,
        actualTransport: CommandTransport.ephemeral,
      );
    }
    return CommandResult(
      stdout: '',
      stderr: '',
      exitCode: 0,
      outputSeparation: CommandOutputSeparation.separated,
      actualTransport: CommandTransport.ephemeral,
    );
  }

  @override
  Future<String> exec(String command) async => _emulate(command).stdout;

  @override
  Future<CommandResult> execWithExitCode(String command) async =>
      _emulate(command);

  @override
  Future<String> execPersistent(String command) async =>
      _emulate(command).stdout;

  @override
  Stream<String> execStream(String command) {
    execCommands.add(command);
    final factory = onExecStream;
    if (factory == null) {
      throw StateError('onExecStream not set');
    }
    return factory(command);
  }

  @override
  Future<void> sendKeysCommand(String command) async {
    sentKeyCommands.add(command);
  }

  /// Applies the shell semantics of
  /// [AgentConfigService.writeRemoteFileAtomic] to [files].
  void _emulateAtomicWrite(String command) {
    final encoded = RegExp(r"printf '%s' '([A-Za-z0-9+/=]*)'")
        .firstMatch(command)!
        .group(1)!;
    final content = utf8.decode(base64.decode(encoded));
    final mvMatch =
        RegExp(r'mv -f -- "([^"]+)" "([^"]+)"').firstMatch(command)!;
    final target = mvMatch.group(2)!;
    final backup = '$target${AgentConfigService.backupSuffix}';
    final existing = files[target];
    if (existing != null && !files.containsKey(backup)) {
      files[backup] = existing;
    }
    files[target] = content;
  }
}

/// Records [PaneIO] calls as readable strings: `typeLiteral %7 text`,
/// `enter %7`, `interrupt %7`, `currentCommand %7`.
class FakePaneIO implements PaneIO {
  final List<String> calls = [];

  /// Value returned by [currentCommand].
  String? currentCommandValue;

  /// Panes returned by [listPanes].
  List<AgentPaneInfo> panes = const [];

  @override
  Future<List<AgentPaneInfo>> listPanes() async => panes;

  @override
  Future<AgentPaneInfo?> paneInfoById(String paneId) async {
    for (final pane in panes) {
      if (pane.id == paneId) return pane;
    }
    return null;
  }

  @override
  Future<String?> currentCommand(String paneId) async {
    calls.add('currentCommand $paneId');
    return currentCommandValue;
  }

  @override
  Future<void> typeLiteral(String paneId, String text) async {
    calls.add('typeLiteral $paneId $text');
  }

  @override
  Future<void> pressEnter(String paneId) async {
    calls.add('enter $paneId');
  }

  @override
  Future<void> pressInterrupt(String paneId) async {
    calls.add('interrupt $paneId');
  }
}
