import 'package:flutter_muxpod/services/agent/pane_io.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_agent_transport.dart';

/// Canned herdr CLI envelopes (shape verified against herdr 0.9.3).
/// Real herdr 0.9 shape: `result.snapshot` is an object whose `panes`
/// key holds the pane list (verified against a live server).
const _snapshotJson = '''
{"id":"cli:api:snapshot","result":{"snapshot":{
  "protocol":22,
  "workspaces":[],
  "tabs":[],
  "panes":[
    {"pane_id":"w5:p1","workspace_id":"w5","tab_id":"w5:t1","cwd":"/home/vincent/agents/vibe/revision-loyers"},
    {"pane_id":"w5:p3","workspace_id":"w5","tab_id":"w5:t3","cwd":"/home/vincent/agents/vibe","terminal_title":"Vibe"},
    {"pane_id":"w5:p4","workspace_id":"w5","tab_id":"w5:t4","cwd":"/srv/www"}
  ]
}}}
''';

String _processInfoJson(String name) => '''
{"id":"cli:pane:process_info","result":{"process_info":{
  "pane_id":"x","shell_pid":1,
  "foreground_processes":[{"name":"$name","cmdline":"$name","pid":42,"cwd":"/tmp"}]
}}}
''';

void main() {
  group('HerdrPaneIO', () {
    test('listPanes parses snapshot and resolves each foreground process',
        () async {
      final t = FakeAgentTransport();
      final io = HerdrPaneIO(t, herdrBin: '/usr/local/bin/herdr');
      t.onExec = (command) {
        if (command.contains('api snapshot')) return _snapshotJson;
        if (command.contains('pane process-info --pane w5:p1')) {
          return _processInfoJson('zsh');
        }
        if (command.contains('pane process-info --pane w5:p3')) {
          return _processInfoJson('Vibe CLI');
        }
        if (command.contains('pane process-info --pane w5:p4')) {
          return _processInfoJson('node');
        }
        throw StateError('unexpected: $command');
      };

      final panes = await io.listPanes();

      expect(panes, hasLength(3));
      expect(panes[0], isA<AgentPaneInfo>());
      expect(panes[0].id, 'w5:p1');
      expect(panes[0].command, 'zsh');
      expect(panes[1].id, 'w5:p3');
      // "Vibe CLI" reduces to its first word for detection.
      expect(panes[1].command, 'vibe');
      expect(panes[1].path, '/home/vincent/agents/vibe');
      expect(panes[2].command, 'node');
      // The custom herdr binary path is used.
      expect(
        t.execCommands.first,
        '/usr/local/bin/herdr api snapshot',
      );
    });

    test('currentCommand returns the lowercased first word of the process name',
        () async {
      final t = FakeAgentTransport();
      final io = HerdrPaneIO(t);
      t.onExec = (_) => _processInfoJson('Vibe CLI');
      expect(await io.currentCommand('w5:p3'), 'vibe');
    });

    test('typeLiteral/pressEnter/pressInterrupt use herdr pane commands',
        () async {
      final t = FakeAgentTransport();
      final io = HerdrPaneIO(t);
      await io.typeLiteral('w5:p3', 'hello agent');
      await io.pressEnter('w5:p3');
      await io.pressInterrupt('w5:p3');
      expect(t.sentKeyCommands, [
        "herdr pane send-text w5:p3 'hello agent'",
        'herdr pane send-keys w5:p3 Enter',
        'herdr pane send-keys w5:p3 C-c',
      ]);
    });

    test('listPanes tolerates a pane that disappears mid-scan', () async {
      final t = FakeAgentTransport();
      final io = HerdrPaneIO(t);
      var calls = 0;
      t.onExec = (command) {
        if (command.contains('api snapshot')) return _snapshotJson;
        if (command.contains('process-info')) {
          calls++;
          if (calls == 2) throw StateError('pane closed');
        }
        return _processInfoJson('zsh');
      };
      final panes = await io.listPanes();
      expect(panes, hasLength(3));
      expect(panes[1].command, isNull); // the vanished pane
    });
  });
}
