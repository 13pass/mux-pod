import 'package:flutter/material.dart';
import 'package:flutter_muxpod/providers/remote_ui_provider.dart';
import 'package:flutter_muxpod/screens/remote_ui/agent_pane_console_screen.dart';
import 'package:flutter_muxpod/screens/remote_ui/agent_sessions_screen.dart';
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

  /// Emits a new state so ref.listen/watch see rescan activity.
  void emit(RemoteUiState next) => state = next;

  @override
  Future<void> openPane(
    String connectionId,
    String? paneId, {
    bool readContent = true,
  }) async {
    calls.add('openPane($connectionId, $paneId, readContent: $readContent)');
  }
}

Widget _buildApp(_FixedRemoteUiNotifier remote) {
  return ProviderScope(
    overrides: [remoteUiProvider.overrideWith(() => remote)],
    child: const MaterialApp(home: AgentSessionsScreen(connectionId: 'c1')),
  );
}

void main() {
  testWidgets('lists one Claude-style card per detected agent', (tester) async {
    final remote = _FixedRemoteUiNotifier(
      RemoteUiState(
        connectionId: 'c1',
        isConnected: true,
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
              agentStatus: 'idle',
            ),
            adapter: ClaudeCodeAdapter(),
          ),
        ],
      ),
    );
    await tester.pumpWidget(_buildApp(remote));
    await tester.pumpAndSettle();

    // Session titles use the human pane labels.
    expect(find.text('vibe · muxpod'), findsOneWidget);
    expect(find.text('Dintel · langfuse'), findsOneWidget);
    // Claude-mobile caption row: kind + Remote control (+ status).
    expect(find.textContaining('Vibe · Remote control'), findsOneWidget);
    expect(
      find.textContaining('Claude Code · Remote control · idle'),
      findsOneWidget,
    );
    expect(remote.calls.first, 'openPane(c1, null, readContent: false)');

    // Tapping a card opens the chat console for that pane.
    await tester.tap(find.byKey(const Key('agent_sessions.card_w7:p2')));
    await tester.pumpAndSettle();
    expect(find.byType(AgentPaneConsoleScreen), findsOneWidget);
  });

  testWidgets('shows an empty state with retry when nothing is detected', (
    tester,
  ) async {
    final remote = _FixedRemoteUiNotifier(
      RemoteUiState(connectionId: 'c1', isConnected: true),
    );
    await tester.pumpWidget(_buildApp(remote));
    await tester.pumpAndSettle();

    expect(find.textContaining('No AI agents detected'), findsOneWidget);
    expect(find.byKey(const Key('agent_sessions.retry')), findsOneWidget);
  });

  testWidgets('rescans keep the list visible under a thin progress bar', (
    tester,
  ) async {
    final remote = _FixedRemoteUiNotifier(
      RemoteUiState(
        connectionId: 'c1',
        isConnected: true,
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
        ],
      ),
    );
    await tester.pumpWidget(_buildApp(remote));
    await tester.pumpAndSettle();

    // A rescan goes busy: the card must stay on screen (no full-screen
    // loading flicker), only the progress bar appears.
    remote.emit(remote.initial.copyWith(isBusy: true));
    await tester.pump();
    expect(find.text('vibe · muxpod'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('list rescans stop while a chat console is open on top', (
    tester,
  ) async {
    final remote = _FixedRemoteUiNotifier(
      RemoteUiState(
        connectionId: 'c1',
        isConnected: true,
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
    final scansBeforeConsole = remote.calls
        .where((c) => c.contains('openPane'))
        .length;

    await tester.tap(find.byKey(const Key('agent_sessions.card_w7:p2')));
    await tester.pumpAndSettle();

    // Well past the 10s rescan period: the only extra scan is the
    // console's own initial open (for its pane) - the LIST must not
    // rescan while the console owns the shared provider state.
    await tester.pump(const Duration(seconds: 25));
    expect(
      remote.calls.where((c) => c.contains('openPane')).length,
      scansBeforeConsole + 1,
    );
    expect(remote.calls.last, 'openPane(c1, w7:p2, readContent: true)');
  });
}
