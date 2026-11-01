import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/remote_ui_provider.dart';
import '../../services/agent/agent_adapter.dart';
import '../../services/agent/agent_types.dart';
import '../../services/agent/pane_io.dart';
import '../../theme/design_colors.dart';
import 'remote_ui_model_intelligence_sheet.dart';

/// Full-screen agent console for ONE multiplexer pane, pushed on top of
/// the terminal.
///
/// Scope: the pane (tmux `%12` / herdr `w5:p3`) the user came from. There
/// is no server picker — [connectionId] and [paneId] come from the
/// terminal — and no headless-chat mode: the composer types into the
/// live pane (`send-keys` / `herdr pane send-text`), which is how TUI
/// agents (Vibe, Claude Code, Codex, Droid) accept input.
///
/// The chips control the running agent through its adapter (model /
/// reasoning effort).
class AgentPaneConsoleScreen extends ConsumerStatefulWidget {
  const AgentPaneConsoleScreen({
    super.key,
    required this.connectionId,
    this.paneId,
    this.paneTitle,
  });

  /// Terminal connection the pane belongs to.
  final String connectionId;

  /// Pane to open the console on; null picks the first detected agent
  /// pane on the server.
  final String? paneId;

  /// Optional display title for the pane (e.g. herdr terminal title).
  final String? paneTitle;

  @override
  ConsumerState<AgentPaneConsoleScreen> createState() =>
      _AgentPaneConsoleScreenState();
}

class _AgentPaneConsoleScreenState
    extends ConsumerState<AgentPaneConsoleScreen> {
  static const _sendButtonKey = Key('agent_console.send_button');
  static const _composerKey = Key('agent_console.composer');
  static const _modelChipKey = Key('agent_console.model_chip');

  final _composerController = TextEditingController();
  final _contentScrollController = ScrollController();
  bool _opening = true;

  @override
  void initState() {
    super.initState();
    // openPane must not start during the build phase: its synchronous
    // prefix writes provider state, and Riverpod forbids provider
    // modification while the tree is building ("Tried to modify a
    // provider while the widget tree was building"). Deferring one
    // frame also keeps the retry/switch taps (event phase) and the
    // initial open on the same code path.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_open());
    });
  }

  /// Error shown when openPane never completes even though every step is
  /// bounded (screen-level watchdog; belt-and-braces over the provider).
  String? _openTimeout;

  /// Error thrown by openPane itself (it normally reports failures
  /// through RemoteUiState.error; anything escaping must still be
  /// visible in a screenshot).
  String? _openError;

  Future<void> _open() async {
    _openTimeout = null;
    _openError = null;
    try {
      await ref
          .read(remoteUiProvider.notifier)
          .openPane(widget.connectionId, widget.paneId)
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      _openTimeout =
          'The console did not finish opening within 60s. '
          'Tap Retry.';
    } on Object catch (e) {
      _openError = 'Console failed to open: $e';
    }
    if (mounted) setState(() => _opening = false);
  }

  @override
  void dispose() {
    _composerController.dispose();
    _contentScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<RemoteUiState>(remoteUiProvider, (prev, next) {
      final notice = next.notice;
      final error = next.error;
      if (!mounted) return;
      if (notice != null && notice.isNotEmpty && notice != prev?.notice) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(notice)));
        ref.read(remoteUiProvider.notifier).clearMessages();
      } else if (error != null && error.isNotEmpty && error != prev?.error) {
        // Errors stay in the state: the status area keeps showing the
        // cause. Clearing here made transient exec failures vanish into
        // the bare "No AI agent detected" screen.
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error)));
      }
      // Keep the newest output in view whenever the preview updates.
      if (next.paneContent != prev?.paneContent) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_contentScrollController.hasClients) return;
          _contentScrollController.animateTo(
            _contentScrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        });
      }
    });

    final remote = ref.watch(remoteUiProvider);
    final agent = remote.agent;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final border = isDark ? DesignColors.borderDark : DesignColors.borderLight;
    final textMuted = isDark
        ? DesignColors.textMuted
        : DesignColors.textMutedLight;

    final title = agent?.kind.displayName ?? 'Agent chat';
    final paneLabel =
        (remote.agentPaneLabel != null && remote.agentPaneLabel!.isNotEmpty)
        ? remote.agentPaneLabel!
        : (widget.paneTitle ?? remote.agentPaneId ?? widget.paneId ?? '');

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 17)),
            if (paneLabel.isNotEmpty)
              Text(
                paneLabel,
                style: TextStyle(fontSize: 12, color: textMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => unawaited(
              ref
                  .read(remoteUiProvider.notifier)
                  .openPane(
                    widget.connectionId,
                    remote.agentPaneId ?? widget.paneId,
                  ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildSwitcher(remote),
            Expanded(
              child:
                  _opening ||
                      remote.isConnecting ||
                      (remote.isBusy && remote.agent == null)
                  ? _buildLoading(remote)
                  : Column(
                      children: [
                        // A pane switch or refresh keeps the current
                        // console visible with a thin progress bar
                        // instead of flashing a full-screen loader.
                        if (remote.isBusy)
                          const LinearProgressIndicator(minHeight: 2),
                        Expanded(
                          child: _buildStatus(context, remote, textMuted),
                        ),
                      ],
                    ),
            ),
            if (agent != null) _buildComposer(context, remote, agent, border),
          ],
        ),
      ),
    );
  }

  /// Horizontal agent switcher: one chip per detected agent, labeled
  /// with its workspace / tab / pane names. Tapping a chip points the
  /// console at that pane in place (no route change). Hidden when there
  /// is nothing to switch to.
  Widget _buildSwitcher(RemoteUiState remote) {
    final agents = remote.detectedAgents;
    if (agents.isEmpty || (agents.length == 1 && remote.agent != null)) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        itemCount: agents.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final detected = agents[index];
          return _AgentChip(
            key: Key('agent_console.agent_chip_${detected.pane.id}'),
            detected: detected,
            active: detected.pane.id == remote.agentPaneId,
            enabled: !remote.isBusy,
            onTap: () => unawaited(
              ref
                  .read(remoteUiProvider.notifier)
                  .openPane(widget.connectionId, detected.pane.id),
            ),
          );
        },
      ),
    );
  }

  /// Loading area that says WHICH phase is running, so a hang is visible
  /// Build stamp (GIT_REF dart-define) so any screenshot identifies the
  /// exact build under test.
  static const _gitRef = String.fromEnvironment(
    'GIT_REF',
    defaultValue: 'unknown-build',
  );

  /// Loading area that says WHICH phase is running, so a hang is visible
  /// in a screenshot instead of an anonymous spinner.
  Widget _buildLoading(RemoteUiState remote) {
    final String phase;
    if (remote.phase == 'resetting-connection') {
      phase = 'Closing previous connection…';
    } else if (remote.phase == 'reading-credentials') {
      phase = 'Reading connection credentials…';
    } else if (remote.isConnecting) {
      phase = 'Connecting to the server…';
    } else if (remote.isBusy) {
      phase =
          'Detecting the agent in pane ${widget.paneId ?? remote.agentPaneId ?? ''}…';
    } else {
      phase = 'Opening the agent console…';
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(
            phase,
            style: TextStyle(color: Theme.of(context).hintColor),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'build: $_gitRef',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).hintColor.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatus(
    BuildContext context,
    RemoteUiState remote,
    Color textMuted,
  ) {
    final agent = remote.agent;
    if (agent == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.smart_toy_outlined, size: 48, color: textMuted),
              const SizedBox(height: 12),
              Text(
                key: const Key('agent_console.status_message'),
                (remote.error != null && remote.error!.isNotEmpty)
                    ? remote.error!
                    : (_openTimeout ??
                          _openError ??
                          (widget.paneId == null
                              ? 'No AI agent detected on this server.\n'
                                    'Start an agent (vibe, claude, codex, droid) '
                                    'in a pane and reopen the console.'
                              : 'No AI agent detected in this pane.\n'
                                    'Start an agent (vibe, claude, codex, droid) there '
                                    'and reopen the console.')),
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
                onPressed: () => unawaited(_open()),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
          child: Row(
            children: [
              const Icon(Icons.terminal, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Live in '
                  '${(remote.agentPaneLabel != null && remote.agentPaneLabel!.isNotEmpty) ? remote.agentPaneLabel! : (widget.paneTitle ?? 'pane ${remote.agentPaneId ?? '-'}')}'
                  '${remote.agentPanePath != null ? ' · ${remote.agentPanePath}' : ''}',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                key: const Key('agent_console.content_refresh'),
                icon: const Icon(Icons.refresh, size: 18),
                color: textMuted,
                tooltip: 'Refresh recent output',
                onPressed: () => unawaited(
                  ref.read(remoteUiProvider.notifier).readPaneContent(),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: (remote.paneContent == null || remote.paneContent!.isEmpty)
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No recent output available for this pane yet.\n'
                      'Tap the refresh icon to retry.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: textMuted),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : Scrollbar(
                  controller: _contentScrollController,
                  child: SingleChildScrollView(
                    controller: _contentScrollController,
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    child: SelectableText(
                      key: const Key('agent_console.pane_content'),
                      remote.paneContent!,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.25,
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildComposer(
    BuildContext context,
    RemoteUiState remote,
    AgentAdapter agent,
    Color border,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: border)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              // The model sheet also accepts free-text model names
              // (availableModels is a convenience list, not an allowlist).
              //
              // No permission control here on purpose: the agent keeps
              // the permissions of its own server-side config; managing
              // them from the phone is out of scope for the console.
              _PillChip(
                key: _modelChipKey,
                label: _modelChipLabel(remote.config),
                icon: Icons.auto_awesome,
                onTap: _openModelSheet,
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: _composerKey,
                  controller: _composerController,
                  textInputAction: TextInputAction.send,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: 'Message the agent…',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                key: _sendButtonKey,
                onPressed: remote.isBusy ? null : _send,
                icon: const Icon(Icons.arrow_upward),
                tooltip: 'Send',
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _modelChipLabel(AgentConfig config) {
    final model = config.model ?? 'Auto';
    final intelligence = config.intelligence;
    return intelligence == null ? model : '$model ${intelligence.label}';
  }

  Future<void> _openModelSheet() async {
    final remote = ref.read(remoteUiProvider);
    final agent = remote.agent;
    if (agent == null) return;
    final result = await RemoteUiModelIntelligenceSheet.show(
      context,
      selectedModel: remote.config.model,
      selectedIntelligence: remote.config.intelligence,
      intelligenceLevels: agent.capabilities.intelligenceLevels,
      availableModels: agent.capabilities.availableModels,
    );
    if (!mounted || result == null) return;
    final notifier = ref.read(remoteUiProvider.notifier);
    if (result.model != null && result.model != remote.config.model) {
      await notifier.applyModel(result.model!);
    }
    if (result.intelligence != null &&
        result.intelligence != remote.config.intelligence) {
      await notifier.applyIntelligence(result.intelligence!);
    }
  }

  void _send() {
    final remote = ref.read(remoteUiProvider);
    if (remote.agent == null || remote.isBusy) return;
    final text = _composerController.text;
    if (text.trim().isEmpty) return;
    unawaited(ref.read(remoteUiProvider.notifier).sendMessage(text));
    _composerController.clear();
  }
}

class _AgentChip extends StatelessWidget {
  const _AgentChip({
    super.key,
    required this.detected,
    required this.active,
    required this.enabled,
    required this.onTap,
  });

  final DetectedAgent detected;
  final bool active;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final border = isDark ? DesignColors.borderDark : DesignColors.borderLight;
    final label = detected.pane.label.isNotEmpty
        ? detected.pane.label
        : 'Pane ${detected.pane.id}';
    final activeBg = theme.colorScheme.primary.withValues(alpha: 0.14);
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active ? theme.colorScheme.primary : border,
            width: active ? 1.4 : 1,
          ),
          color: active ? activeBg : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.smart_toy_outlined,
              size: 13,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: isDark
                      ? DesignColors.textPrimary
                      : DesignColors.textPrimaryLight,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              detected.adapter.kind.displayName,
              style: TextStyle(fontSize: 10, color: theme.hintColor),
            ),
          ],
        ),
      ),
    );
  }
}

class _PillChip extends StatelessWidget {
  const _PillChip({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final border = isDark ? DesignColors.borderDark : DesignColors.borderLight;
    final fg = isDark
        ? DesignColors.textPrimary
        : DesignColors.textPrimaryLight;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 12, color: fg)),
            const SizedBox(width: 3),
            Icon(Icons.expand_more, size: 13, color: fg),
          ],
        ),
      ),
    );
  }
}
