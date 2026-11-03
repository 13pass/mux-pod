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

  @override
  Future<void> openPane(String connectionId, String? paneId) async {
    calls.add('openPane($connectionId, $paneId)');
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
    expect(remote.calls.first, 'openPane(c1, null)');

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
}
