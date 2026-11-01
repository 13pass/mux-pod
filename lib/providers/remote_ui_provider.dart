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

  /// Last known agent configuration.
  final AgentConfig config;

  /// True while a config read/apply operation is in flight.
  final bool isBusy;

  /// Last error message, if any.
  final String? error;

  /// Last confirmation message from an apply operation.
  final String? notice;

  const RemoteUiState({
    this.connectionId,
    this.isConnecting = false,
    this.isConnected = false,
    this.agent,
    this.agentPaneId,
    this.agentPanePath,
    this.config = const AgentConfig(),
    this.isBusy = false,
    this.error,
    this.notice,
  });

  static const _unset = Object();

  RemoteUiState copyWith({
    Object? connectionId = _unset,
    bool? isConnecting,
    bool? isConnected,
    Object? agent = _unset,
    Object? agentPaneId = _unset,
    Object? agentPanePath = _unset,
    AgentConfig? config,
    bool? isBusy,
    Object? error = _unset,
    Object? notice = _unset,
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
      config: config ?? this.config,
      isBusy: isBusy ?? this.isBusy,
      error: error == _unset ? this.error : error as String?,
      notice: notice == _unset ? this.notice : notice as String?,
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
  PaneIO? _paneIO;
  AgentTransport? _transport;

  @override
  RemoteUiState build() {
    ref.onDispose(() {
      unawaited(_client?.disconnect());
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
  /// [connectionId] if needed, resolves the agent running in [paneId]
  /// (or falls back to the first detected agent pane when null), and
  /// points the state at it.
  Future<void> openPane(String connectionId, String? paneId) async {
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

      AgentAdapter? found;
      AgentPaneInfo? pane;
      if (paneId != null) {
        pane = await paneIO.paneInfoById(paneId);
        found = pane == null ? null : AgentRegistry.detect(pane.command);
      }
      if (found == null) {
        // Fall back to the first pane running a known agent.
        for (final candidate in await paneIO.listPanes()) {
          final adapter = AgentRegistry.detect(candidate.command);
          if (adapter != null) {
            found = adapter;
            pane = candidate;
            break;
          }
        }
      }

      var config = const AgentConfig();
      if (found != null && pane != null) {
        config = await found.readConfig(
          AgentContext(
            ssh: transport,
            paneIO: paneIO,
            paneId: pane.id,
            paneWorkingDirectory: pane.path,
          ),
        );
      }

      state = state.copyWith(
        agent: found,
        agentPaneId: pane?.id,
        agentPanePath: pane?.path,
        config: config,
        isBusy: false,
        error: found == null && paneId != null
            ? 'No AI agent detected in pane $paneId'
            : null,
      );
    } on Object catch (e) {
      state = state.copyWith(isBusy: false, error: '$e');
    }
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

    state = state.copyWith(
      isConnecting: true,
      isConnected: false,
      error: null,
      notice: null,
    );

    final previous = _client;
    _client = null;
    _paneIO = null;
    _transport = null;
    if (previous != null) await previous.disconnect();

    final client = SshClient();
    final isHerdr = connection.multiplexer.backend == BackendType.herdr;
    try {
      final options = await buildConnectionConnectOptions(
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
      );

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
      );
    } on TimeoutException {
      // Never leave a half-opened connection behind: it would linger as a
      // zombie TCP session and tripping sshd's MaxStartups blocks every
      // later attempt with an endless spinner.
      await client.disconnect();
      state = state.copyWith(
        isConnecting: false,
        isConnected: false,
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
        error: '$e',
      );
    }
  }

  /// Disconnects from the current server and clears detection state.
  Future<void> disconnect() async {
    final client = _client;
    _client = null;
    _paneIO = null;
    _transport = null;
    if (client != null) await client.disconnect();
    state = const RemoteUiState();
  }

  /// Re-scans the server's panes for a known agent and re-reads its
  /// configuration.
  ///
  /// Detection is backend-aware: on tmux servers it runs
  /// `tmux list-panes -a` (via the shared [tmuxFacade]); on herdr servers
  /// it uses `herdr api snapshot` + `herdr pane process-info`, because
  /// herdr's panes are its own terminal emulators, invisible to tmux. Each
  /// pane's foreground process is matched against the registered adapters.
  Future<void> refresh() async {
    final client = _client;
    final paneIO = _paneIO;
    final transport = _transport;
    if (client == null ||
        paneIO == null ||
        transport == null ||
        !client.isConnected) {
      return;
    }

    state = state.copyWith(isBusy: true, error: null);
    try {
      final panes = await paneIO.listPanes();

      AgentAdapter? found;
      String? paneId;
      String? panePath;
      for (final pane in panes) {
        final adapter = AgentRegistry.detect(pane.command);
        if (adapter != null) {
          found = adapter;
          paneId = pane.id;
          panePath = pane.path;
          break;
        }
      }

      var config = const AgentConfig();
      if (found != null) {
        config = await found.readConfig(
          AgentContext(
            ssh: transport,
            paneIO: paneIO,
            paneId: paneId!,
            paneWorkingDirectory: panePath,
          ),
        );
      }

      state = state.copyWith(
        agent: found,
        agentPaneId: paneId,
        agentPanePath: panePath,
        config: config,
        isBusy: false,
      );
    } on Object catch (e) {
      state = state.copyWith(isBusy: false, error: '$e');
    }
  }

  /// Applies a model switch to the detected live-pane agent.
  Future<void> applyModel(String model) =>
      _apply((adapter, context) => adapter.applyModel(context, model));

  /// Applies a reasoning-effort change to the detected live-pane agent.
  Future<void> applyIntelligence(UnifiedIntelligence level) =>
      _apply((adapter, context) => adapter.applyIntelligence(context, level));

  /// Applies an autonomy/permission change to the detected live-pane
  /// agent.
  Future<void> applyPermission(UnifiedPermission level) =>
      _apply((adapter, context) => adapter.applyPermission(context, level));

  /// Toggles plan/spec mode on the detected live-pane agent.
  Future<void> setPlanMode(bool enabled) =>
      _apply((adapter, context) => adapter.setPlanMode(context, enabled));

  /// Sends a chat [message] to the detected live-pane agent (the
  /// "connect to the harness chat agent" path: text is typed into the
  /// agent's pane from the mobile composer instead of the terminal
  /// keyboard).
  Future<void> sendMessage(String message) =>
      _apply((adapter, context) => adapter.sendMessage(context, message));

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
