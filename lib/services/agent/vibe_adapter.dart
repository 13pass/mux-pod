import 'agent_adapter.dart';
import 'agent_config_service.dart';
import 'agent_types.dart';

/// Adapter for Mistral Vibe (`vibe`, the harness CLI behind herdr agent
/// panes).
///
/// Mechanisms (verified against `vibe --help` / `vibe config`, vibe 3.0.4):
///
/// - Config lives in `~/.vibe/config.toml`: `active_model` (model alias)
///   and `default_agent` (permission profile: `ask`, `accept-edits`,
///   `smart-approve`, `auto-approve`, or a custom agent from
///   `~/.vibe/agents/<name>.toml`). Both are read when a session starts.
/// - Headless runs take `--model` / `--agent` / `--resume` flags (see
///   `headless_command_builder.dart`); this adapter mirrors them for the
///   live pane.
/// - Live pane: `/model <alias>` is typed into the TUI for immediate
///   effect; `active_model` is persisted for new sessions. Permission
///   changes persist `default_agent` (the running session keeps its
///   agent until restarted).
/// - Chat input to the live pane is the agent-agnostic default
///   ([AgentAdapter.sendMessage]: literal `send-keys` + Enter), which is
///   how the harness chat agent in a herdr pane is driven from the
///   Remote UI composer.
class VibeAdapter extends AgentAdapter {
  VibeAdapter();

  /// User-level config file.
  static const String configPath = r'$HOME/.vibe/config.toml';

  @override
  AgentKind get kind => AgentKind.vibe;

  @override
  List<String> get processNames => const ['vibe', 'vibe-rs'];

  @override
  AgentCapabilities get capabilities => const AgentCapabilities(
        // Model aliases are user-defined in ~/.vibe/config.toml
        // ([[models]] / providers), so free-text entry.
        availableModels: [],
        // Vibe has no reasoning-effort flag (neither TUI nor headless).
        intelligenceLevels: [],
        permissionLevels: [
          UnifiedPermission.readOnly,
          UnifiedPermission.defaultPermissions,
          UnifiedPermission.autoReview,
          UnifiedPermission.fullAccess,
          UnifiedPermission.custom,
        ],
        supportsPlanMode: false,
      );

  // ===== Pure mappings (unit-tested directly) =====

  /// Maps a unified permission level to a Vibe builtin agent name
  /// (`default_agent` / `--agent`). Returns null for
  /// [UnifiedPermission.custom] ("leave the config file untouched").
  static String? agentForPermission(UnifiedPermission level) {
    return switch (level) {
      UnifiedPermission.readOnly => 'ask',
      UnifiedPermission.defaultPermissions => 'accept-edits',
      UnifiedPermission.autoReview => 'smart-approve',
      UnifiedPermission.fullAccess => 'auto-approve',
      UnifiedPermission.custom => null,
    };
  }

  /// Maps a persisted `default_agent` value back to a unified level.
  /// Custom agent names have no unified equivalent and map to null.
  static UnifiedPermission? permissionForAgent(String agent) {
    return switch (agent) {
      'ask' => UnifiedPermission.readOnly,
      'accept-edits' => UnifiedPermission.defaultPermissions,
      'smart-approve' => UnifiedPermission.autoReview,
      'auto-approve' => UnifiedPermission.fullAccess,
      _ => null,
    };
  }

  // ===== AgentAdapter implementation =====

  @override
  Future<AgentConfig> readConfig(AgentContext context) async {
    final content = await AgentConfigService.readRemoteFile(
      context.ssh,
      configPath,
    );
    if (content == null) return const AgentConfig();
    final model = AgentConfigService.tomlGetString(content, 'active_model');
    final agent = AgentConfigService.tomlGetString(content, 'default_agent');
    return AgentConfig(
      model: model,
      permission: agent == null ? null : permissionForAgent(agent),
    );
  }

  @override
  Future<String> applyModel(AgentContext context, String model) async {
    await _updateConfig(
      context,
      (content) =>
          AgentConfigService.tomlSetString(content, 'active_model', model),
    );
    // Best-effort immediate effect on the running TUI session.
    await context.paneIO.typeLiteral(context.paneId, '/model $model');
    await context.paneIO.pressEnter(context.paneId);
    return 'Model "$model" saved to $configPath and /model sent to the pane';
  }

  @override
  Future<String> applyIntelligence(
    AgentContext context,
    UnifiedIntelligence level,
  ) async {
    // Not reachable through the UI (intelligenceLevels is empty): Vibe
    // exposes no reasoning-effort control.
    return 'Vibe has no reasoning-effort setting; no change was made';
  }

  @override
  Future<String> applyPermission(
    AgentContext context,
    UnifiedPermission level,
  ) async {
    final agent = agentForPermission(level);
    if (agent == null) {
      return 'Custom permissions: $configPath left untouched';
    }
    await _updateConfig(
      context,
      (content) =>
          AgentConfigService.tomlSetString(content, 'default_agent', agent),
    );
    return 'Agent "$agent" saved to $configPath (default_agent). New '
        'sessions start with it; the running pane keeps its current agent.';
  }

  @override
  Future<String> setPlanMode(AgentContext context, bool enabled) async {
    // Not reachable through the UI (supportsPlanMode is false). Vibe has
    // no plan mode; `--worktree` is handled separately by the chat layer.
    return 'Vibe has no plan mode; no change was made';
  }

  /// Reads `~/.vibe/config.toml`, applies [transform], and writes it back
  /// atomically (keeping a one-time `.muxpod-bak` backup).
  Future<void> _updateConfig(
    AgentContext context,
    String Function(String content) transform,
  ) async {
    final current =
        await AgentConfigService.readRemoteFile(context.ssh, configPath) ?? '';
    await AgentConfigService.writeRemoteFileAtomic(
      context.ssh,
      configPath,
      transform(current),
    );
  }
}
