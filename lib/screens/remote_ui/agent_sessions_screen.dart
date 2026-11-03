import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/remote_ui_provider.dart';
import '../../services/agent/pane_io.dart';
import '../../theme/design_colors.dart';
import 'agent_pane_console_screen.dart';

/// List of the AI agents detected on the server, one card per agent
/// pane, in the style of the Claude mobile app's session list: icon,
/// session title (workspace / tab / pane title), lifecycle status and
/// a "Remote control" caption. Tapping a card opens the chat console
/// for that pane.
///
/// Pushed from the terminal menu on top of the terminal; the scan runs
/// once on open (and again when returning from a console) plus a slow
/// poll while the screen is open so statuses stay current.
class AgentSessionsScreen extends ConsumerStatefulWidget {
  const AgentSessionsScreen({super.key, required this.connectionId});

  /// Terminal connection whose server is scanned for agents.
  final String connectionId;

  @override
  ConsumerState<AgentSessionsScreen> createState() =>
      _AgentSessionsScreenState();
}

class _AgentSessionsScreenState extends ConsumerState<AgentSessionsScreen> {
  static const _gitRef = String.fromEnvironment(
    'GIT_REF',
    defaultValue: 'unknown-build',
  );

  bool _opening = true;
  Timer? _rescanTimer;

  @override
  void initState() {
    super.initState();
    // Same build-phase rule as the console: openPane's synchronous
    // prefix writes provider state, so the first scan runs post-frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_scan());
    });
    _rescanTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      final remote = ref.read(remoteUiProvider);
      if (remote.isBusy) return;
      unawaited(_scan());
    });
  }

  @override
  void dispose() {
    _rescanTimer?.cancel();
    super.dispose();
  }

  Future<void> _scan() async {
    try {
      await ref
          .read(remoteUiProvider.notifier)
          .openPane(widget.connectionId, null)
          .timeout(const Duration(seconds: 60));
    } on Object {
      // Failures surface through RemoteUiState.error in the list body.
    }
    if (mounted) setState(() => _opening = false);
  }

  Future<void> _openConsole(DetectedAgent agent) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AgentPaneConsoleScreen(
          connectionId: widget.connectionId,
          paneId: agent.pane.id,
          paneTitle: agent.pane.label.isEmpty ? null : agent.pane.label,
        ),
      ),
    );
    // The console may have changed what runs where: rescan on return.
    if (mounted) unawaited(_scan());
  }

  @override
  Widget build(BuildContext context) {
    final remote = ref.watch(remoteUiProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final border = isDark ? DesignColors.borderDark : DesignColors.borderLight;
    final textMuted = isDark
        ? DesignColors.textMuted
        : DesignColors.textMutedLight;

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI agents'),
        actions: [
          IconButton(
            key: const Key('agent_sessions.refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: remote.isBusy ? null : () => unawaited(_scan()),
          ),
        ],
      ),
      body: SafeArea(
        child: _opening || remote.isBusy
            ? _buildLoading(textMuted)
            : _buildBody(context, remote, border, textMuted),
      ),
    );
  }

  Widget _buildLoading(Color textMuted) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(
            'Scanning panes for AI agents…',
            style: TextStyle(color: textMuted),
          ),
          const SizedBox(height: 6),
          Text(
            'build: $_gitRef',
            style: TextStyle(
              fontSize: 11,
              color: textMuted.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    RemoteUiState remote,
    Color border,
    Color textMuted,
  ) {
    final agents = remote.detectedAgents;
    if (agents.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.smart_toy_outlined, size: 48, color: textMuted),
              const SizedBox(height: 12),
              Text(
                (remote.error != null && remote.error!.isNotEmpty)
                    ? remote.error!
                    : 'No AI agents detected on this server.\n'
                          'Start an agent (vibe, claude, codex, droid) in a '
                          'pane and reopen this list.',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: textMuted),
                textAlign: TextAlign.center,
              ),
              if (remote.detectDetail != null &&
                  remote.detectDetail!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  remote.detectDetail!,
                  style: TextStyle(fontSize: 11, color: textMuted),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'build: $_gitRef',
                style: TextStyle(
                  fontSize: 11,
                  color: textMuted.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('agent_sessions.retry'),
                onPressed: () => unawaited(_scan()),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    return Scrollbar(
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        itemCount: agents.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final agent = agents[index];
          return _AgentSessionCard(
            key: Key('agent_sessions.card_${agent.pane.id}'),
            agent: agent,
            border: border,
            textMuted: textMuted,
            onTap: () => unawaited(_openConsole(agent)),
          );
        },
      ),
    );
  }
}

/// One session card: code icon, session title (the pane's
/// workspace / tab / pane title), status dot + kind + "Remote control"
/// caption, chevron.
class _AgentSessionCard extends StatelessWidget {
  const _AgentSessionCard({
    super.key,
    required this.agent,
    required this.border,
    required this.textMuted,
    required this.onTap,
  });

  final DetectedAgent agent;
  final Color border;
  final Color textMuted;
  final VoidCallback onTap;

  static const _statusColors = <String, Color>{
    'working': Color(0xFF34D399),
    'blocked': Color(0xFFF59E0B),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = agent.status;
    final statusColor = _statusColors[status] ?? textMuted;
    final title = agent.pane.label.isNotEmpty
        ? agent.pane.label
        : 'Pane ${agent.pane.id}';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                ),
                child: Icon(
                  Icons.code,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: statusColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '${agent.adapter.kind.displayName} · '
                            'Remote control${status == null ? '' : ' · $status'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: textMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
