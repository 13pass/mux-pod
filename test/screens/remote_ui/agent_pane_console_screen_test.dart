import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_muxpod/providers/remote_ui_provider.dart';
import 'package:flutter_muxpod/screens/remote_ui/agent_pane_console_screen.dart';
import 'package:flutter_muxpod/services/agent/agent_types.dart';
import 'package:flutter_muxpod/services/agent/vibe_adapter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Notifier fake: records calls, holds a fixed state.
class _FixedRemoteUiNotifier extends RemoteUiNotifier {
  _FixedRemoteUiNotifier(this.initial);

  final RemoteUiState initial;
  final List<String> calls = [];

  @override
  RemoteUiState build() => initial;

  /// Emits a new state so ref.listen callbacks fire (provider errors).
  void emit(RemoteUiState next) => state = next;

  @override
  Future<void> readPaneContent({int lines = 40}) async {
    calls.add('readPaneContent');
  }

  @override
  Future<void> openPane(
    String connectionId,
    String? paneId, {
    bool readContent = true,
  }) async {
    calls.add('openPane($connectionId, $paneId)');
  }

  @override
  Future<void> sendMessage(String message) async {
    calls.add('sendMessage($message)');
  }

  @override
  @override
  void clearMessages() {}
}

/// Guards the build-phase contract: openPane's synchronous prefix writes
/// provider state, which Riverpod forbids while the widget tree is
/// building ("Tried to modify a provider while the widget tree was
/// building"). This notifier fails the test if that regresses.
class _BuildPhaseRemoteUiNotifier extends RemoteUiNotifier {
  _BuildPhaseRemoteUiNotifier(this.initial);

  final RemoteUiState initial;
  final List<String> calls = [];

  @override
  RemoteUiState build() => initial;

  @override
  Future<void> openPane(
    String connectionId,
    String? paneId, {
    bool readContent = true,
  }) async {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      throw StateError('openPane ran during the build phase: $phase');
    }
    calls.add('openPane($connectionId, $paneId)');
  }
}

Widget _buildApp(RemoteUiNotifier remote) {
  return ProviderScope(
    overrides: [remoteUiProvider.overrideWith(() => remote)],
    child: MaterialApp(
      home: AgentPaneConsoleScreen(connectionId: 'c1', paneId: 'w5:p3'),
    ),
  );
}

void main() {
  testWidgets('shows the detected agent and sends composer text to the pane', (
    tester,
  ) async {
    final remote = _FixedRemoteUiNotifier(
      RemoteUiState(
        connectionId: 'c1',
        isConnected: true,
        agent: VibeAdapter(),
        agentPaneId: 'w5:p3',
        agentPanePath: '/home/vincent/agents/vibe',
      ),
    );
    await tester.pumpWidget(_buildApp(remote));
    await tester.pumpAndSettle();

    expect(find.text('Vibe'), findsOneWidget);
    // Claude-mobile style app bar: agent kind + Remote control subtitle;
    // the raw pane id does not appear anywhere in the chat UI.
    expect(find.textContaining('Remote control'), findsOneWidget);
    expect(find.textContaining('w5:p3'), findsNothing);
    expect(remote.calls.first, 'openPane(c1, w5:p3)');
    // Composer visible for a detected agent; no model/permission chips.
    expect(find.byKey(const Key('agent_console.model_chip')), findsNothing);
    expect(
      find.byKey(const Key('agent_console.permission_chip')),
      findsNothing,
    );
    expect(find.byKey(const Key('agent_console.composer')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('agent_console.composer')),
      'hello harness',
    );
    await tester.tap(find.byKey(const Key('agent_console.send_button')));
    await tester.pumpAndSettle();

    expect(remote.calls, contains('sendMessage(hello harness)'));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('agent_console.composer')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('shows a hint when the pane has no detected agent', (
    tester,
  ) async {
    final remote = _FixedRemoteUiNotifier(
      RemoteUiState(connectionId: 'c1', isConnected: true),
    );
    await tester.pumpWidget(_buildApp(remote));
    await tester.pumpAndSettle();

    expect(find.text('Agent chat'), findsOneWidget);
    expect(find.textContaining('No AI agent detected'), findsOneWidget);
    // No composer without an agent.
    expect(find.byKey(const Key('agent_console.composer')), findsNothing);
  });

  testWidgets('keeps a provider error visible in the status area', (
    tester,
  ) async {
    final remote = _FixedRemoteUiNotifier(
      RemoteUiState(connectionId: 'c1', isConnected: true),
    );
    await tester.pumpWidget(_buildApp(remote));
    await tester.pumpAndSettle();

    // The provider reports a transient exec failure (e.g. a scan that
    // died on a timeout).
    remote.emit(remote.initial.copyWith(error: 'Command execution timed out'));
    await tester.pump();

    // The status area message becomes the error itself (the snackbar
    // may still be animating out; the keyed status text is the
    // persistence contract).
    final status = tester.widget<Text>(
      find.byKey(const Key('agent_console.status_message')),
    );
    expect(status.data, 'Command execution timed out');
  });

  testWidgets('shows the pane recent output as the last messages', (
    tester,
  ) async {
    final remote = _FixedRemoteUiNotifier(
      RemoteUiState(
        connectionId: 'c1',
        isConnected: true,
        agent: VibeAdapter(),
        agentPaneId: 'w5:p3',
        agentPaneLabel: 'vibe · muxpod',
        paneContent:
            '> user: hello\n'
            '────────────────────\uFFFD\n'
            'agent: hi there',
      ),
    );
    await tester.pumpWidget(_buildApp(remote));
    await tester.pumpAndSettle();

    // Body text renders as a line; user lines and TUI dash walls are
    // classified (dash walls become dividers, not text).
    expect(find.textContaining('agent: hi there'), findsOneWidget);
    expect(find.textContaining('> user: hello'), findsOneWidget);
    expect(find.textContaining('───'), findsNothing);
  });

  testWidgets('offers a refresh hint when no output was read', (tester) async {
    final remote = _FixedRemoteUiNotifier(
      RemoteUiState(
        connectionId: 'c1',
        isConnected: true,
        agent: VibeAdapter(),
        agentPaneId: 'w5:p3',
      ),
    );
    await tester.pumpWidget(_buildApp(remote));
    await tester.pumpAndSettle();

    expect(find.textContaining('No recent output available'), findsOneWidget);
    expect(find.byKey(const Key('agent_console.pane_content')), findsNothing);
  });

  testWidgets('never calls openPane while the frame is building', (
    tester,
  ) async {
    final remote = _BuildPhaseRemoteUiNotifier(
      RemoteUiState(connectionId: 'c1', isConnected: true),
    );
    await tester.pumpWidget(_buildApp(remote));
    await tester.pumpAndSettle();

    // The initial open ran once, after the frame (a build-phase call
    // would have thrown inside the notifier and surfaced as
    // "Console failed to open" in the status area).
    expect(remote.calls, ['openPane(c1, w5:p3)']);
    expect(find.textContaining('Console failed to open'), findsNothing);
  });

  testWidgets('polls the pane content while the console is open', (
    tester,
  ) async {
    final remote = _FixedRemoteUiNotifier(
      RemoteUiState(
        connectionId: 'c1',
        isConnected: true,
        agent: VibeAdapter(),
        agentPaneId: 'w5:p3',
      ),
    );
    await tester.pumpWidget(_buildApp(remote));
    await tester.pumpAndSettle();

    int contentReads() =>
        remote.calls.where((c) => c == 'readPaneContent').length;

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(contentReads(), 2);
  });

  group('classifyTranscriptLine', () {
    test('TUI dash walls classify as dividers', () {
      expect(
        classifyTranscriptLine('─────────────────────────────────────\uFFFD'),
        TranscriptLineType.divider,
      );
      expect(
        classifyTranscriptLine('――――― short'),
        isNot(TranscriptLineType.divider),
      );
    });

    test('user input lines classify as user', () {
      expect(
        classifyTranscriptLine('> peux tu aussi remplacer les tirets'),
        TranscriptLineType.user,
      );
      // The bare live-input prompt is chrome, not a message.
      expect(classifyTranscriptLine('>'), TranscriptLineType.chrome);
    });

    test('agent activity markers classify as activity', () {
      expect(
        classifyTranscriptLine('⏵ Ran 6 commands, thought'),
        TranscriptLineType.activity,
      );
    });

    test('spinner, todo and status-bar lines classify as chrome', () {
      expect(
        classifyTranscriptLine('⢰ Running command… (33s Esc/Ctrl+C)'),
        TranscriptLineType.chrome,
      );
      expect(
        classifyTranscriptLine('▶ 1/6 · Fix bug 1: sessions list timer'),
        TranscriptLineType.chrome,
      );
      expect(
        classifyTranscriptLine(
          '~/agents/vibe                    GLM-5.3 (Mistral Hosted)[max] · 241k/800k tokens (30%)',
        ),
        TranscriptLineType.chrome,
      );
    });

    test('prose and empty lines classify as body', () {
      expect(
        classifyTranscriptLine('  The main test replacement never landed.'),
        TranscriptLineType.body,
      );
      expect(classifyTranscriptLine(''), TranscriptLineType.body);
    });

    test('claude profile: calibrated against a live pane read', () {
      const rules = TranscriptRules.claude;
      // User input (typed history and the live ❯ prompt).
      expect(
        classifyTranscriptLine('> can you fix the pricing?', rules: rules),
        TranscriptLineType.user,
      );
      expect(
        classifyTranscriptLine('❯ can you fix the pricing?', rules: rules),
        TranscriptLineType.user,
      );
      expect(
        classifyTranscriptLine('❯', rules: rules),
        TranscriptLineType.chrome, // bare live prompt
      );
      // Activity: done markers, tool results, recaps, annotations.
      expect(
        classifyTranscriptLine(
          '✻ Sautéed for 6m 44s · done 17:55',
          rules: rules,
        ),
        TranscriptLineType.activity,
      );
      expect(
        classifyTranscriptLine('⎿ Read 4 lines (selected 1)', rules: rules),
        TranscriptLineType.activity,
      );
      expect(
        classifyTranscriptLine(
          '※ recap: Merged main into your Langfuse branch',
          rules: rules,
        ),
        TranscriptLineType.activity,
      );
      expect(
        classifyTranscriptLine(
          '▎ UNVERIFIED — not readable off the page',
          rules: rules,
        ),
        TranscriptLineType.activity,
      );
      expect(
        classifyTranscriptLine(
          '● Remote Control disconnected — run /login',
          rules: rules,
        ),
        TranscriptLineType.activity,
      );
      // Status bar.
      expect(
        classifyTranscriptLine(
          '🟢 Opus 5 (1M context) ▓▓░░░░░░░░ 20% | \$11.73 | 102g CO₂',
          rules: rules,
        ),
        TranscriptLineType.chrome,
      );
      // Prose stays body.
      expect(
        classifyTranscriptLine(
          '  The placeholder over-stated prices.',
          rules: rules,
        ),
        TranscriptLineType.body,
      );
    });

    test('extractTranscriptLinks finds URLs and trims punctuation', () {
      expect(extractTranscriptLinks('no url here'), isEmpty);
      final single = extractTranscriptLinks(
        'Download: https://share.angou.fr/f/abc123/ today.',
      );
      expect(single, hasLength(1));
      expect(single.single.url, 'https://share.angou.fr/f/abc123/');
      // The prose around the link is preserved by start/end offsets.
      final line = 'see (https://example.com/x?y=1) and https://z.io/a, ok?';
      final links = extractTranscriptLinks(line);
      expect(links, hasLength(2));
      expect(links[0].url, 'https://example.com/x?y=1');
      expect(links[1].url, 'https://z.io/a');
      for (final link in links) {
        expect(line.substring(link.start, link.end), link.url);
      }
    });

    test('forKind maps kinds to profiles', () {
      expect(
        TranscriptRules.forKind(AgentKind.vibe),
        same(TranscriptRules.vibe),
      );
      expect(
        TranscriptRules.forKind(AgentKind.claudeCode),
        same(TranscriptRules.claude),
      );
      // Uncalibrated kinds get the generic profile.
      expect(
        TranscriptRules.forKind(AgentKind.codex),
        isNot(same(TranscriptRules.claude)),
      );
    });
  });
}
