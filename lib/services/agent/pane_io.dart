import 'dart:convert';

import '../command/command_request.dart';
import '../tmux/commands/content_commands.dart';
import '../tmux/commands/input_commands.dart';
import '../tmux/tmux_command_executor.dart';
import '../tmux/tmux_facade.dart';
import 'agent_transport.dart';

/// One pane of the server's multiplexer, as seen by agent detection.
class AgentPaneInfo {
  /// Pane id: tmux `%12` or herdr `w5:p3`.
  final String id;

  /// Foreground process name (`pane_current_command` / herdr
  /// `foreground_processes[0].name`), null when unknown.
  final String? command;

  /// Working directory of the pane.
  final String? path;

  const AgentPaneInfo({required this.id, this.command, this.path});
}

/// Backend-aware pane access for agent control.
///
/// The Remote UI must work on both multiplexer backends mux-pod supports:
///
/// - **tmux**: panes are listed with `tmux list-panes -a` and driven with
///   `tmux send-keys` ([TmuxPaneIO]).
/// - **herdr**: herdr runs its own terminal emulators (NOT tmux panes), so
///   panes come from `herdr api snapshot` + `herdr pane process-info`, and
///   input goes through `herdr pane send-text` / `send-keys`
///   ([HerdrPaneIO]).
abstract class PaneIO {
  /// Lists all panes of all sessions/workspaces with their foreground
  /// process name and working directory.
  Future<List<AgentPaneInfo>> listPanes();

  /// Current foreground process name of [paneId], null when unknown.
  Future<String?> currentCommand(String paneId);

  /// Types [text] literally into [paneId] (no key interpretation).
  Future<void> typeLiteral(String paneId, String text);

  /// Submits the current input line (Enter).
  Future<void> pressEnter(String paneId);

  /// Sends Ctrl+C to [paneId].
  Future<void> pressInterrupt(String paneId);
}

/// [PaneIO] over the tmux layer, using the shared [tmuxFacade] so the tmux
/// binary path is resolved exactly like the terminal screen does.
class TmuxPaneIO implements PaneIO {
  TmuxPaneIO(this._executor);

  final TmuxCommandExecutor _executor;

  Future<String> _run(String command) async {
    final result = await _executor.execute(
      CommandRequest(
        command: command,
        transport: CommandTransportPreference.ephemeralOnly,
        output: CommandOutputRequirement.separatedOutput,
      ),
    );
    if (result.exitCode != 0) {
      throw StateError(
        result.stderr.trim().isEmpty
            ? 'tmux command failed (exit ${result.exitCode})'
            : result.stderr.trim(),
      );
    }
    return result.stdout;
  }

  @override
  Future<List<AgentPaneInfo>> listPanes() async {
    final sessions = await tmuxFacade.listAllPanes(_executor);
    final panes = <AgentPaneInfo>[];
    for (final session in sessions) {
      for (final window in session.windows) {
        for (final pane in window.panes) {
          panes.add(
            AgentPaneInfo(
              id: pane.id,
              command: pane.currentCommand,
              path: pane.currentPath,
            ),
          );
        }
      }
    }
    return panes;
  }

  @override
  Future<String?> currentCommand(String paneId) async {
    final out = await _run(TmuxContentCommands.paneCurrentCommand(paneId));
    final trimmed = out.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  Future<void> typeLiteral(String paneId, String text) =>
      _run(TmuxInputCommands.sendKeys(paneId, text, literal: true));

  @override
  Future<void> pressEnter(String paneId) =>
      _run(TmuxInputCommands.sendEnter(paneId));

  @override
  Future<void> pressInterrupt(String paneId) =>
      _run(TmuxInputCommands.sendInterrupt(paneId));
}

/// [PaneIO] over a herdr server (`herdr` CLI), for connections whose
/// multiplexer backend is herdr.
///
/// herdr manages its own terminal emulators — its panes are invisible to
/// `tmux list-panes` — so pane listing uses `herdr api snapshot` and the
/// foreground process comes from `herdr pane process-info --pane <id>`.
class HerdrPaneIO implements PaneIO {
  HerdrPaneIO(this._transport, {String? herdrBin}) : _herdrBin = herdrBin;

  final AgentTransport _transport;
  final String? _herdrBin;
  String? _resolvedBin;

  /// herdr binary to invoke: the configured absolute path when set,
  /// otherwise auto-detected via the login shell on first use.
  Future<String> _bin() async {
    final configured = _herdrBin;
    if (configured != null && configured.isNotEmpty) return configured;
    final resolved = _resolvedBin;
    if (resolved != null) return resolved;
    try {
      final out = await _transport.exec(
        r"\$SHELL -lc 'command -v herdr'",
      );
      final path = out.trim();
      if (path.startsWith('/')) {
        _resolvedBin = path;
        return path;
      }
    } on Object {
      // fall through to the bare command name
    }
    return 'herdr';
  }

  @override
  Future<List<AgentPaneInfo>> listPanes() async {
    final bin = await _bin();
    final snapshotJson = await _transport.exec('$bin api snapshot');
    final decoded = jsonDecode(snapshotJson);
    final result = decoded is Map<String, dynamic> ? resultOf(decoded) : null;
    final snapshot = result is Map<String, dynamic> ? result['snapshot'] : null;
    if (snapshot is! List) return const [];

    final panes = <AgentPaneInfo>[];
    for (final raw in snapshot) {
      if (raw is! Map<String, dynamic>) continue;
      final paneId = raw['pane_id'];
      if (paneId is! String || paneId.isEmpty) continue;
      final cwd = raw['cwd'];
      // The foreground process name needs one extra call per pane.
      String? command;
      try {
        command = await currentCommand(paneId);
      } on Object {
        command = null; // pane may have closed between snapshot and query
      }
      panes.add(
        AgentPaneInfo(
          id: paneId,
          command: command,
          path: cwd is String ? cwd : null,
        ),
      );
    }
    return panes;
  }

  @override
  Future<String?> currentCommand(String paneId) async {
    // Pane ids are herdr-generated (`w5:p3`) — safe unquoted, same as
    // [HerdrCommands.paneSendText].
    final bin = await _bin();
    final out = await _transport.exec('$bin pane process-info --pane $paneId');
    final decoded = jsonDecode(out);
    final result = decoded is Map<String, dynamic> ? resultOf(decoded) : null;
    final info = result is Map<String, dynamic> ? result['process_info'] : null;
    if (info is! Map<String, dynamic>) return null;
    final processes = info['foreground_processes'];
    if (processes is! List || processes.isEmpty) return null;
    final first = processes.first;
    if (first is! Map<String, dynamic>) return null;
    final name = first['name'];
    if (name is! String || name.isEmpty) return null;
    // herdr reports display names like "Vibe CLI"; detection matches on the
    // first word lowercased ("vibe"), mirroring tmux basename matching.
    return name.split(' ').first.toLowerCase();
  }

  @override
  Future<void> typeLiteral(String paneId, String text) async {
    final bin = await _bin();
    await _transport.sendKeysCommand(
      '$bin pane send-text $paneId ${_shellQuote(text)}',
    );
  }

  @override
  Future<void> pressEnter(String paneId) async {
    final bin = await _bin();
    await _transport.sendKeysCommand('$bin pane send-keys $paneId Enter');
  }

  @override
  Future<void> pressInterrupt(String paneId) async {
    final bin = await _bin();
    await _transport.sendKeysCommand('$bin pane send-keys $paneId C-c');
  }

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", r"'\''")}'";

  static dynamic resultOf(Map<String, dynamic> envelope) =>
      envelope['result'];
}
