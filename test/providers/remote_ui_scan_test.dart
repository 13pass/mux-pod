import 'package:flutter_muxpod/providers/remote_ui_provider.dart';
import 'package:flutter_muxpod/services/agent/claude_code_adapter.dart';
import 'package:flutter_muxpod/services/agent/pane_io.dart';
import 'package:flutter_muxpod/services/agent/vibe_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RemoteUiNotifier.scanPanes', () {
    const shellPane = AgentPaneInfo(id: 'w5:p1', command: 'zsh');
    const vibePane = AgentPaneInfo(
      id: 'w5:p3',
      command: 'vibe',
      path: '/home/vincent/agents/vibe',
      workspace: 'vibe',
      tab: 'muxpod',
      title: 'Vibe',
    );
    const vibeRsPane = AgentPaneInfo(
      id: 'w5:p6',
      command: 'vibe-rs',
      path: '/srv/app',
      workspace: 'vibe',
      tab: 'site-apero',
    );
    const claudePane = AgentPaneInfo(
      id: 'w7:p2',
      command: 'claude',
      workspace: 'Dintel',
      tab: 'langfuse',
    );

    test('collects every detected agent with its pane', () {
      final scan = RemoteUiNotifier.scanPanes([
        shellPane,
        vibePane,
        vibeRsPane,
        claudePane,
      ], null);
      expect(scan.agents, hasLength(3));
      expect(scan.agents[0].pane.id, 'w5:p3');
      expect(scan.agents[0].adapter, isA<VibeAdapter>());
      expect(scan.agents[1].pane.id, 'w5:p6');
      expect(scan.agents[2].adapter, isA<ClaudeCodeAdapter>());
      // No pane id given: the first detected agent is the target.
      expect(scan.target!.pane.id, 'w5:p3');
    });

    test('carries the reported lifecycle status onto the agent', () {
      final scan = RemoteUiNotifier.scanPanes([
        const AgentPaneInfo(
          id: 'w7:p2',
          command: 'claude',
          agentStatus: 'idle',
        ),
        const AgentPaneInfo(id: 'w5:p3', command: 'vibe'),
      ], null);
      expect(scan.agents.first.status, 'idle');
      expect(scan.agents.last.status, isNull);
    });

    test('targets the requested pane when given', () {
      final scan = RemoteUiNotifier.scanPanes([
        shellPane,
        vibePane,
        claudePane,
      ], 'w7:p2');
      expect(scan.target!.pane.id, 'w7:p2');
      expect(scan.target!.adapter, isA<ClaudeCodeAdapter>());
      expect(scan.agents, hasLength(2));
    });

    test('null target when the requested pane has no agent', () {
      final scan = RemoteUiNotifier.scanPanes([shellPane, vibePane], 'w5:p1');
      expect(scan.target, isNull);
      expect(scan.agents, hasLength(1));
      // The detail explains what the focused pane runs.
      expect(scan.detail, startsWith('pane w5:p1: zsh'));
      expect(scan.detail, contains('scan: 2 panes, 2 command(s) resolved'));
    });

    test('null target on an empty server', () {
      final scan = RemoteUiNotifier.scanPanes([shellPane], null);
      expect(scan.target, isNull);
      expect(scan.agents, isEmpty);
      // No focused pane id: the detail only carries scan stats.
      expect(scan.detail, ' | scan: 1 panes, 1 command(s) resolved');
    });

    test('app interactions outrank server-side activity', () {
      final scan = RemoteUiNotifier.scanPanes(
        [
          const AgentPaneInfo(id: 'a', command: 'vibe', agentStateSeq: 60),
          const AgentPaneInfo(id: 'b', command: 'claude', agentStateSeq: 10),
        ],
        null,
        interactionMs: {'b': 123, 'a': 45},
      );
      // The user interacted with 'b' most recently FROM THE APP: it
      // ranks above the server-side busier agent.
      expect(scan.agents.map((a) => a.pane.id).toList(), ['b', 'a']);
      expect(scan.target!.pane.id, 'b');
    });

    test('orders agents by last interaction (sequence) first', () {
      final scan = RemoteUiNotifier.scanPanes([
        // Old start, but the most recent interaction (highest seq).
        const AgentPaneInfo(
          id: 'a',
          command: 'claude',
          agentStartedAtMs: 100,
          agentStateSeq: 60,
        ),
        // Recent start, older interaction.
        const AgentPaneInfo(
          id: 'b',
          command: 'vibe',
          agentStartedAtMs: 900,
          agentStateSeq: 10,
        ),
        // No sequence (herdr does not report it): after the seq group,
        // by start descending.
        const AgentPaneInfo(id: 'c', command: 'vibe-rs', agentStartedAtMs: 800),
        const AgentPaneInfo(id: 'd', command: 'droid', agentStartedAtMs: 50),
      ], null);
      expect(scan.agents.map((a) => a.pane.id).toList(), ['a', 'b', 'c', 'd']);
      expect(scan.target!.pane.id, 'a');
    });

    test('orders agents most recent first, unknown starts last', () {
      final scan = RemoteUiNotifier.scanPanes([
        const AgentPaneInfo(id: 'a', command: 'vibe', agentStartedAtMs: 100),
        const AgentPaneInfo(id: 'b', command: 'claude'),
        const AgentPaneInfo(id: 'c', command: 'vibe', agentStartedAtMs: 300),
        const AgentPaneInfo(id: 'd', command: 'vibe-rs', agentStartedAtMs: 300),
        const AgentPaneInfo(id: 'e', command: 'droid'),
      ], null);
      // Newest start at the top; equal starts keep scan order;
      // unknown starts at the end in scan order.
      expect(scan.agents.map((a) => a.pane.id).toList(), [
        'c',
        'd',
        'a',
        'b',
        'e',
      ]);
      // No focused pane: the most recent session is the target.
      expect(scan.target!.pane.id, 'c');
    });

    test('panes without a resolved command count as unresolved', () {
      final scan = RemoteUiNotifier.scanPanes([
        const AgentPaneInfo(id: 'w5:p2'),
        vibePane,
      ], 'w5:p2');
      expect(scan.target, isNull);
      expect(scan.detail, contains('1 command(s) resolved'));
    });
  });
}
