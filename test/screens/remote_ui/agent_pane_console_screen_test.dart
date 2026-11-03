import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_muxpod/providers/remote_ui_provider.dart';
import 'package:flutter_muxpod/screens/remote_ui/agent_pane_console_screen.dart';
import 'package:flutter_muxpod/services/agent/claude_code_adapter.dart';
import 'package:flutter_muxpod/services/agent/pane_io.dart';
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
  Future<void> openPane(String connectionId, String? paneId) async {
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
  Future<void> openPane(String connectionId, String? paneId) async {
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

  testWidgets('switcher lists every detected agent and switches panes', (
    tester,
  ) async {
    final remote = _FixedRemoteUiNotifier(
      RemoteUiState(
        connectionId: 'c1',
        isConnected: true,
        agent: VibeAdapter(),
        agentPaneId: 'w5:p3',
        agentPaneLabel: 'vibe · muxpod',
        detectedAgents: [
          DetectedAgent(
            pane: const AgentPaneInfo(
              id: 'w5:p3',
              command: 'vibe',
              workspace: 'vibe',
              tab: 'muxpod',
            ),
            adapter: VibeAdapter(),
          ),
          DetectedAgent(
            pane: const AgentPaneInfo(
              id: 'w7:p2',
              command: 'claude',
              workspace: 'Dintel',
              tab: 'langfuse',
            ),
            adapter: ClaudeCodeAdapter(),
          ),
        ],
      ),
    );
    await tester.pumpWidget(_buildApp(remote));
    await tester.pumpAndSettle();

    // Chips labeled with workspace/tab names, not raw pane ids.
    expect(find.text('vibe · muxpod'), findsWidgets);
    expect(find.text('Dintel · langfuse'), findsOneWidget);
    expect(find.textContaining('w7:p2'), findsNothing);

    await tester.tap(find.byKey(const Key('agent_console.agent_chip_w7:p2')));
    await tester.pumpAndSettle();

    expect(remote.calls, contains('openPane(c1, w7:p2)'));
  });

  testWidgets('switcher stays hidden for a single active agent', (
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

    expect(
      find.byKey(const Key('agent_console.agent_chip_w5:p3')),
      findsNothing,
    );
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
        paneContent: 'user: hello\nagent: hi there',
      ),
    );
    await tester.pumpWidget(_buildApp(remote));
    await tester.pumpAndSettle();

    final preview = tester.widget<SelectableText>(
      find.byKey(const Key('agent_console.pane_content')),
    );
    expect(preview.data, contains('agent: hi there'));
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
}
