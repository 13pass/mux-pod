import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/remote_ui_provider.dart';
import '../../services/agent/agent_adapter.dart';
import '../../services/agent/agent_types.dart';
import '../../theme/design_colors.dart';
import 'remote_ui_model_intelligence_sheet.dart';
import 'remote_ui_permission_sheet.dart';

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
/// reasoning effort / permission mode).
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
  static const _permissionChipKey = Key('agent_console.permission_chip');
  static const _modelChipKey = Key('agent_console.model_chip');

  final _composerController = TextEditingController();
  bool _opening = true;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    await ref
        .read(remoteUiProvider.notifier)
        .openPane(widget.connectionId, widget.paneId);
    if (mounted) setState(() => _opening = false);
  }

  @override
  void dispose() {
    _composerController.dispose();
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error)));
        ref.read(remoteUiProvider.notifier).clearMessages();
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
        widget.paneTitle ?? remote.agentPaneId ?? widget.paneId ?? '';

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
                    widget.paneId ?? remote.agentPaneId,
                  ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _opening || remote.isConnecting || remote.isBusy
                  ? _buildLoading(remote)
                  : _buildStatus(context, remote, textMuted),
            ),
            if (agent != null) _buildComposer(context, remote, agent, border),
          ],
        ),
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
    if (remote.phase == 'reading-credentials') {
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
                (remote.error != null && remote.error!.isNotEmpty)
                    ? remote.error!
                    : 'No AI agent detected in this pane.\n'
                          'Start an agent (vibe, claude, codex, droid) there '
                          'and reopen the console.',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: textMuted),
                textAlign: TextAlign.center,
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

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.terminal, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Live pane ${remote.agentPaneId ?? '-'}'
                  '${remote.agentPanePath != null ? ' · ${remote.agentPanePath}' : ''}',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'The composer below types into this pane. '
            'Watch the reply in the terminal.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: textMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(
    BuildContext context,
    RemoteUiState remote,
    AgentAdapter agent,
    Color border,
  ) {
    final capabilities = agent.capabilities;
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
              _PillChip(
                key: _modelChipKey,
                label: _modelChipLabel(remote.config),
                icon: Icons.auto_awesome,
                onTap: _openModelSheet,
              ),
              const SizedBox(width: 8),
              if (capabilities.permissionLevels.isNotEmpty)
                _PillChip(
                  key: _permissionChipKey,
                  label: remote.config.permission?.label ?? 'Permissions',
                  icon: Icons.lock_outline,
                  onTap: _openPermissionSheet,
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

  Future<void> _openPermissionSheet() async {
    final remote = ref.read(remoteUiProvider);
    final agent = remote.agent;
    if (agent == null) return;
    final level = await RemoteUiPermissionSheet.show(
      context,
      selected: remote.config.permission,
      permissions: agent.capabilities.permissionLevels,
    );
    if (!mounted || level == null || level == remote.config.permission) {
      return;
    }
    await ref.read(remoteUiProvider.notifier).applyPermission(level);
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
