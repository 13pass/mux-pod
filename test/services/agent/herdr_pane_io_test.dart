import 'package:flutter_muxpod/services/agent/pane_io.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_agent_transport.dart';

/// Canned herdr CLI envelopes (shape verified against a live herdr 0.9
/// server): `result.snapshot` carries `panes` plus `agents` (herdr's own
/// agent report: pane_id -> agent name) and workspace/tab labels.
const _snapshotJson = '''
{"id":"cli:api:snapshot","result":{"snapshot":{
  "protocol":22,
  "workspaces":[{"workspace_id":"w5","label":"vibe"}],
  "tabs":[
    {"tab_id":"w5:t1","label":"shell","workspace_id":"w5"},
    {"tab_id":"w5:t3","label":"muxpod","workspace_id":"w5"},
    {"tab_id":"w5:t4","label":"srv","workspace_id":"w5"},
    {"tab_id":"w5:t5","label":"gitea","workspace_id":"w5"}
  ],
  "panes":[
    {"pane_id":"w5:p1","workspace_id":"w5","tab_id":"w5:t1","cwd":"/home/vincent/agents/vibe/revision-loyers"},
    {"pane_id":"w5:p3","workspace_id":"w5","tab_id":"w5:t3","cwd":"/home/vincent/agents/vibe","terminal_title":"Vibe"},
    {"pane_id":"w5:p4","workspace_id":"w5","tab_id":"w5:t4","cwd":"/srv/www"},
    {"pane_id":"w5:p5","workspace_id":"w5","tab_id":"w5:t5","cwd":"/srv/gitea"}
  ],
  "agents":[
    {"agent":"claude","agent_status":"idle","pane_id":"w5:p4","workspace_id":"w5","tab_id":"w5:t4","cwd":"/srv/www"},
    {"agent":"mistral-vibe","agent_status":"working","pane_id":"w5:p5","workspace_id":"w5","tab_id":"w5:t5","cwd":"/srv/gitea"}
  ]
}}}
''';

String _processInfoJson(String name) =>
    '''
{"id":"cli:pane:process_info","result":{"process_info":{
  "pane_id":"x","shell_pid":1,
  "foreground_processes":[{"name":"$name","cmdline":"$name","pid":42,"cwd":"/tmp"}]
}}}
''';

void main() {
  group('HerdrPaneIO', () {
    test('listPanes resolves foregrounds in ONE batched exec and merges '
        'herdr agent reports', () async {
      final t = FakeAgentTransport();
      final io = HerdrPaneIO(t, herdrBin: '/usr/local/bin/herdr');
      t.onExec = (command) {
        if (command.startsWith('test -x -- ')) return ''; // bin verification
        if (command.contains('api snapshot')) return _snapshotJson;
        if (command.contains('<<<MUXPOD')) {
          // Batched loop output, framed per pane.
          return '\n<<<MUXPOD:w5:p1>>>'
              '${_processInfoJson('zsh')}'
              '\n<<<MUXPOD:w5:p3>>>'
              '${_processInfoJson('Vibe CLI')}';
        }
        throw StateError('unexpected: $command');
      };

      final panes = await io.listPanes();

      expect(panes, hasLength(4));
      expect(panes[0], isA<AgentPaneInfo>());
      expect(panes[0].id, 'w5:p1');
      expect(panes[0].command, 'zsh');
      expect(panes[1].id, 'w5:p3');
      // "Vibe CLI" reduces to its first word for detection.
      expect(panes[1].command, 'vibe');
      expect(panes[1].path, '/home/vincent/agents/vibe');
      // Workspace / tab labels resolve through the snapshot.
      expect(panes[1].workspace, 'vibe');
      expect(panes[1].tab, 'muxpod');
      // herdr's own report identifies w5:p4 (its foreground process is a
      // wrapper); no probe was issued for it and the report wins.
      expect(panes[2].command, 'claude');
      // The herdr-vibe plugin reports Vibe sessions as "mistral-vibe".
      expect(panes[3].command, 'mistral-vibe');
      expect(panes[3].tab, 'gitea');
      // The custom herdr binary path is used (after the test -x probe).
      expect(t.execCommands.first, 'test -x -- /usr/local/bin/herdr');
      expect(t.execCommands[1], '/usr/local/bin/herdr api snapshot');
      // Exactly ONE process-info exec for both probed panes.
      final probes = t.execCommands
          .where((c) => c.contains('process-info'))
          .toList();
      expect(probes, hasLength(1));
      expect(probes.single, contains('w5:p1'));
      expect(probes.single, contains('w5:p3'));
      expect(probes.single, isNot(contains('w5:p4')));
      expect(probes.single, isNot(contains('w5:p5')));
    });

    test(
      'listPanes falls back to per-pane probes when the batch fails',
      () async {
        final t = FakeAgentTransport();
        final io = HerdrPaneIO(t, herdrBin: '/usr/local/bin/herdr');
        t.onExec = (command) {
          if (command.startsWith('test -x -- ')) return '';
          if (command.contains('api snapshot')) return _snapshotJson;
          if (command.contains('<<<MUXPOD')) return ''; // unparseable batch
          if (command.contains('process-info --pane w5:p1')) {
            return _processInfoJson('zsh');
          }
          if (command.contains('process-info --pane w5:p3')) {
            return _processInfoJson('Vibe CLI');
          }
          throw StateError('unexpected: $command');
        };

        final panes = await io.listPanes();

        expect(panes[0].command, 'zsh');
        expect(panes[1].command, 'vibe');
        // Even on the fallback path the herdr report wins for w5:p4.
        expect(panes[2].command, 'claude');
        // Per-pane probes were issued only for the unreported panes (the
        // batch command itself mentions --pane and must not count).
        final probes = t.execCommands
            .where(
              (c) =>
                  c.contains('process-info --pane') && !c.contains('<<<MUXPOD'),
            )
            .toList();
        expect(probes, hasLength(2));
      },
    );

    test(
      'listPanes falls back to per-pane probes when the batch exec throws',
      () async {
        final t = FakeAgentTransport();
        final io = HerdrPaneIO(t, herdrBin: '/usr/local/bin/herdr');
        t.onExec = (command) {
          if (command.startsWith('test -x -- ')) return '';
          if (command.contains('api snapshot')) return _snapshotJson;
          if (command.contains('<<<MUXPOD')) {
            throw StateError('channel error'); // transient exec failure
          }
          if (command.contains('process-info --pane w5:p1')) {
            return _processInfoJson('zsh');
          }
          if (command.contains('process-info --pane w5:p3')) {
            return _processInfoJson('Vibe CLI');
          }
          throw StateError('unexpected: $command');
        };

        final panes = await io.listPanes();

        expect(panes[0].command, 'zsh');
        expect(panes[1].command, 'vibe');
        expect(panes[2].command, 'claude'); // herdr report wins on fallback
        expect(panes[3].command, 'mistral-vibe');
        final probes = t.execCommands
            .where(
              (c) =>
                  c.contains('process-info --pane') && !c.contains('<<<MUXPOD'),
            )
            .toList();
        expect(probes, hasLength(2));
      },
    );

    test('snapshot exec retries once after a transient failure', () async {
      final t = FakeAgentTransport();
      final io = HerdrPaneIO(t, herdrBin: '/usr/local/bin/herdr');
      var snapshotCalls = 0;
      t.onExec = (command) {
        if (command.startsWith('test -x -- ')) return '';
        if (command.contains('api snapshot')) {
          snapshotCalls++;
          if (snapshotCalls == 1) throw StateError('transient');
          return _snapshotJson;
        }
        if (command.contains('<<<MUXPOD')) {
          return '\n<<<MUXPOD:w5:p1>>>'
              '${_processInfoJson('zsh')}'
              '\n<<<MUXPOD:w5:p3>>>'
              '${_processInfoJson('Vibe CLI')}';
        }
        throw StateError('unexpected: $command');
      };

      final panes = await io.listPanes();

      expect(snapshotCalls, 2); // one transient failure + one retry
      expect(panes, hasLength(4));
      expect(panes[0].command, 'zsh');
      expect(panes[1].command, 'vibe');
    });

    test('readRecentContent reads unwrapped text and strips padding', () async {
      final t = FakeAgentTransport();
      final io = HerdrPaneIO(t, herdrBin: '/usr/local/bin/herdr');
      t.onExec = (command) {
        if (command.startsWith('test -x -- ')) return '';
        if (command.contains('pane read w5:p3')) {
          return 'user: do the thing   \nagent: done             \n';
        }
        throw StateError('unexpected: $command');
      };
      final content = await io.readRecentContent('w5:p3', lines: 12);
      expect(content, 'user: do the thing\nagent: done');
      final read = t.execCommands.where((c) => c.contains('pane read')).single;
      expect(read, contains('--source recent-unwrapped'));
      expect(read, contains('--lines 12'));
      expect(read, contains('--format text'));
    });

    test('readRecentContent is empty on failure', () async {
      final t = FakeAgentTransport();
      final io = HerdrPaneIO(t, herdrBin: '/usr/local/bin/herdr');
      t.onExec = (command) {
        if (command.startsWith('test -x -- ')) return '';
        throw StateError('channel error');
      };
      expect(await io.readRecentContent('w5:p3'), isEmpty);
    });

    test(
      'currentCommand prefers a known agent among the foreground list',
      () async {
        final t = FakeAgentTransport();
        final io = HerdrPaneIO(t, herdrBin: '/usr/local/bin/herdr');
        // herdr lists lingering helpers (xdg-open) ahead of the pane's
        // real agent (verified on a live server).
        t.onExec = (command) {
          if (command.startsWith('test -x -- ')) return '';
          if (command.contains('process-info --pane w5:p8')) {
            return '''
{"id":"cli:pane:process_info","result":{"process_info":{
  "pane_id":"x","shell_pid":1,
  "foreground_processes":[
    {"name":"xdg-open","pid":1},
    {"name":"xdg-open","pid":2},
    {"name":"xdg-open","pid":3},
    {"name":"vibe-rs","pid":4}
  ]
}}}
''';
          }
          throw StateError('unexpected: $command');
        };
        expect(await io.currentCommand('w5:p8'), 'vibe-rs');
      },
    );

    test(
      'currentCommand falls back to the first process without an agent',
      () async {
        final t = FakeAgentTransport();
        final io = HerdrPaneIO(t, herdrBin: '/usr/local/bin/herdr');
        t.onExec = (command) {
          if (command.startsWith('test -x -- ')) return '';
          if (command.contains('process-info')) {
            return '''
{"id":"cli:pane:process_info","result":{"process_info":{
  "pane_id":"x","shell_pid":1,
  "foreground_processes":[
    {"name":"node","pid":1},
    {"name":"vim","pid":2}
  ]
}}}
''';
          }
          throw StateError('unexpected: $command');
        };
        expect(await io.currentCommand('w5:p8'), 'node');
      },
    );

    test(
      'batched scan also prefers a known agent in the foreground list',
      () async {
        final t = FakeAgentTransport();
        final io = HerdrPaneIO(t, herdrBin: '/usr/local/bin/herdr');
        t.onExec = (command) {
          if (command.startsWith('test -x -- ')) return '';
          if (command.contains('api snapshot')) return _snapshotJson;
          if (command.contains('<<<MUXPOD')) {
            return '\n<<<MUXPOD:w5:p1>>>'
                '${_processInfoJson('zsh')}'
                '\n<<<MUXPOD:w5:p3>>>'
                '{"id":"cli:pane:process_info","result":{"process_info":{'
                '"pane_id":"x","shell_pid":1,"foreground_processes":['
                '{"name":"xdg-open","pid":1},{"name":"vibe-rs","pid":2}]}}}';
          }
          throw StateError('unexpected: $command');
        };
        final panes = await io.listPanes();
        // xdg-open comes first in the list but the agent wins.
        expect(panes[1].command, 'vibe-rs');
        expect(panes[0].command, 'zsh');
      },
    );

    test(
      'currentCommand returns the lowercased first word of the process name',
      () async {
        final t = FakeAgentTransport();
        final io = HerdrPaneIO(t);
        t.onExec = (_) => _processInfoJson('Vibe CLI');
        expect(await io.currentCommand('w5:p3'), 'vibe');
      },
    );

    test(
      'typeLiteral/pressEnter/pressInterrupt use herdr pane commands',
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
      },
    );

    test(
      'paneInfoById uses herdr report without any process-info call',
      () async {
        final t = FakeAgentTransport();
        final io = HerdrPaneIO(t, herdrBin: '/usr/local/bin/herdr');
        t.onExec = (command) {
          if (command.startsWith('test -x -- ')) return '';
          if (command.contains('api snapshot')) return _snapshotJson;
          throw StateError('no probe expected, got: $command');
        };
        final pane = await io.paneInfoById('w5:p4');
        expect(pane, isNotNull);
        expect(pane!.command, 'claude');
        expect(pane.id, 'w5:p4');
        expect(pane.tab, 'srv');
        expect(
          t.execCommands.where((c) => c.contains('process-info')),
          isEmpty,
        );
      },
    );

    test(
      'paneInfoById resolves one unreported pane with a single call',
      () async {
        final t = FakeAgentTransport();
        final io = HerdrPaneIO(t);
        t.onExec = (command) {
          if (command.startsWith('test -x -- ')) return ''; // bin auto-detect
          if (command.contains(r"$SHELL -lc")) {
            return ''; // no result -> fallback
          }
          if (command.contains('api snapshot')) return _snapshotJson;
          if (command.contains('process-info --pane w5:p3')) {
            return _processInfoJson('Vibe CLI');
          }
          throw StateError('must not probe other panes, got: $command');
        };
        final pane = await io.paneInfoById('w5:p3');
        expect(pane, isNotNull);
        expect(pane!.id, 'w5:p3');
        expect(pane.command, 'vibe');
        // snapshot + exactly one process-info for the target pane.
        expect(
          t.execCommands.where((c) => c.contains('process-info')),
          hasLength(1),
        );
        expect(
          t.execCommands.where((c) => c.contains('api snapshot')),
          hasLength(1),
        );
      },
    );

    test('listPanes tolerates a pane that disappears mid-scan', () async {
      final t = FakeAgentTransport();
      final io = HerdrPaneIO(t, herdrBin: '/usr/local/bin/herdr');
      t.onExec = (command) {
        if (command.startsWith('test -x -- ')) return '';
        if (command.contains('api snapshot')) return _snapshotJson;
        if (command.contains('<<<MUXPOD')) {
          // w5:p1 produced no output (pane closed): empty body.
          return '\n<<<MUXPOD:w5:p1>>>'
              '\n<<<MUXPOD:w5:p3>>>'
              '${_processInfoJson('Vibe CLI')}';
        }
        throw StateError('unexpected: $command');
      };
      final panes = await io.listPanes();
      expect(panes, hasLength(4));
      expect(panes[0].command, isNull); // the vanished pane
      expect(panes[1].command, 'vibe');
      expect(panes[2].command, 'claude'); // from herdr's own report
      expect(panes[3].command, 'mistral-vibe'); // from herdr's own report
    });
  });
}
