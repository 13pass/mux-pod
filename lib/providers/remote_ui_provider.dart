import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/agent/agent_adapter.dart';
import '../services/agent/agent_registry.dart';
import '../services/agent/agent_transport.dart';
import '../services/agent/agent_types.dart';
import '../services/agent/pane_io.dart';
import '../services/backend/backend_type.dart';
import '../services/backend/multiplexer_config.dart';
import '../services/ssh/ssh_client.dart';
import '../services/tmux/tmux_facade.dart';
import 'connection_connect_options.dart';
import 'connection_provider.dart';
import 'settings_provider.dart';
import 'ssh_provider.dart';

/// State for the Remote UI tab: which server is connected, which agent
/// (if any) was detected in its tmux panes, and the agent's last known
/// configuration.
class RemoteUiState {
  /// Selected server connection id, null when nothing is selected.
  final String? connectionId;

  /// True while the dedicated SSH connection is being established.
  final bool isConnecting;

  /// True when the dedicated SSH connection is ready.
  final bool isConnected;

  /// Adapter of the agent detected in a tmux pane, null when no known
  /// agent runs on the connected server.
  final AgentAdapter? agent;

  /// tmux pane id the detected agent runs in.
  final String? agentPaneId;

  /// Working directory of the agent pane (`pane_current_path`).
  final String? agentPanePath;

  /// Human label of the agent pane (workspace / tab / pane title).
  final String? agentPaneLabel;

  /// What detection actually saw (pane command / scan stats), shown in
  /// the console when no agent is found so a screenshot explains itself.
  final String? detectDetail;

  /// Recent terminal output of the agent pane (the last messages
  /// preview in the console), null when none was read yet.
  final String? paneContent;

  /// Every agent detected on the server (one entry per pane running a
  /// known agent), powering the console's agent switcher.
  final List<DetectedAgent> detectedAgents;

  /// Last real activity per pane id, epoch ms: the newer of the app
  /// interaction (message/interrupt/open) and the last observed agent
  /// state change. Panes without either fall back to the session
  /// start. Powers the session-list ordering and the card datetime.
  final Map<String, int> paneActivityMs;

  /// Last known agent configuration.
  final AgentConfig config;

  /// True while a config read/apply operation is in flight.
  final bool isBusy;

  /// Last error message, if any.
  final String? error;

  /// Last confirmation message from an apply operation.
  final String? notice;

  /// Fine-grained connect phase for the console loading text
  /// ('reading-credentials' | 'connecting' | null).
  final String? phase;

  const RemoteUiState({
    this.connectionId,
    this.isConnecting = false,
    this.isConnected = false,
    this.agent,
    this.agentPaneId,
    this.agentPanePath,
    this.agentPaneLabel,
    this.detectDetail,
    this.paneContent,
    this.detectedAgents = const [],
    this.paneActivityMs = const {},
    this.config = const AgentConfig(),
    this.isBusy = false,
    this.error,
    this.notice,
    this.phase,
  });

  static const _unset = Object();

  RemoteUiState copyWith({
    Object? connectionId = _unset,
    bool? isConnecting,
    bool? isConnected,
    Object? agent = _unset,
    Object? agentPaneId = _unset,
    Object? agentPanePath = _unset,
    Object? agentPaneLabel = _unset,
    Object? detectDetail = _unset,
    Object? paneContent = _unset,
    List<DetectedAgent>? detectedAgents,
    Map<String, int>? paneActivityMs,
    AgentConfig? config,
    bool? isBusy,
    Object? error = _unset,
    Object? notice = _unset,
    String? phase,
  }) {
    return RemoteUiState(
      connectionId: connectionId == _unset
          ? this.connectionId
          : connectionId as String?,
      isConnecting: isConnecting ?? this.isConnecting,
      isConnected: isConnected ?? this.isConnected,
      agent: agent == _unset ? this.agent : agent as AgentAdapter?,
      agentPaneId: agentPaneId == _unset
          ? this.agentPaneId
          : agentPaneId as String?,
      agentPanePath: agentPanePath == _unset
          ? this.agentPanePath
          : agentPanePath as String?,
      agentPaneLabel: agentPaneLabel == _unset
          ? this.agentPaneLabel
          : agentPaneLabel as String?,
      detectDetail: detectDetail == _unset
          ? this.detectDetail
          : detectDetail as String?,
      paneContent: paneContent == _unset
          ? this.paneContent
          : paneContent as String?,
      detectedAgents: detectedAgents ?? this.detectedAgents,
      paneActivityMs: paneActivityMs ?? this.paneActivityMs,
      config: config ?? this.config,
      isBusy: isBusy ?? this.isBusy,
      error: error == _unset ? this.error : error as String?,
      notice: notice == _unset ? this.notice : notice as String?,
      phase: phase ?? (connectionId == _unset ? this.phase : null),
    );
  }
}

/// Manages the Remote UI tab's dedicated SSH connection and live-pane
/// agent control.
///
/// The tab owns its own [SshClient] (separate from the terminal screen's
/// global `sshProvider`) so that long-running chat streams and config
/// operations never block terminal input.
class RemoteUiNotifier extends Notifier<RemoteUiState> {
  SshClient? _client;

  /// When the user last interacted with each pane FROM THE APP (message
  /// sent, interrupt, console opened for it), pane id -> epoch ms.
  /// herdr reports no timestamps and pre-plugin sessions carry no state
  /// sequence at all, so this is the primary last-interaction signal;
  /// the server sequence is the fallback.
  final Map<String, int> _paneInteractionMs = {};

  /// Change detector per pane: the last seen herdr state sequence and
  /// pane revision, with the wall clock of the poll that OBSERVED the
  /// last change. Either marker moving between two polls pins the
  /// pane's activity to now (poll granularity) - the revision covers
  /// ANY pane content change, including desktop-side interaction the
  /// app cannot otherwise see. atMs stays null until the first
  /// observed change (first sight is at an unknown past time).
  final Map<String, ({int? seq, int revision, int? atMs})> _paneChangeClocks =
      {};

  void _touchInteraction(String paneId) {
    _paneInteractionMs[paneId] = DateTime.now().millisecondsSinceEpoch;
  }

  /// Last content tail hash per pane (null until first sight) and the
  /// wall clock of the poll that observed the last CHANGE. One batched
  /// short read; a changed tail pins the pane's activity to now.
  final Map<String, ({int hash, int? atMs})> _paneContentHashes = {};
  final Map<String, int> _contentActivityMs = {};

  Future<void> _observeContentChanges(List<String> paneIds) async {
    if (paneIds.isEmpty) return;
    final paneIO = _paneIO;
    if (paneIO == null) return;
    final tails = await paneIO.readRecentContents(paneIds);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final entry in tails.entries) {
      final hash = entry.value.hashCode;
      final known = _paneContentHashes[entry.key];
      if (known == null) {
        // First sight: the tail's history is unknown.
        _paneContentHashes[entry.key] = (hash: hash, atMs: null);
      } else if (known.hash != hash) {
        _paneContentHashes[entry.key] = (hash: hash, atMs: nowMs);
        _contentActivityMs[entry.key] = nowMs;
      }
    }
  }

  void _observePaneChanges(List<AgentPaneInfo> panes) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final pane in panes) {
      final seq = pane.agentStateSeq;
      final revision = pane.paneRevision;
      if (seq == null && revision == null) continue;
      final known = _paneChangeClocks[pane.id];
      if (known == null) {
        _paneChangeClocks[pane.id] = (
          seq: seq,
          revision: revision ?? -1,
          atMs: null,
        );
        continue;
      }
      final seqChanged = seq != null && seq != known.seq;
      final revisionChanged = revision != null && revision != known.revision;
      if (seqChanged || revisionChanged) {
        _paneChangeClocks[pane.id] = (
          seq: seq ?? known.seq,
          revision: revision ?? known.revision,
          atMs: nowMs,
        );
      }
    }
  }

  /// Whether this provider owns `_client` (dedicated connection). When the
  /// terminal's live connection is reused, [_client] stays null and
  /// disconnects must leave that connection alone.
  bool _ownsClient = false;
  PaneIO? _paneIO;
  AgentTransport? _transport;

  @override
  RemoteUiState build() {
    ref.onDispose(() {
      if (_ownsClient) {
        unawaited(_client?.disconnect());
      }
    });
    return const RemoteUiState();
  }

  /// The dedicated SSH connection used by the Remote UI tab, null until
  /// [selectServer] succeeds.
  SshClient? get client => _client;

  /// Backend-aware pane access for the selected server (tmux or herdr).
  PaneIO? get paneIO => _paneIO;

  /// Connects to the server [connectionId] and detects running agents.
  Future<void> selectServer(String connectionId) async {
    await _ensureConnected(connectionId);
    await refresh();
  }

  /// Opens the agent console for one specific pane: connects to
  /// [connectionId] if needed, scans EVERY pane once (one tmux call /
  /// one herdr snapshot + one batched process-info round trip), and
  /// points the state at the agent running in [paneId] — or the first
  /// detected agent pane when null. The scan also fills
  /// [RemoteUiState.detectedAgents] for the console's agent switcher.
  /// [readContent] also loads the pane transcript (the chat console
  /// wants it; the sessions list does not).
  Future<void> openPane(
    String connectionId,
    String? paneId, {
    bool readContent = true,
  }) async {
    // Opening a specific pane counts as an interaction (it reorders the
    // session list); the server-wide scan (null) does not.
    if (paneId != null) _touchInteraction(paneId);
    await _ensureConnected(connectionId);
    if (state.connectionId != connectionId) return;

    state = state.copyWith(isBusy: true, error: null, notice: null);
    try {
      final paneIO = _paneIO;
      final transport = _transport;
      if (paneIO == null || transport == null) {
        state = state.copyWith(isBusy: false);
        return;
      }

      final panes = await paneIO.listPanes();
      // Pin pane changes to the wall clock: when a pane's sequence,
      // revision or CONTENT TAIL moved since the last look, its last
      // activity is NOW (poll granularity). First sight stays unpinned
      // - the change happened at some unknown past time. The content
      // check is the one that catches "the user is talking to this
      // agent" even from the desktop and on unreported panes.
      _observePaneChanges(panes);
      await _observeContentChanges([
        for (final pane in panes)
          if (AgentRegistry.detect(pane.command) != null) pane.id,
      ]);
      final activity = <String, int>{..._paneInteractionMs};
      for (final entry in _paneChangeClocks.entries) {
        final atMs = entry.value.atMs;
        if (atMs == null) continue;
        final previous = activity[entry.key];
        if (previous == null || atMs > previous) {
          activity[entry.key] = atMs;
        }
      }
      for (final entry in _contentActivityMs.entries) {
        final atMs = entry.value;
        final previous = activity[entry.key];
        if (previous == null || atMs > previous) {
          activity[entry.key] = atMs;
        }
      }
      final scan = scanPanes(panes, paneId, activityMs: activity);
      final target = scan.target;
      var config = const AgentConfig();
      if (target != null) {
        config = await target.adapter.readConfig(
          AgentContext(
            ssh: transport,
            paneIO: paneIO,
            paneId: target.pane.id,
            paneWorkingDirectory: target.pane.path,
          ),
        );
      }

      state = state.copyWith(
        agent: target?.adapter,
        agentPaneId: target?.pane.id,
        agentPanePath: target?.pane.path,
        agentPaneLabel: target == null || target.pane.label.isEmpty
            ? null
            : target.pane.label,
        detectedAgents: scan.agents,
        paneActivityMs: activity,
        detectDetail: scan.detail,
        // Cleared per open: the next read fills it with THIS pane's
        // recent output (the previous agent's preview must not leak).
        paneContent: null,
        config: config,
        isBusy: false,
        error: target == null && paneId != null
            ? 'No AI agent detected in pane $paneId'
            : null,
      );
      if (target != null && readContent) {
        // Best effort; never blocks the console open. The sessions list
        // scans with readContent=false: it shows statuses, not
        // transcripts.
        unawaited(readPaneContent());
      }
    } on Object catch (e) {
      // Keep the failure visible in the status area (screenshots must
      // explain themselves), not only as a transient snackbar.
      state = state.copyWith(
        isBusy: false,
        error: '$e',
        detectDetail: 'detection failed: $e',
      );
    }
  }

  /// Resolves [panes] into every detected agent, the target for
  /// [paneId] (first detected agent when null), and the detection detail
  /// line for the console status. Pure; unit-tested directly.
  static ({List<DetectedAgent> agents, DetectedAgent? target, String detail})
  scanPanes(
    List<AgentPaneInfo> panes,
    String? paneId, {
    Map<String, int> activityMs = const {},
  }) {
    final agents = <DetectedAgent>[];
    for (final pane in panes) {
      final adapter = AgentRegistry.detect(pane.command);
      if (adapter != null) {
        agents.add(DetectedAgent(pane: pane, adapter: adapter));
      }
    }
    // Last activity first, all keys on ONE wall-clock scale:
    // 1. observed activity time (app interaction or a state-change
    //    pinned by the poll),
    // 2. else session start (newest first),
    // 3. unknowns keep their scan order at the end. The raw herdr
    // sequence never sorts by itself - a stale September sequence
    // must not outrank a November session.
    final indexed = [
      for (var i = 0; i < agents.length; i++) (index: i, agent: agents[i]),
    ];
    int? key(int i) =>
        activityMs[agents[i].pane.id] ?? agents[i].pane.agentStartedAtMs;
    indexed.sort((a, b) {
      final aMs = key(a.index);
      final bMs = key(b.index);
      if (aMs != null && bMs != null && aMs != bMs) {
        return bMs.compareTo(aMs);
      }
      if (aMs != null && bMs == null) return -1;
      if (aMs == null && bMs != null) return 1;
      return a.index.compareTo(b.index);
    });
    final sorted = [for (final entry in indexed) entry.agent];
    DetectedAgent? target;
    if (paneId != null) {
      for (final agent in sorted) {
        if (agent.pane.id == paneId) {
          target = agent;
          break;
        }
      }
    } else {
      // No focused pane: the most recently active session is the best
      // guess.
      target = sorted.isEmpty ? null : sorted.first;
    }
    var resolved = 0;
    for (final pane in panes) {
      if (pane.command != null) resolved++;
    }
    final detail = StringBuffer();
    if (paneId != null) {
      AgentPaneInfo? focused;
      for (final pane in panes) {
        if (pane.id == paneId) {
          focused = pane;
          break;
        }
      }
      detail.write(
        'pane $paneId: '
        '${focused == null ? "not in snapshot" : (focused.command ?? "no foreground process reported")}',
      );
    }
    detail.write(
      ' | scan: ${panes.length} panes, $resolved command(s) resolved',
    );
    return (agents: sorted, target: target, detail: detail.toString());
  }

  /// Detects which of [paneIds] run a known AI agent. Used by the
  /// terminal's pane sheet to badge agent panes. Connects to
  /// [connectionId] with the Remote UI's dedicated connection if needed.
  Future<Map<String, AgentKind>> agentsForPanes(
    String connectionId,
    List<String> paneIds,
  ) async {
    final result = <String, AgentKind>{};
    if (paneIds.isEmpty) return result;
    await _ensureConnected(connectionId);
    final paneIO = _paneIO;
    if (paneIO == null || state.connectionId != connectionId) return result;
    try {
      // One scan resolves every pane: per-pane lookups would re-run the
      // whole snapshot N times (minutes on a phone).
      final wanted = paneIds.toSet();
      for (final pane in await paneIO.listPanes()) {
        if (!wanted.contains(pane.id)) continue;
        final adapter = AgentRegistry.detect(pane.command);
        if (adapter != null) result[pane.id] = adapter.kind;
      }
    } on Object {
      // Badges are cosmetic; never block the sheet on failure.
    }
    return result;
  }

  /// Clears the previous connection state. When [ownsClient] is true a
  /// previously OWNED dedicated connection is disposed (bounded); a reused
  /// terminal connection is never touched.
  void _reset({required bool ownsClient}) {
    final previous = _client;
    _client = null;
    _paneIO = null;
    _transport = null;
    _ownsClient = ownsClient;
    if (previous != null && !ownsClient) {
      // previous was owned; new path reuses -> dispose it (bounded).
      unawaited(
        previous.disconnect().timeout(
          const Duration(seconds: 5),
          onTimeout: () {},
        ),
      );
    }
  }

  /// Connects to [connectionId] (reusing the connection when already
  /// active) and installs the backend-aware [PaneIO].
  Future<void> _ensureConnected(String connectionId) async {
    if (_client != null &&
        _client!.isConnected &&
        state.connectionId == connectionId) {
      return;
    }
    final connection = ref
        .read(connectionsProvider.notifier)
        .getById(connectionId);
    if (connection == null) {
      // Unknown id: do not leave isConnecting stuck on (infinite spinner).
      state = state.copyWith(isConnecting: false, error: 'Unknown connection');
      return;
    }

    // Preferred path: REUSE the terminal's live SSH connection. The console
    // is always opened from the terminal, that connection is already
    // authenticated, and opening a second connection has proven fragile on
    // mobile networks (new SSH handshakes time out while established flows
    // keep working). The console only issues short ephemeral exec commands,
    // which are safe over the shared connection.
    final ssh = ref.read(sshProvider.notifier);
    final live = ssh.liveClient;
    if (live != null &&
        live.isConnected &&
        ssh.liveConnectionId == connectionId) {
      _reset(ownsClient: false);
      _transport = SshAgentTransport(live);
      _paneIO = connection.multiplexer.backend == BackendType.herdr
          ? HerdrPaneIO(
              _transport!,
              herdrBin: connection.multiplexer.executablePath ?? 'herdr',
            )
          : TmuxPaneIO(live.tmuxExecutor);
      state = state.copyWith(
        connectionId: connectionId,
        isConnecting: false,
        isConnected: true,
        phase: null,
        error: null,
        notice: null,
      );
      return;
    }
    state = state.copyWith(
      isConnecting: true,
      isConnected: false,
      error: null,
      notice: null,
      phase: 'resetting-connection',
    );

    if (_ownsClient) {
      // Closing a previous (possibly half-dead) console connection must
      // never block a new attempt: a wedged close here produced the
      // endless 'Connecting...' spinner. Best-effort, bounded.
      final previous = _client;
      if (previous != null) {
        try {
          await previous.disconnect().timeout(const Duration(seconds: 5));
        } on Object {
          // Leave the old socket to the OS; proceed regardless.
        }
      }
    }
    _client = null;
    _paneIO = null;
    _transport = null;
    _ownsClient = true;
    state = state.copyWith(phase: 'reading-credentials');

    final client = SshClient();
    final isHerdr = connection.multiplexer.backend == BackendType.herdr;
    final SshConnectOptions options;
    try {
      // Credential reads go through the Android Keystore (secure storage);
      // a wedged keystore read must surface as an error, not a hang.
      options = await buildConnectionConnectOptions(
        connection,
        settingsKeepAliveTimeoutSeconds: ref
            .read(settingsProvider)
            .keepAliveTimeoutSeconds,
        // For herdr connections the multiplexer executablePath points at the
        // herdr binary, not tmux; the Remote UI never runs tmux commands on a
        // herdr server, so drop it to keep tmux auto-detection sane.
        multiplexerOverride: isHerdr
            ? const MultiplexerConfig(backend: BackendType.herdr)
            : null,
      ).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      state = state.copyWith(
        isConnecting: false,
        isConnected: false,
        phase: null,
        error:
            'Timed out reading connection credentials (secure storage). '
            'Try re-importing the SSH key in Keys.',
      );
      return;
    }
    try {
      state = state.copyWith(phase: 'connecting');

      // The console only issues ephemeral exec commands (herdr CLI / tmux /
      // config reads), so a lightweight connection suffices: no persistent
      // shells, no keep-alive. A full connect also starts the polling/input
      // shells, a step the terminal never exercises on the same server and
      // a hang candidate on flaky mobile links.
      await client
          .connect(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            options: options,
            lightweight: true,
          )
          .timeout(const Duration(seconds: 30));

      _client = client;
      _transport = SshAgentTransport(client);
      _paneIO = isHerdr
          ? HerdrPaneIO(
              _transport!,
              herdrBin: connection.multiplexer.executablePath ?? 'herdr',
            )
          : TmuxPaneIO(client.tmuxExecutor);
      state = state.copyWith(
        connectionId: connectionId,
        isConnecting: false,
        isConnected: true,
        phase: null,
      );
    } on TimeoutException {
      // Never leave a half-opened connection behind: it would linger as a
      // zombie TCP session and tripping sshd's MaxStartups blocks every
      // later attempt with an endless spinner.
      await client.disconnect();
      state = state.copyWith(
        isConnecting: false,
        isConnected: false,
        phase: null,
        error: 'Connection timed out after 30s',
      );
    } on Object catch (e) {
      await client.disconnect();
      state = state.copyWith(
        isConnecting: false,
        isConnected: false,
        agent: null,
        agentPaneId: null,
        agentPanePath: null,
        phase: null,
        error: '$e',
      );
    }
  }

  /// Disconnects from the current server and clears detection state.
  Future<void> disconnect() async {
    final client = _ownsClient ? _client : null;
    _client = null;
    _paneIO = null;
    _transport = null;
    _ownsClient = false;
    _paneInteractionMs.clear();
    _paneChangeClocks.clear();
    _paneContentHashes.clear();
    _contentActivityMs.clear();
    if (client != null) await client.disconnect();
    state = const RemoteUiState();
  }

  /// Re-scans the server's panes and re-reads the configuration of the
  /// currently selected agent (first detected agent when none is
  /// selected). Also refreshes the full agent list.
  ///
  /// Detection is backend-aware: on tmux servers it runs
  /// `tmux list-panes -a` (via the shared [tmuxFacade]); on herdr servers
  /// it uses `herdr api snapshot` + one batched `herdr pane process-info`
  /// loop, because herdr's panes are its own terminal emulators,
  /// invisible to tmux. Each pane's foreground process is matched against
  /// the registered adapters, and herdr's own agent report is merged in
  /// (it identifies agents whose foreground process is a wrapper).
  Future<void> refresh() async {
    final connectionId = state.connectionId;
    if (connectionId == null) return;
    await openPane(connectionId, state.agentPaneId);
  }

  /// Sends Ctrl+C to the selected agent pane (remote control: stop the
  /// running turn).
  Future<void> interruptAgent() async {
    final paneIO = _paneIO;
    final paneId = state.agentPaneId;
    if (paneIO == null || paneId == null) return;
    _touchInteraction(paneId);
    state = state.copyWith(isBusy: true, error: null, notice: null);
    try {
      await paneIO.pressInterrupt(paneId);
      state = state.copyWith(
        isBusy: false,
        notice: 'Interrupt sent to the agent pane',
      );
    } on Object catch (e) {
      state = state.copyWith(isBusy: false, error: '$e');
    }
  }

  /// Re-reads the recent terminal output of the selected agent pane
  /// (the last-messages preview in the console). Best effort: failures
  /// keep the previous preview.
  Future<void> readPaneContent({int lines = 40}) async {
    final paneIO = _paneIO;
    final paneId = state.agentPaneId;
    if (paneIO == null || paneId == null) return;
    try {
      final content = await paneIO.readRecentContent(paneId, lines: lines);
      // The selection may have changed while reading; only update the
      // preview when the read still belongs to the selected pane.
      if (!ref.mounted || state.agentPaneId != paneId) return;
      state = state.copyWith(paneContent: content.isEmpty ? null : content);
    } on Object {
      // Keep the previous preview.
    }
  }

  /// Toggles plan/spec mode on the detected live-pane agent.
  Future<void> setPlanMode(bool enabled) =>
      _apply((adapter, context) => adapter.setPlanMode(context, enabled));

  /// Sends a chat [message] to the detected live-pane agent (the
  /// "connect to the harness chat agent" path: text is typed into the
  /// agent's pane from the mobile composer instead of the terminal
  /// keyboard).
  Future<void> sendMessage(String message) async {
    final paneId = state.agentPaneId;
    if (paneId != null) _touchInteraction(paneId);
    await _apply((adapter, context) => adapter.sendMessage(context, message));
    // The typed message (and the first lines of the reply) land in the
    // pane a beat after send-keys: re-read the preview shortly.
    await Future<void>.delayed(const Duration(seconds: 2));
    if (ref.mounted) await readPaneContent();
  }

  /// Clears the current notice/error after the UI has shown it.
  void clearMessages() {
    state = state.copyWith(error: null, notice: null);
  }

  Future<void> _apply(
    Future<String> Function(AgentAdapter adapter, AgentContext context) action,
  ) async {
    final adapter = state.agent;
    final transport = _transport;
    final paneIO = _paneIO;
    final paneId = state.agentPaneId;
    if (adapter == null ||
        transport == null ||
        paneIO == null ||
        paneId == null) {
      return;
    }

    state = state.copyWith(isBusy: true, error: null, notice: null);
    final context = AgentContext(
      ssh: transport,
      paneIO: paneIO,
      paneId: paneId,
      paneWorkingDirectory: state.agentPanePath,
    );
    try {
      final message = await action(adapter, context);
      // Re-read the effective config best effort; a failed re-read must
      // not mask the successful apply.
      var config = state.config;
      try {
        config = await adapter.readConfig(context);
      } on Object {
        // Keep the previous snapshot.
      }
      state = state.copyWith(isBusy: false, notice: message, config: config);
    } on Object catch (e) {
      state = state.copyWith(isBusy: false, error: '$e');
    }
  }
}

/// Provider for the Remote UI tab.
final remoteUiProvider = NotifierProvider<RemoteUiNotifier, RemoteUiState>(
  RemoteUiNotifier.new,
);
