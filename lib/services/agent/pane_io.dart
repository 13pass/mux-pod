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

  /// Workspace (tmux session / herdr workspace) display name.
  final String? workspace;

  /// Tab (tmux window / herdr tab) display name.
  final String? tab;

  /// Pane display title (tmux pane title / herdr terminal_title).
  final String? title;

  const AgentPaneInfo({
    required this.id,
    this.command,
    this.path,
    this.workspace,
    this.tab,
    this.title,
  });

  /// Human label: workspace, tab and pane title joined with dots, e.g.
  /// `vibe · shell · Vibe`. Empty parts are skipped.
  String get label {
    final parts = <String>[
      if (workspace != null && workspace!.isNotEmpty) workspace!,
      if (tab != null && tab!.isNotEmpty) tab!,
      if (title != null && title!.isNotEmpty) title!,
    ];
    return parts.join(' \u00b7 ');
  }
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

  /// Info for a single [paneId], null when it no longer exists.
  Future<AgentPaneInfo?> paneInfoById(String paneId);

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
              workspace: session.name,
              tab: window.name,
              title: pane.title,
            ),
          );
        }
      }
    }
    return panes;
  }

  @override
  Future<AgentPaneInfo?> paneInfoById(String paneId) async {
    for (final pane in await listPanes()) {
      if (pane.id == paneId) return pane;
    }
    return null;
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

  /// Upper bound for one herdr CLI round trip. herdr commands answer in
  /// milliseconds on the server; anything slower is a hung channel that
  /// must surface as an error, not an infinite spinner.
  static const _execTimeout = Duration(seconds: 15);

  final AgentTransport _transport;
  final String? _herdrBin;
  String? _resolvedBin;

  /// herdr binary to invoke: the configured absolute path when set,
  /// otherwise auto-detected via the login shell on first use.
  Future<bool> _existsOnServer(String path) async {
    try {
      final result = await _transport.execWithExitCode('test -x -- $path');
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }

  Future<String> _bin() async {
    final resolved = _resolvedBin;
    if (resolved != null) return resolved;
    final configured = _herdrBin;
    if (configured != null &&
        configured.isNotEmpty &&
        await _existsOnServer(configured)) {
      _resolvedBin = configured;
      return configured;
    }
    try {
      // Non-interactive exec channels carry no login PATH and often no
      // $SHELL, so probe the standard install locations in ONE round
      // trip, then the login shell as a last resort.
      final out = await _transport.execWithExitCode(
        r'for p in "$HOME/.local/bin/herdr" /usr/local/bin/herdr '
        r'/usr/bin/herdr; do test -x "$p" && { printf %s "$p"; exit 0; }; '
        'done; exit 1',
        timeout: _execTimeout,
      );
      final path = out.stdout.trim();
      if (out.exitCode == 0 && path.startsWith('/')) {
        _resolvedBin = path;
        return path;
      }
    } on Object {
      // fall through to the login-shell probe
    }
    try {
      final out = await _transport.execWithExitCode(
        r'${SHELL:-/bin/bash} -lc "command -v herdr"',
        timeout: _execTimeout,
      );
      final path = out.stdout.trim();
      if (out.exitCode == 0 && path.startsWith('/')) {
        _resolvedBin = path;
        return path;
      }
    } on Object {
      // fall through to the bare command name
    }
    return 'herdr';
  }

  /// Raw pane entries of the last snapshot (pane_id + cwd), cached for
  /// [_snapshotCacheTtl] so a burst of lookups (badges + one console open)
  /// costs ONE snapshot round trip instead of one per lookup.
  static const _snapshotCacheTtl = Duration(seconds: 5);
  ({List<AgentPaneInfo> panes, DateTime at})? _snapshotCache;

  Future<List<AgentPaneInfo>> _snapshotPanes() async {
    final cached = _snapshotCache;
    if (cached != null &&
        DateTime.now().difference(cached.at) < _snapshotCacheTtl) {
      return cached.panes;
    }
    final bin = await _bin();
    final snapshot = await _transport.execWithExitCode(
      '$bin api snapshot',
      timeout: _execTimeout,
    );
    if (snapshot.exitCode != 0 || snapshot.stdout.trim().isEmpty) {
      throw StateError(
        'herdr api snapshot failed (exit ${snapshot.exitCode})'
        '${snapshot.stderr.trim().isEmpty ? '' : ': ${snapshot.stderr.trim()}'}',
      );
    }
    final decoded = jsonDecode(snapshot.stdout);
    final result = decoded is Map<String, dynamic> ? resultOf(decoded) : null;
    final snapshotObj = result is Map<String, dynamic>
        ? result['snapshot']
        : null;
    // herdr 0.9: result.snapshot is an object with a "panes" list (plus
    // agents/tabs/workspaces). Tolerate a flat pane list as well.
    final panesRaw = snapshotObj is Map<String, dynamic>
        ? snapshotObj['panes']
        : snapshotObj;
    // Workspace / tab display names for pane labels.
    final workspaceNames = <String, String>{};
    final tabNames = <String, String>{};
    if (snapshotObj is Map<String, dynamic>) {
      final workspaces = snapshotObj['workspaces'];
      if (workspaces is List) {
        for (final w in workspaces) {
          if (w is! Map<String, dynamic>) continue;
          final id = w['workspace_id'];
          final label = w['label'];
          if (id is String && label is String && label.isNotEmpty) {
            workspaceNames[id] = label;
          }
        }
      }
      final tabs = snapshotObj['tabs'];
      if (tabs is List) {
        for (final t in tabs) {
          if (t is! Map<String, dynamic>) continue;
          final id = t['tab_id'];
          final label = t['label'];
          if (id is String && label is String && label.isNotEmpty) {
            tabNames[id] = label;
          }
        }
      }
    }
    final panes = <AgentPaneInfo>[];
    if (panesRaw is List) {
      for (final raw in panesRaw) {
        if (raw is! Map<String, dynamic>) continue;
        final paneId = raw['pane_id'];
        if (paneId is! String || paneId.isEmpty) continue;
        final cwd = raw['cwd'];
        final workspaceId = raw['workspace_id'];
        final tabId = raw['tab_id'];
        final terminalTitle = raw['terminal_title'];
        panes.add(
          AgentPaneInfo(
            id: paneId,
            path: cwd is String ? cwd : null,
            workspace: workspaceId is String
                ? workspaceNames[workspaceId]
                : null,
            tab: tabId is String ? tabNames[tabId] : null,
            title: terminalTitle is String && terminalTitle.isNotEmpty
                ? terminalTitle
                : null,
          ),
        );
      }
    }
    _snapshotCache = (panes: panes, at: DateTime.now());
    return panes;
  }

  Future<AgentPaneInfo> _withCommand(AgentPaneInfo pane) async {
    // The foreground process name needs one extra call per pane; a pane
    // that closed between snapshot and query just reports no command.
    String? command;
    try {
      command = await currentCommand(pane.id);
    } on Object {
      command = null;
    }
    return AgentPaneInfo(
      id: pane.id,
      command: command,
      path: pane.path,
      workspace: pane.workspace,
      tab: pane.tab,
      title: pane.title,
    );
  }

  @override
  Future<List<AgentPaneInfo>> listPanes() async {
    return [
      for (final pane in await _snapshotPanes()) await _withCommand(pane),
    ];
  }

  @override
  Future<AgentPaneInfo?> paneInfoById(String paneId) async {
    // Resolve a single pane WITHOUT the per-pane process-info scan of
    // [listPanes]: snapshot (cached) + one process-info for the target.
    for (final pane in await _snapshotPanes()) {
      if (pane.id == paneId) return await _withCommand(pane);
    }
    return null;
  }

  @override
  Future<String?> currentCommand(String paneId) async {
    // Pane ids are herdr-generated (`w5:p3`) — safe unquoted, same as
    // [HerdrCommands.paneSendText].
    final bin = await _bin();
    final info = await _transport.execWithExitCode(
      '$bin pane process-info --pane $paneId',
      timeout: _execTimeout,
    );
    if (info.exitCode != 0 || info.stdout.trim().isEmpty) {
      return null; // pane closed or herdr could not report it
    }
    final decoded = jsonDecode(info.stdout);
    final result = decoded is Map<String, dynamic> ? resultOf(decoded) : null;
    final processInfo = result is Map<String, dynamic>
        ? result['process_info']
        : null;
    if (processInfo is! Map<String, dynamic>) return null;
    final processes = processInfo['foreground_processes'];
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

  static dynamic resultOf(Map<String, dynamic> envelope) => envelope['result'];
}
