import 'dart:async';

import '../command/command_request.dart';
import '../command/command_result.dart';
import '../ssh/ssh_client.dart';

/// The minimal command surface agent adapters need over a live SSH
/// connection.
///
/// Adapters depend on this abstraction (not on the concrete [SshClient])
/// so they stay unit-testable with a fake transport and never create
/// their own connections. [SshAgentTransport] is the production
/// implementation backed by [SshClient].
abstract class AgentTransport {
  /// Whether the underlying SSH connection is up.
  bool get isConnected;

  /// Runs [command] on a fresh ephemeral channel (stdout/stderr separated)
  /// and returns stdout. Throws [SshConnectionError] on failure.
  Future<String> exec(String command);

  /// Runs [command] and returns the full result including the exit code.
  Future<CommandResult> execWithExitCode(String command);

  /// Runs [command] preferring the persistent polling shell (merged
  /// output) and returns its output.
  Future<String> execPersistent(String command);

  /// Runs a long-lived [command] and streams its stdout incrementally.
  ///
  /// Cancelling the returned stream closes the channel and kills the
  /// remote process. The exec lock is held for the stream's lifetime, so
  /// long streams must use a dedicated connection (see Remote UI).
  Stream<String> execStream(String command);

  /// Runs a tmux input command (e.g. `tmux send-keys ...`) on an
  /// ephemeral channel. Throws [SshConnectionError] when tmux reports an
  /// error.
  Future<void> sendKeysCommand(String command);
}

/// [AgentTransport] backed by a concrete [SshClient].
class SshAgentTransport implements AgentTransport {
  SshAgentTransport(this._client);

  final SshClient _client;

  @override
  bool get isConnected => _client.isConnected;

  @override
  Future<String> exec(String command) async {
    final result = await _client.execute(
      CommandRequest(
        command: command,
        transport: CommandTransportPreference.ephemeralOnly,
        output: CommandOutputRequirement.separatedOutput,
      ),
    );
    return result.stdout;
  }

  @override
  Future<CommandResult> execWithExitCode(String command) {
    return _client.execute(
      CommandRequest(
        command: command,
        transport: CommandTransportPreference.ephemeralOnly,
        output: CommandOutputRequirement.separatedOutput,
      ),
    );
  }

  @override
  Future<String> execPersistent(String command) async {
    final result = await _client.execute(
      CommandRequest(
        command: command,
        transport: CommandTransportPreference.persistentPreferred,
        output: CommandOutputRequirement.outputOnly,
      ),
    );
    return result.mergedOutput ?? result.stdout;
  }

  @override
  Stream<String> execStream(String command) => _client.execStream(command);

  @override
  Future<void> sendKeysCommand(String command) async {
    final result = await _client.execute(
      CommandRequest(
        command: command,
        transport: CommandTransportPreference.ephemeralOnly,
        output: CommandOutputRequirement.separatedOutput,
      ),
    );
    if (result.exitCode != 0) {
      throw SshConnectionError(
        result.stderr.trim().isEmpty
            ? 'tmux command failed (exit ${result.exitCode})'
            : result.stderr.trim(),
      );
    }
  }
}
