import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/remote_ui_provider.dart';
import '../../services/agent/agent_types.dart';
import '../../utils/external_links.dart';
import '../../services/agent/pane_io.dart';
import '../../theme/design_colors.dart';

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

  final _composerController = TextEditingController();
  final _contentScrollController = ScrollController();

  /// Polls the pane's recent output while the console is open: the
  /// transcript must behave like a live chat view, not a snapshot
  /// taken at open time.
  Timer? _contentPollTimer;
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
    // Timer callbacks run in the event phase, so the poll's state
    // writes are safe. readPaneContent no-ops without a selected agent
    // pane; ticks during a scan/switch are skipped by isBusy.
    _contentPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      final remote = ref.read(remoteUiProvider);
      if (remote.isBusy || remote.agent == null) return;
      unawaited(ref.read(remoteUiProvider.notifier).readPaneContent());
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
    _contentPollTimer?.cancel();
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

    // Claude-mobile style: the session title (pane label) is the app
    // bar title, the agent kind + "Remote control" the subtitle.
    final sessionTitle =
        (remote.agentPaneLabel != null && remote.agentPaneLabel!.isNotEmpty)
        ? remote.agentPaneLabel!
        : (widget.paneTitle ?? agent?.kind.displayName ?? 'Agent chat');
    final subtitle = agent == null
        ? null
        : '${agent.kind.displayName} · Remote control';

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              sessionTitle,
              key: const Key('agent_console.title'),
              style: const TextStyle(fontSize: 16),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (subtitle != null)
              Text(
                subtitle,
                style: TextStyle(fontSize: 11, color: textMuted),
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
                          child: _buildStatus(
                            context,
                            remote,
                            border,
                            textMuted,
                          ),
                        ),
                      ],
                    ),
            ),
            if (agent != null) _buildComposer(context, remote, border),
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
    Color border,
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
        Expanded(
          child: (remote.paneContent == null || remote.paneContent!.isEmpty)
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No recent output available for this pane yet.\n'
                      'The transcript refreshes automatically.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: textMuted),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : Padding(
                  // Terminal-style card: the pane tail reads as a
                  // conversation transcript inside a rounded surface.
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: Scrollbar(
                    controller: _contentScrollController,
                    child: SingleChildScrollView(
                      controller: _contentScrollController,
                      padding: const EdgeInsets.all(10),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: border),
                        ),
                        padding: const EdgeInsets.all(10),
                        child: _buildTranscriptBody(
                          remote.paneContent!,
                          agent.kind,
                          border,
                          textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// Transcript body: the pane tail rendered line by line, colored by
  /// type (user messages in the primary color, agent activity muted,
  /// TUI chrome faint, dash rules as thin dividers instead of walls of
  /// `────`).
  Widget _buildTranscriptBody(
    String content,
    AgentKind kind,
    Color border,
    Color textMuted,
  ) {
    final theme = Theme.of(context);
    final rules = TranscriptRules.forKind(kind);
    final lines = content.split('\n');
    return SelectionArea(
      key: const Key('agent_console.pane_content'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            _buildTranscriptLine(
              line,
              rules: rules,
              theme: theme,
              border: border,
              textMuted: textMuted,
            ),
        ],
      ),
    );
  }

  Widget _buildTranscriptLine(
    String line, {
    required TranscriptRules rules,
    required ThemeData theme,
    required Color border,
    required Color textMuted,
  }) {
    final type = classifyTranscriptLine(line, rules: rules);
    switch (type) {
      case TranscriptLineType.divider:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Container(height: 1, color: border.withValues(alpha: 0.7)),
        );
      case TranscriptLineType.user:
        return _TranscriptLineText(
          line: line,
          linkColor: theme.colorScheme.primary,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.35,
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w500,
          ),
        );
      case TranscriptLineType.activity:
        return _TranscriptLineText(
          line: line,
          linkColor: theme.colorScheme.primary,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.35,
            color: textMuted,
          ),
        );
      case TranscriptLineType.chrome:
        if (line.trim().isEmpty) return const SizedBox(height: 5);
        return Text(
          line,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.35,
            color: textMuted.withValues(alpha: 0.7),
          ),
        );
      case TranscriptLineType.body:
        if (line.trim().isEmpty) return const SizedBox(height: 5);
        return _TranscriptLineText(
          line: line,
          linkColor: theme.colorScheme.primary,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.35,
          ),
        );
    }
  }

  Widget _buildComposer(
    BuildContext context,
    RemoteUiState remote,
    Color border,
  ) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // "+" menu (Claude-mobile style): remote-control actions.
          PopupMenuButton<String>(
            key: const Key('agent_console.plus_menu'),
            icon: const Icon(Icons.add),
            tooltip: 'Remote control actions',
            onSelected: (action) {
              if (action == 'interrupt') {
                unawaited(ref.read(remoteUiProvider.notifier).interruptAgent());
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'interrupt',
                child: Row(
                  children: [
                    Icon(Icons.stop_circle_outlined, size: 20),
                    SizedBox(width: 10),
                    Text('Interrupt agent (Ctrl+C)'),
                  ],
                ),
              ),
            ],
          ),
          Expanded(
            child: TextField(
              key: _composerKey,
              controller: _composerController,
              textInputAction: TextInputAction.send,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: 'Message the agent…',
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide(color: border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide(color: border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide(color: theme.colorScheme.primary),
                ),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 4),
          IconButton.filled(
            key: _sendButtonKey,
            onPressed: remote.isBusy ? null : _send,
            icon: const Icon(Icons.arrow_upward, size: 20),
            tooltip: 'Send',
          ),
        ],
      ),
    );
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

/// How one transcript line renders in the console.
enum TranscriptLineType { divider, user, activity, chrome, body }

/// Per-agent transcript formatting rules. Every agent TUI echoes user
/// input, activity and status chrome with its own glyphs; the rules map
/// them so the renderer can color by meaning.
///
/// [TranscriptRules.vibe] and [TranscriptRules.claude] are calibrated
/// against live pane reads; other kinds fall back to the generic
/// profile (reasonable defaults, same dash-wall/padding detection).
class TranscriptRules {
  const TranscriptRules({
    this.userPrefixes = const ['> '],
    this.activityRunes = const ['⏵'],
    this.chromeRunes = _genericChromeRunes,
    this.barePromptRunes = const ['>'],
  });

  /// Line prefixes that mark the user's own messages.
  final List<String> userPrefixes;

  /// Leading runes that mark agent activity (markers, tool results).
  final List<String> activityRunes;

  /// Leading runes that mark TUI chrome (spinners, todos, status).
  final List<String> chromeRunes;

  /// Whole-line runes: the live input prompt, chrome not a message.
  final List<String> barePromptRunes;

  static const _genericChromeRunes = [
    '■',
    '▶',
    '●',
    '☑',
    '☐',
    '⢰',
    '⠋',
    '⠙',
    '⠹',
    '⠸',
    '⠼',
    '⠴',
    '⠦',
    '⠧',
    '⠇',
    '⠏',
  ];

  /// Vibe (default profile).
  static const vibe = TranscriptRules();

  /// Claude Code: `❯` prompt, `✻` done markers, `⎿` tool results,
  /// `※` recaps, `▎` annotations, `●` alerts, `🟢` status.
  static const claude = TranscriptRules(
    userPrefixes: ['> ', '❯ '],
    activityRunes: ['✻', '✽', '✢', '✳', '✶', '※', '▎', '⎿', '●', '⏵'],
    chromeRunes: [..._genericChromeRunes, '🟢', '🔴', '❯'],
    barePromptRunes: ['>', '❯'],
  );

  /// Rules for one agent kind (generic profile for uncalibrated TUIs).
  static TranscriptRules forKind(AgentKind kind) {
    switch (kind) {
      case AgentKind.vibe:
        return vibe;
      case AgentKind.claudeCode:
        return claude;
      default:
        return const TranscriptRules();
    }
  }
}

/// One clickable URL inside a transcript line.
class TranscriptLink {
  const TranscriptLink({
    required this.start,
    required this.end,
    required this.url,
  });
  final int start;
  final int end;
  final String url;
}

final RegExp _transcriptUrlPattern = RegExp(
  r"https?://[^\s<>']+",
  caseSensitive: false,
);

/// Extracts the clickable URLs of one transcript line. Trailing
/// punctuation (`.`, `)`, `,`, `…`) is left out of the link so prose
/// like `(https://host/x).` stays tappable without the `.`.
List<TranscriptLink> extractTranscriptLinks(String line) {
  final links = <TranscriptLink>[];
  for (final match in _transcriptUrlPattern.allMatches(line)) {
    var url = match.group(0)!;
    var end = match.end;
    while (url.length > 'https://'.length &&
        RegExp(r'[).,;:!?…>»·]').hasMatch(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
      end--;
    }
    if (url.length <= 'https://'.length) continue;
    links.add(TranscriptLink(start: match.start, end: end, url: url));
  }
  return links;
}

/// Classifies one raw pane-tail line for the transcript renderer:
///
/// - TUI rules (long runs of box-drawing dashes) render as dividers,
///   not as walls of `────`.
/// - User-prefixed lines are the user's messages (the agent TUI echoes
///   input that way - including what the composer sends) - user color.
/// - Activity runes mark agent activity - muted.
/// - Chrome runes and status-bar lines (huge padding gaps survive
///   right-trimming) - fainter muted.
/// - Everything else is agent output - normal body color.
TranscriptLineType classifyTranscriptLine(
  String raw, {
  TranscriptRules rules = TranscriptRules.vibe,
}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return TranscriptLineType.body;

  // TUI rules: at least 8 visible chars, ≥80% dashes (a trailing
  // replacement char survives unwrapped reads of wide glyphs).
  final compact = trimmed.replaceAll('\uFFFD', '').trim();
  if (compact.length >= 8) {
    final nonDash = compact.replaceAll(RegExp(r'[\s─━═\-—_=~]'), '');
    if (nonDash.isEmpty || nonDash.length * 5 <= compact.length) {
      return TranscriptLineType.divider;
    }
  }

  for (final prefix in rules.userPrefixes) {
    if (trimmed.startsWith(prefix) && trimmed.length > prefix.length) {
      return TranscriptLineType.user;
    }
  }

  final first = trimmed.runes.isEmpty
      ? ''
      : String.fromCharCode(trimmed.runes.first);
  if (rules.activityRunes.contains(first)) {
    return TranscriptLineType.activity;
  }
  if (rules.barePromptRunes.contains(trimmed)) {
    return TranscriptLineType.chrome;
  }
  if (rules.chromeRunes.contains(first)) {
    return TranscriptLineType.chrome;
  }
  // Status bars survive right-trimming but keep their huge internal
  // padding gaps.
  if (RegExp(r'\s{5,}').hasMatch(trimmed)) {
    return TranscriptLineType.chrome;
  }
  return TranscriptLineType.body;
}

/// One transcript line with clickable URLs: text around each link
/// renders normally, `https?://…` spans render underlined in the
/// primary color and open the OS browser (via the app's scheme-guarded
/// external-link helpers).
///
/// Stateful on purpose: the recognizers are created once per line
/// content (the transcript re-renders every poll tick) and disposed
/// on change/unmount - creating them per build would leak.
class _TranscriptLineText extends StatefulWidget {
  const _TranscriptLineText({
    required this.line,
    required this.style,
    required this.linkColor,
  });

  final String line;
  final TextStyle style;
  final Color linkColor;

  @override
  State<_TranscriptLineText> createState() => _TranscriptLineTextState();
}

class _TranscriptLineTextState extends State<_TranscriptLineText> {
  final _recognizers = <TapGestureRecognizer>[];
  TextSpan? _span;

  @override
  void initState() {
    super.initState();
    _buildSpan();
  }

  @override
  void didUpdateWidget(_TranscriptLineText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.line != widget.line ||
        oldWidget.style != widget.style ||
        oldWidget.linkColor != widget.linkColor) {
      _buildSpan();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  void _buildSpan() {
    _disposeRecognizers();
    final links = extractTranscriptLinks(widget.line);
    final linkStyle = widget.style.copyWith(
      color: widget.linkColor,
      decoration: TextDecoration.underline,
      decorationColor: widget.linkColor.withValues(alpha: 0.5),
    );
    final children = <InlineSpan>[];
    var pos = 0;
    for (final link in links) {
      if (link.start > pos) {
        children.add(TextSpan(text: widget.line.substring(pos, link.start)));
      }
      final recognizer = TapGestureRecognizer();
      recognizer.onTap = () => unawaited(_open(link.url));
      _recognizers.add(recognizer);
      children.add(
        TextSpan(text: link.url, style: linkStyle, recognizer: recognizer),
      );
      pos = link.end;
    }
    if (pos < widget.line.length) {
      children.add(TextSpan(text: widget.line.substring(pos)));
    }
    _span = TextSpan(style: widget.style, children: children);
  }

  Future<void> _open(String url) async {
    final uri = tryParseExternalHttpUri(url);
    if (uri != null) {
      await launchExternalUri(uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(_span!);
  }
}
