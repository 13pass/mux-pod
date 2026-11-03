import 'package:flutter_muxpod/services/agent/agent_adapter.dart';
import 'package:flutter_muxpod/services/agent/agent_types.dart';
import 'package:flutter_muxpod/services/agent/vibe_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_agent_transport.dart';

void main() {
  group('VibeAdapter pure mappings', () {
    test('agentForPermission maps to vibe builtin agents', () {
      expect(VibeAdapter.agentForPermission(UnifiedPermission.readOnly), 'ask');
      expect(
        VibeAdapter.agentForPermission(UnifiedPermission.defaultPermissions),
        'accept-edits',
      );
      expect(
        VibeAdapter.agentForPermission(UnifiedPermission.autoReview),
        'smart-approve',
      );
      expect(
        VibeAdapter.agentForPermission(UnifiedPermission.fullAccess),
        'auto-approve',
      );
      expect(VibeAdapter.agentForPermission(UnifiedPermission.custom), isNull);
    });

    test('permissionForAgent maps persisted default_agent back', () {
      expect(VibeAdapter.permissionForAgent('ask'), UnifiedPermission.readOnly);
      expect(
        VibeAdapter.permissionForAgent('accept-edits'),
        UnifiedPermission.defaultPermissions,
      );
      expect(
        VibeAdapter.permissionForAgent('smart-approve'),
        UnifiedPermission.autoReview,
      );
      expect(
        VibeAdapter.permissionForAgent('auto-approve'),
        UnifiedPermission.fullAccess,
      );
      // Custom agents and unknown values have no unified equivalent.
      expect(VibeAdapter.permissionForAgent('review'), isNull);
    });

    test('capabilities expose permissions but no intelligence levels', () {
      final caps = VibeAdapter().capabilities;
      expect(caps.permissionLevels, isNotEmpty);
      expect(caps.intelligenceLevels, isEmpty);
      expect(caps.supportsPlanMode, isFalse);
      expect(caps.requiresRestartToApply, isFalse);
    });
  });

  group('VibeAdapter remote operations', () {
    FakeAgentTransport transport({Map<String, String>? files}) =>
        FakeAgentTransport(files: files);

    AgentContext contextFor(FakeAgentTransport ssh) => AgentContext(
      ssh: ssh,
      paneIO: ssh.paneIO,
      paneId: '%7',
      paneWorkingDirectory: '/home/vincent/agents/vibe',
    );

    test(
      'readConfig parses active_model and default_agent from config.toml',
      () async {
        final ssh = transport(
          files: {
            r'$HOME/.vibe/config.toml':
                'active_model = "mistral-large-4-0-3"\ndefault_agent = "smart-approve"\n',
          },
        );
        final config = await VibeAdapter().readConfig(contextFor(ssh));
        expect(config.model, 'mistral-large-4-0-3');
        expect(config.permission, UnifiedPermission.autoReview);
      },
    );

    test(
      'readConfig returns an empty config when the file is missing',
      () async {
        final config = await VibeAdapter().readConfig(contextFor(transport()));
        expect(config.model, isNull);
        expect(config.permission, isNull);
      },
    );

    test(
      'applyModel persists active_model and types /model into the pane',
      () async {
        final ssh = transport(
          files: {r'$HOME/.vibe/config.toml': 'default_agent = "ask"\n'},
        );
        final message = await VibeAdapter().applyModel(
          contextFor(ssh),
          'mistral-small',
        );
        expect(
          ssh.files[r'$HOME/.vibe/config.toml'],
          contains('active_model = "mistral-small"'),
        );
        // Original content preserved.
        expect(
          ssh.files[r'$HOME/.vibe/config.toml'],
          contains('default_agent = "ask"'),
        );
        expect(message, contains('mistral-small'));
        expect(ssh.paneIO.calls, [
          'typeLiteral %7 /model mistral-small',
          'enter %7',
        ]);
      },
    );

    test('applyPermission writes default_agent', () async {
      final ssh = transport();
      final message = await VibeAdapter().applyPermission(
        contextFor(ssh),
        UnifiedPermission.fullAccess,
      );
      expect(
        ssh.files[r'$HOME/.vibe/config.toml'],
        contains('default_agent = "auto-approve"'),
      );
      expect(message, contains('auto-approve'));
    });

    test('applyPermission custom leaves the config file untouched', () async {
      final ssh = transport(
        files: {r'$HOME/.vibe/config.toml': 'default_agent = "review"\n'},
      );
      final message = await VibeAdapter().applyPermission(
        contextFor(ssh),
        UnifiedPermission.custom,
      );
      expect(
        ssh.files[r'$HOME/.vibe/config.toml'],
        contains('default_agent = "review"'),
      );
      expect(message, contains('left untouched'));
    });

    test(
      'sendMessage types the chat text literally into the pane and submits',
      () async {
        final ssh = transport();
        final message = await VibeAdapter().sendMessage(
          contextFor(ssh),
          'hello harness',
        );
        expect(ssh.paneIO.calls, ['typeLiteral %7 hello harness', 'enter %7']);
        expect(message, contains('Vibe'));
      },
    );
  });
}
