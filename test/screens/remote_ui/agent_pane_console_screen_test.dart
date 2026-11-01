import 'package:flutter/material.dart';
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

  @override
  Future<void> openPane(String connectionId, String? paneId) async {
    calls.add('openPane($connectionId, $paneId)');
  }

  @override
  Future<void> sendMessage(String message) async {
    calls.add('sendMessage($message)');
  }

  @override
  Future<void> applyModel(String model) async {
    calls.add('applyModel($model)');
  }

  @override
  Future<void> applyPermission(UnifiedPermission level) async {
    calls.add('applyPermission($level)');
  }

  @override
  void clearMessages() {}
}

Widget _buildApp(_FixedRemoteUiNotifier remote) {
  return ProviderScope(
    overrides: [
      remoteUiProvider.overrideWith(() => remote),
    ],
    child: MaterialApp(home: AgentPaneConsoleScreen(connectionId: 'c1', paneId: 'w5:p3')),
  );
}

void main() {
  testWidgets('shows the detected agent and sends composer text to the pane',
      (tester) async {
    final remote = _FixedRemoteUiNotifier(
      RemoteUiState(
        connectionId: 'c1',
        isConnected: true,
        agent: VibeAdapter(),
        agentPaneId: 'w5:p3',
        agentPanePath: '/home/vincent/agents/vibe',
        config: const AgentConfig(
          model: 'mistral-large-4-0-3',
          permission: UnifiedPermission.autoReview,
        ),
      ),
    );
    await tester.pumpWidget(_buildApp(remote));
    await tester.pumpAndSettle();

    expect(find.text('Vibe'), findsOneWidget);
    expect(find.textContaining('w5:p3'), findsWidgets);
    expect(remote.calls.first, 'openPane(c1, w5:p3)');
    // Chips + composer visible for a detected agent.
    expect(find.byKey(const Key('agent_console.composer')), findsOneWidget);
    expect(find.textContaining('mistral-large-4-0-3'), findsOneWidget);
    expect(find.textContaining('Auto-review'), findsOneWidget);

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

  testWidgets('shows a hint when the pane has no detected agent',
      (tester) async {
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
}
