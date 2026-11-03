import 'dart:convert';

import '../command/command_request.dart';
import '../command/command_result.dart';
import '../tmux/commands/content_commands.dart';
import '../tmux/commands/input_commands.dart';
import '../tmux/tmux_command_executor.dart';
import '../tmux/tmux_facade.dart';
import 'agent_adapter.dart';
import 'agent_registry.dart';
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

  /// Agent lifecycle state herdr reports for the pane ("working",
  /// "blocked", "idle"), null when the backend has none (tmux).
  final String? agentStatus;

  /// Pid of the pane's agent process (herdr foreground list), null
  /// when unknown.
  final int? agentPid;

  /// Epoch milliseconds (server clock) when the agent process started,
  /// null when unknown. Powers the session-start datetime and the
  /// most-recent-first ordering.
  final int? agentStartedAtMs;

  /// herdr's global state-change sequence for the pane's agent: every
  /// agent transition (turn started/finished, blocked…) increments it,
  /// so a HIGHER value means a more recent interaction. Null for
  /// panes herdr does not report. Powers the last-interaction
  /// ordering.
  final int? agentStateSeq;

  /// herdr's per-pane revision counter: it moves whenever the pane's
  /// content changes (agent output, user typing, TUI redraws) - even
  /// for panes herdr reports no agent for. Change detection between
  /// polls pins real activity times, including desktop-side
  /// interactions the app cannot otherwise see.
  final int? paneRevision;

  const AgentPaneInfo({
    required this.id,
    this.command,
    this.path,
    this.workspace,
    this.tab,
    this.title,
    this.agentStatus,
    this.agentPid,
    this.agentStartedAtMs,
    this.agentStateSeq,
    this.paneRevision,
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

/// A pane running a known agent: the pane plus the adapter matching its
/// foreground process. The console's agent switcher shows one of these
/// per detected agent, labeled with the pane's [AgentPaneInfo.label].
class DetectedAgent {
  const DetectedAgent({required this.pane, required this.adapter});

  final AgentPaneInfo pane;
  final AgentAdapter adapter;

  /// Agent lifecycle state the backend reports for this pane
  /// ("working" | "blocked" | "idle"), null when unknown.
  String? get status => pane.agentStatus;
}

/// Strips the huge right padding TUI output carries (full-width status
/// bars etc.) so preview lines don't wrap on a phone.
String trimTrailingPadding(String raw) =>
    [for (final line in raw.split('\n')) line.trimRight()].join('\n').trim();

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

  /// Reads the last [lines] of the pane's terminal output as plain
  /// text (long lines unwrapped when the backend supports it), with
  /// trailing padding stripped per line. Best effort: empty string when
  /// the content cannot be read.
  Future<String> readRecentContent(String paneId, {int lines = 40});

  /// Short tail of every pane in ONE batched call (activity
  /// detection: a changed tail between two polls means someone typed
  /// or the agent produced output). Best effort per pane.
  Future<Map<String, String>> readRecentContents(
    List<String> paneIds, {
    int lines = 3,
  });

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
  Future<String> readRecentContent(String paneId, {int lines = 40}) async {
    try {
      final out = await _run(
        TmuxContentCommands.capture(
          paneId,
          startLine: -lines,
          escapeSequences: false,
        ),
      );
      return trimTrailingPadding(out);
    } on Object {
      return '';
    }
  }

  @override
  Future<Map<String, String>> readRecentContents(
    List<String> paneIds, {
    int lines = 3,
  }) async {
    final tails = <String, String>{};
    for (final paneId in paneIds) {
      tails[paneId] = await readRecentContent(paneId, lines: lines);
    }
    return tails;
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

  /// Raw pane entries of the last snapshot, cached for
  /// [_snapshotCacheTtl] so a burst of lookups (badges + one console open)
  /// costs ONE snapshot round trip instead of one per lookup. The
  /// [agentNames] map carries herdr's own agent report per pane id,
  /// [agentStatuses] the lifecycle state it reports for each of them,
  /// [agentSeqs] the global state-change sequence per pane.
  static const _snapshotCacheTtl = Duration(seconds: 5);
  ({
    List<AgentPaneInfo> panes,
    Map<String, String> agentNames,
    Map<String, String> agentStatuses,
    Map<String, int> agentSeqs,
    DateTime at,
  })?
  _snapshotCache;

  Future<
    ({
      List<AgentPaneInfo> panes,
      Map<String, String> agentNames,
      Map<String, String> agentStatuses,
      Map<String, int> agentSeqs,
    })
  >
  _snapshotPanes() async {
    final cached = _snapshotCache;
    if (cached != null &&
        DateTime.now().difference(cached.at) < _snapshotCacheTtl) {
      return (
        panes: cached.panes,
        agentNames: cached.agentNames,
        agentStatuses: cached.agentStatuses,
        agentSeqs: cached.agentSeqs,
      );
    }
    final bin = await _bin();
    // The snapshot is the one irreplacable call (pane enumeration); a
    // transient channel failure gets one retry before giving up.
    CommandResult? snapshot;
    var lastError = 'herdr api snapshot failed';
    for (var attempt = 0; attempt < 2 && snapshot == null; attempt++) {
      try {
        final result = await _transport.execWithExitCode(
          '$bin api snapshot',
          timeout: _execTimeout,
        );
        if (result.exitCode == 0 && result.stdout.trim().isNotEmpty) {
          snapshot = result;
        } else {
          lastError =
              'herdr api snapshot failed (exit ${result.exitCode})'
              '${result.stderr.trim().isEmpty ? '' : ': ${result.stderr.trim()}'}';
        }
      } on Object catch (e) {
        lastError = 'herdr api snapshot failed: $e';
      }
    }
    if (snapshot == null) throw StateError(lastError);
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
        final rawStatus = raw['agent_status'];
        final rawRevision = raw['revision'];
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
            agentStatus: rawStatus is String && rawStatus != 'unknown'
                ? rawStatus
                : null,
            paneRevision: rawRevision is int ? rawRevision : null,
          ),
        );
      }
    }
    // herdr's own agent report: pane id -> agent name ("claude", "pi").
    // herdr tracks these sessions itself, so the report identifies
    // agents whose foreground process is a wrapper (claude panes run
    // `clawpatrol`).
    final agentNames = <String, String>{};
    final agentStatuses = <String, String>{};
    final agentSeqs = <String, int>{};
    if (snapshotObj is Map<String, dynamic>) {
      final agents = snapshotObj['agents'];
      if (agents is List) {
        for (final a in agents) {
          if (a is! Map<String, dynamic>) continue;
          final agentPaneId = a['pane_id'];
          final agentName = a['agent'];
          if (agentPaneId is String && agentPaneId.isNotEmpty) {
            if (agentName is String && agentName.isNotEmpty) {
              agentNames[agentPaneId] = agentName.trim().toLowerCase();
            }
            final status = a['agent_status'];
            if (status is String && status.isNotEmpty) {
              agentStatuses[agentPaneId] = status;
            }
            final seq = a['state_change_seq'];
            if (seq is int) {
              agentSeqs[agentPaneId] = seq;
            }
          }
        }
      }
    }
    _snapshotCache = (
      panes: panes,
      agentNames: agentNames,
      agentStatuses: agentStatuses,
      agentSeqs: agentSeqs,
      at: DateTime.now(),
    );
    return (
      panes: panes,
      agentNames: agentNames,
      agentStatuses: agentStatuses,
      agentSeqs: agentSeqs,
    );
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
      agentStatus: pane.agentStatus,
      agentStateSeq: pane.agentStateSeq,
      paneRevision: pane.paneRevision,
    );
  }

  /// Resolves the foreground process of every [ids] pane in ONE exec: a
  /// server-side shell loop framed with `<<<MUXPOD:<pane>>>` markers.
  /// One round trip for N panes instead of N round trips (the per-pane
  /// path was slow and flaky over the shared terminal connection).
  /// Returns null when the batch could not be parsed, so callers can
  /// fall back to per-pane probes.
  /// Parsed foreground pick per pane: process name + pid.
  Future<Map<String, ({String name, int? pid})>?> _batchForegroundCommands(
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const {};
    // Pane ids are herdr-generated (`w5:p3`); only embed clearly safe
    // ids in the loop, anything else is skipped (command stays null).
    final safe = ids
        .where((id) => RegExp(r'^[A-Za-z0-9:_-]+$').hasMatch(id))
        .toList();
    if (safe.isEmpty) return const {};
    final bin = await _bin();
    late final CommandResult out;
    try {
      out = await _transport.execWithExitCode(
        'for p in ${safe.join(' ')}; do '
        'printf \'\\n<<<MUXPOD:%s>>>\' "\$p"; '
        '$bin pane process-info --pane "\$p" 2>/dev/null; '
        'done; true',
        timeout: _execTimeout,
      );
    } on Object {
      // A transient exec failure (channel error, timeout under lock
      // contention) must degrade to the per-pane fallback, not kill the
      // whole scan.
      return null;
    }
    if (out.exitCode != 0) return null;
    final marker = RegExp(r'<<<MUXPOD:([^>]+)>>>');
    final matches = marker.allMatches(out.stdout).toList();
    if (matches.isEmpty) return null;
    final commands = <String, ({String name, int? pid})>{};
    for (var i = 0; i < matches.length; i++) {
      final paneId = matches[i].group(1)!.trim();
      final start = matches[i].end;
      final end = i + 1 < matches.length
          ? matches[i + 1].start
          : out.stdout.length;
      final body = out.stdout.substring(start, end).trim();
      if (body.isEmpty) continue; // pane closed or herdr could not report it
      try {
        final decoded = jsonDecode(body);
        final result = decoded is Map<String, dynamic>
            ? resultOf(decoded)
            : null;
        final processInfo = result is Map<String, dynamic>
            ? result['process_info']
            : null;
        final processes = processInfo is Map<String, dynamic>
            ? processInfo['foreground_processes']
            : null;
        // Same agent-first picking as [currentCommand]: herdr may list
        // lingering helpers (xdg-open) ahead of the pane's agent.
        final pick = _pickForegroundProcess(processes);
        if (pick != null) commands[paneId] = pick;
      } on Object {
        // Unparseable chunk: leave this pane unresolved.
      }
    }
    return commands;
  }

  /// Resolves the start time of every [pids] process in ONE exec:
  /// the server epoch followed by `ps etimes` (elapsed seconds) per
  /// pid, so the list can show a session-start datetime and sort
  /// most-recent-first. herdr's snapshot carries no timestamps.
  /// Best effort: pids missing from the output stay unknown.
  Future<Map<int, int>> _batchProcessStartTimes(List<int> pids) async {
    if (pids.isEmpty) return const {};
    try {
      final out = await _transport.execWithExitCode(
        'echo \$(date +%s); ps -o pid=,etimes= -p ${pids.join(' ')}',
        timeout: _execTimeout,
      );
      if (out.stdout.trim().isEmpty) return const {};
      final lines = out.stdout
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      if (lines.isEmpty) return const {};
      final nowEpoch = int.tryParse(lines.first);
      if (nowEpoch == null) return const {};
      final started = <int, int>{};
      for (final line in lines.skip(1)) {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length < 2) continue;
        final pid = int.tryParse(parts[0]);
        final elapsed = int.tryParse(parts[1]);
        if (pid == null || elapsed == null) continue;
        started[pid] = (nowEpoch - elapsed) * 1000;
      }
      return started;
    } on Object {
      return const {};
    }
  }

  @override
  Future<List<AgentPaneInfo>> listPanes() async {
    final snapshot = await _snapshotPanes();
    // Probe EVERY pane in one batched exec: herdr's own report still
    // wins for the agent NAME, but the probe also yields the agent
    // process PID (needed for the session-start lookup) even on
    // panes herdr reports itself.
    final probed = await _batchForegroundCommands([
      for (final pane in snapshot.panes) pane.id,
    ]);
    if (probed == null) {
      // Batch failed (old herdr, odd shell): per-pane probes, bounded.
      // No PID/start-time resolution on this path.
      final result = <AgentPaneInfo>[];
      for (final pane in snapshot.panes) {
        final reported = snapshot.agentNames[pane.id];
        result.add(
          reported != null
              ? _withReportedAgent(
                  pane,
                  reported,
                  snapshot.agentStatuses[pane.id],
                  seq: snapshot.agentSeqs[pane.id],
                )
              : await _withCommand(pane),
        );
      }
      return result;
    }
    final startTimes = await _batchProcessStartTimes([
      for (final pick in probed.values)
        if (pick.pid != null) pick.pid!,
    ]);
    return [
      for (final pane in snapshot.panes)
        AgentPaneInfo(
          id: pane.id,
          // herdr's own report wins over the foreground process name.
          command: snapshot.agentNames[pane.id] ?? probed[pane.id]?.name,
          path: pane.path,
          workspace: pane.workspace,
          tab: pane.tab,
          title: pane.title,
          agentStatus: snapshot.agentStatuses[pane.id] ?? pane.agentStatus,
          agentPid: probed[pane.id]?.pid,
          agentStartedAtMs: startTimes[probed[pane.id]?.pid],
          agentStateSeq: snapshot.agentSeqs[pane.id],
          paneRevision: pane.paneRevision,
        ),
    ];
  }

  /// Pane copy carrying herdr's own reported agent as its command (no
  /// process-info probe needed: herdr tracks these sessions itself).
  AgentPaneInfo _withReportedAgent(
    AgentPaneInfo pane,
    String agent,
    String? status, {
    int? seq,
  }) => AgentPaneInfo(
    id: pane.id,
    command: agent,
    path: pane.path,
    workspace: pane.workspace,
    tab: pane.tab,
    title: pane.title,
    agentStatus: status ?? pane.agentStatus,
    agentStateSeq: seq ?? pane.agentStateSeq,
    paneRevision: pane.paneRevision,
  );

  @override
  Future<AgentPaneInfo?> paneInfoById(String paneId) async {
    // Resolve a single pane WITHOUT the per-pane process-info scan of
    // [listPanes]: snapshot (cached) + one process-info for the target —
    // or none at all when herdr itself reports the pane's agent.
    final snapshot = await _snapshotPanes();
    for (final pane in snapshot.panes) {
      if (pane.id != paneId) continue;
      final reported = snapshot.agentNames[paneId];
      if (reported != null) {
        return _withReportedAgent(
          pane,
          reported,
          snapshot.agentStatuses[paneId],
          seq: snapshot.agentSeqs[paneId],
        );
      }
      return _withCommand(pane);
    }
    return null;
  }

  @override
  Future<String?> currentCommand(String paneId) async {
    if (!_safePaneId(paneId)) return null;
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
    return _pickForegroundProcessName(processes);
  }

  /// Picks the pane's representative process name from herdr's
  /// foreground process list: the first entry that is a KNOWN agent
  /// (herdr lists lingering helpers like xdg-open ahead of the agent),
  /// else the first entry. Names normalize like [currentCommand]:
  /// display names such as "Vibe CLI" reduce to their first word
  /// lowercased ("vibe").
  static String? _pickForegroundProcessName(List? processes) =>
      _pickForegroundProcess(processes)?.name;

  /// Same as [_pickForegroundProcessName] but also returns the pid of
  /// the picked entry (for the session-start lookup).
  static ({String name, int? pid})? _pickForegroundProcess(List? processes) {
    if (processes == null || processes.isEmpty) return null;
    final picked = <({String name, int? pid})>[];
    for (final entry in processes) {
      if (entry is! Map<String, dynamic>) continue;
      final name = entry['name'];
      if (name is String && name.isNotEmpty) {
        final pid = entry['pid'];
        picked.add((
          name: name.split(' ').first.toLowerCase(),
          pid: pid is int ? pid : null,
        ));
      }
    }
    if (picked.isEmpty) return null;
    for (final entry in picked) {
      if (AgentRegistry.detect(entry.name) != null) return entry;
    }
    return picked.first;
  }

  /// Short tails of many panes in ONE exec (framed markers, same
  /// pattern as the process-info batch). Used for activity detection.
  @override
  Future<Map<String, String>> readRecentContents(
    List<String> paneIds, {
    int lines = 3,
  }) async {
    final tails = <String, String>{};
    final safe = paneIds.where((id) => _safePaneId(id)).toList();
    if (safe.isEmpty) return tails;
    final bin = await _bin();
    try {
      final out = await _transport.execWithExitCode(
        'for p in ${safe.join(' ')}; do '
        'printf \'\\n<<<MUXPOD:%s>>>\' "\$p"; '
        '$bin pane read "\$p" --source recent-unwrapped '
        '--lines $lines --format text 2>/dev/null; '
        'done; true',
        timeout: _execTimeout,
      );
      final marker = RegExp(r'<<<MUXPOD:([^>]+)>>>');
      final matches = marker.allMatches(out.stdout).toList();
      for (var i = 0; i < matches.length; i++) {
        final paneId = matches[i].group(1)!.trim();
        final start = matches[i].end;
        final end = i + 1 < matches.length
            ? matches[i + 1].start
            : out.stdout.length;
        final body = out.stdout.substring(start, end).trim();
        tails[paneId] = trimTrailingPadding(body);
      }
    } on Object {
      // Best effort: keep whatever was parsed before the failure.
    }
    return tails;
  }

  @override
  Future<String> readRecentContent(String paneId, {int lines = 40}) async {
    if (!_safePaneId(paneId)) return '';
    final bin = await _bin();
    try {
      final out = await _transport.execWithExitCode(
        '$bin pane read $paneId '
        '--source recent-unwrapped --lines $lines --format text',
        timeout: _execTimeout,
      );
      if (out.exitCode != 0) return '';
      return trimTrailingPadding(out.stdout);
    } on Object {
      return '';
    }
  }

  @override
  Future<void> typeLiteral(String paneId, String text) async {
    if (!_safePaneId(paneId)) return;
    final bin = await _bin();
    await _transport.sendKeysCommand(
      '$bin pane send-text $paneId ${_shellQuote(text)}',
    );
  }

  @override
  Future<void> pressEnter(String paneId) async {
    if (!_safePaneId(paneId)) return;
    final bin = await _bin();
    await _transport.sendKeysCommand('$bin pane send-keys $paneId Enter');
  }

  @override
  Future<void> pressInterrupt(String paneId) async {
    if (!_safePaneId(paneId)) return;
    final bin = await _bin();
    await _transport.sendKeysCommand('$bin pane send-keys $paneId C-c');
  }

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", r"'\''")}'";

  /// Pane ids are embedded into herdr CLI commands. They come from the
  /// server's own snapshot (herdr generates `w5:p3`), but a hostile or
  /// compromised server could craft one - never embed an id that is
  /// not plainly safe. Same pattern as the batched scan guard.
  static bool _safePaneId(String paneId) =>
      RegExp(r'^[A-Za-z0-9:_-]+$').hasMatch(paneId);

  static dynamic resultOf(Map<String, dynamic> envelope) => envelope['result'];
}
