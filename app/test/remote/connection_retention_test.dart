import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart' show appForegroundProvider;
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_relay.dart';
import 'support/fake_ssh.dart';

class _NoLocal extends LocalConnectionController {
  @override
  Future<HostConnection?> build() async => null;
}

class _Settings extends SettingsController {
  _Settings(this.enabled);
  final bool enabled;

  @override
  AppSettings build() => AppSettings(loaded: true, retainSshConnections: enabled);

  @override
  Future<void> setRetainSshConnections(bool value) async => state = state.copyWith(retainSshConnections: value);
}

class _PartialSecretFailure extends MemorySecretStore {
  _PartialSecretFailure() : super({SshSecrets.passwordKey(sampleSsh.id): 'initial'});

  @override
  Future<void> delete(String key) async => throw StateError('keystore deletion failed');
}

class _SecretReadFailure extends MemorySecretStore {
  _SecretReadFailure()
    : super({
        SshSecrets.privateKeyKey(sampleSsh.id): 'synthetic-key',
        SshSecrets.passphraseKey(sampleSsh.id): 'existing-passphrase',
      });

  bool failPassphraseRead = false;
  int writes = 0;
  int deletes = 0;
  final failure = StateError('keystore read failed');

  @override
  Future<String?> read(String key) async {
    if (failPassphraseRead && key == SshSecrets.passphraseKey(sampleSsh.id)) throw failure;
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    await super.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    deletes++;
    await super.delete(key);
  }
}

class _Download extends DshCarrier {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  String get kind => 'memory';
  @override
  DshTracer? get tracer => null;
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    final stat = {'absolutePath': args['path'], 'version': 'v1', 'bytes': 3};
    if (endpoint == 'workspaceFiles/stat') return RpcOk(stat);
    if (endpoint == 'workspaceFiles/readBytes') {
      entered.complete();
      await release.future;
      return RpcOk({
        ...stat,
        'offset': 0,
        'data': base64Encode([1, 2, 3]),
        'eof': true,
      });
    }
    return const RpcError(DshRemoteException('gateway/not-found', 'unused'));
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnsupportedError('unused');
  @override
  Future<void> close() async {}
}

Future<void> flush(WidgetTester tester) async {
  await tester.pump(Duration.zero);
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump(Duration.zero);
}

void testRetention(String name, Future<void> Function(WidgetTester tester) body) {
  testWidgets(name, (tester) async {
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
    }
  });
}

void main() {
  const relayHost = HostRef.relay('mac');
  final sshHost = HostRef.ssh(sampleSsh.id);
  const anotherSsh = SshHostConfig(
    id: 'ssh-another',
    name: 'Another computer',
    host: '192.168.1.21',
    user: 'me',
    hostKeyType: 'ssh-ed25519',
    hostKeyFingerprint: 'SHA256:goodkeygoodkeygoodkeygoodkeygoodkey00000',
  );
  late FakeRelayBackend relay;
  late FakeSshServer ssh;
  late FakeConnector connector;

  Future<ProviderContainer> create(
    WidgetTester tester, {
    bool enabled = true,
    MemorySecretStore? secrets,
    DshClient? client,
    SshHostConfig sshConfig = sampleSsh,
  }) async {
    SharedPreferences.setMockInitialValues({
      HostsController.prefsKey: jsonEncode([sshConfig.toJson(), anotherSsh.toJson()]),
    });
    relay = FakeRelayBackend(user: sampleRelayUser);
    ssh = FakeSshServer();
    connector = FakeConnector();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secretStoreProvider.overrideWithValue(
            secrets ??
                MemorySecretStore({
                  SshSecrets.passwordKey(sampleSsh.id): 'initial',
                  SshSecrets.passwordKey(anotherSsh.id): 'initial',
                }),
          ),
          localConnectionProvider.overrideWith(_NoLocal.new),
          settingsProvider.overrideWith(() => _Settings(enabled)),
          networkKicksProvider.overrideWithValue(const Stream.empty()),
          relayBackendProvider.overrideWithValue(relay),
          sshLinkFactoryProvider.overrideWithValue(
            (ref, config) => SshHostLink(
              config: config,
              loadSecrets: () => ref.read(hostsProvider.notifier).loadSecrets(config.id),
              transportFactory: ssh.connect,
              connectClient: client == null
                  ? connector.call
                  : ({required baseUri, required token, required hostHeader}) async => client,
              backoff: Backoff(initial: const Duration(milliseconds: 1), maxAttempts: 2),
            ),
          ),
        ],
        child: const SizedBox(),
      ),
    );
    final c = ProviderScope.containerOf(tester.element(find.byType(SizedBox)));
    c.listen(activeConnectionProvider, (_, _) {});
    await c.read(hostsProvider.notifier).ready;
    await c.read(activeHostProvider.notifier).ready;
    await c.read(relayAccountProvider.future);
    return c;
  }

  Future<HostConnection> connect(WidgetTester tester, ProviderContainer c, HostRef host) async {
    c.read(activeHostProvider.notifier).select(host);
    for (var attempt = 0; attempt < 100; attempt++) {
      await flush(tester);
      final value = c.read(activeConnectionProvider);
      expect(value.hasError, isFalse, reason: '${value.error}\n${value.stackTrace}');
      if (value.value?.hostId == host.id) return value.value!;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    fail('Host $host did not connect: ${c.read(activeConnectionProvider)}');
  }

  Future<void> leave(WidgetTester tester, ProviderContainer c) async {
    c.read(activeHostProvider.notifier).select(HostRef.local);
    await flush(tester);
    await flush(tester);
  }

  testRetention('foreground SSH survives a local round trip without connecting another saved host', (tester) async {
    final c = await create(tester);
    final first = await connect(tester, c, sshHost);
    await leave(tester, c);
    expect(ssh.transports.first.isClosed, isFalse);
    final second = await connect(tester, c, sshHost);
    expect(second.client, same(first.client));
    expect(ssh.connects, hasLength(1));
  });

  testRetention('switching through a relay keeps SSH reusable but does not retain the relay', (tester) async {
    final c = await create(tester);
    final first = await connect(tester, c, sshHost);
    final transport = ssh.last;
    final remote = await connect(tester, c, relayHost);
    await leave(tester, c);
    final second = await connect(tester, c, sshHost);
    expect(second.client, same(first.client));
    expect(transport.isClosed, isFalse);
    expect(ssh.connects, hasLength(1));
    expect(relay.closedClients, contains(remote.client));
    expect(relay.connected, ['mac']);
  });

  testRetention('two selected SSH hosts both remain reusable without replacing each other', (tester) async {
    final c = await create(tester);
    final first = await connect(tester, c, sshHost);
    final secondHost = HostRef.ssh(anotherSsh.id);
    final second = await connect(tester, c, secondHost);
    await leave(tester, c);
    expect((await connect(tester, c, sshHost)).client, same(first.client));
    expect((await connect(tester, c, secondHost)).client, same(second.client));
    expect(ssh.connects, hasLength(2));
    expect(ssh.transports.every((transport) => !transport.isClosed), isTrue);
  });

  testRetention('off retains the existing disconnect-on-switch behavior', (tester) async {
    expect(const AppSettings().retainSshConnections, isFalse);
    final c = await create(tester, enabled: false);
    final first = await connect(tester, c, sshHost);
    await leave(tester, c);
    expect(ssh.transports.first.isClosed, isTrue);
    expect((await connect(tester, c, sshHost)).client, isNot(same(first.client)));
    expect(ssh.connects, hasLength(2));
  });

  testRetention('background expiry releases unused hosts only after five minutes', (tester) async {
    final c = await create(tester);
    final first = await connect(tester, c, sshHost);
    await leave(tester, c);
    c.read(appForegroundProvider.notifier).set(false);
    await tester.pump(const Duration(minutes: 4, seconds: 59));
    expect(ssh.transports.first.isClosed, isFalse);
    await tester.pump(const Duration(seconds: 1));
    await flush(tester);
    await flush(tester);
    expect(ssh.transports.first.isClosed, isTrue);
    c.read(appForegroundProvider.notifier).set(true);
    expect((await connect(tester, c, sshHost)).client, isNot(same(first.client)));
  });

  testRetention('returning foreground cancels cleanup and the next background gets a full grace period', (
    tester,
  ) async {
    final c = await create(tester);
    await connect(tester, c, sshHost);
    await leave(tester, c);
    c.read(appForegroundProvider.notifier).set(false);
    await tester.pump(const Duration(minutes: 4));
    c.read(appForegroundProvider.notifier).set(true);
    await tester.pump(const Duration(minutes: 6));
    expect(ssh.transports.first.isClosed, isFalse);
    c.read(appForegroundProvider.notifier).set(false);
    await tester.pump(const Duration(minutes: 4));
    expect(ssh.transports.first.isClosed, isFalse);
    await tester.pump(const Duration(minutes: 1));
    await flush(tester);
    await flush(tester);
    expect(ssh.transports.first.isClosed, isTrue);
  });

  testRetention('background expiry leaves a still-observed connection usable until it is left', (tester) async {
    final c = await create(tester);
    final first = await connect(tester, c, sshHost);
    c.read(appForegroundProvider.notifier).set(false);
    await tester.pump(const Duration(minutes: 5));
    await flush(tester);
    expect(ssh.transports.first.isClosed, isFalse);
    expect(c.read(activeConnectionProvider).value?.client, same(first.client));
    await leave(tester, c);
    expect(ssh.transports.first.isClosed, isTrue);
  });

  testRetention('turning retention off preserves the active host and releases it on switching away', (tester) async {
    final c = await create(tester);
    final first = await connect(tester, c, sshHost);
    await c.read(settingsProvider.notifier).setRetainSshConnections(false);
    await flush(tester);
    expect(ssh.transports.first.isClosed, isFalse);
    expect(c.read(activeConnectionProvider).value?.client, same(first.client));
    await leave(tester, c);
    expect(ssh.transports.first.isClosed, isTrue);
  });

  testRetention('turning retention off immediately releases an inactive host', (tester) async {
    final c = await create(tester);
    await connect(tester, c, sshHost);
    await leave(tester, c);
    await c.read(settingsProvider.notifier).setRetainSshConnections(false);
    await flush(tester);
    await flush(tester);
    expect(ssh.transports.first.isClosed, isTrue);
  });

  for (final fail in [false, true]) {
    testRetention('an in-flight transfer defers cleanup and releases on ${fail ? 'error' : 'success'}', (tester) async {
      final c = await create(tester);
      final first = await connect(tester, c, sshHost);
      final completed = Completer<void>();
      final transfer = first.whileInUse(() => completed.future);
      final result = expectLater(transfer, fail ? throwsStateError : completes);
      await leave(tester, c);
      c.read(appForegroundProvider.notifier).set(false);
      await tester.pump(const Duration(minutes: 5));
      await flush(tester);
      expect(ssh.transports.first.isClosed, isFalse);
      if (fail) {
        completed.completeError(StateError('transfer failed'));
      } else {
        completed.complete();
      }
      await result;
      await flush(tester);
      await flush(tester);
      expect(ssh.transports.first.isClosed, isTrue);
    });
  }

  testRetention('a real artifact download finishes across host switch and background expiry', (tester) async {
    final carrier = _Download();
    final c = await create(tester, client: DshClient.withCarrier(carrier));
    final connection = await connect(tester, c, sshHost);
    final cache = (await tester.runAsync(() => Directory.systemTemp.createTemp('dsh-retention-')))!;
    addTearDown(() => cache.delete(recursive: true));
    final files = ArtifactFiles(connection: connection, channel: const FilesChannel(), cacheRoot: () async => cache);
    File? downloaded;
    Object? failure;
    final download = files.materialize(
      's1',
      const Artifact(path: '/home/me/report.txt', origin: ArtifactOrigin.linked, turn: 1),
    );
    unawaited(
      download.then<void>(
        (file) {
          downloaded = file;
        },
        onError: (Object error) {
          failure = error;
        },
      ),
    );
    for (var i = 0; i < 100 && !carrier.entered.isCompleted && failure == null; i++) {
      await flush(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(failure, isNull);
    expect(carrier.entered.isCompleted, isTrue);
    await leave(tester, c);
    c.read(appForegroundProvider.notifier).set(false);
    await tester.pump(const Duration(minutes: 5));
    await flush(tester);
    expect(ssh.transports.first.isClosed, isFalse);
    carrier.release.complete();
    for (var i = 0; i < 100 && downloaded == null && failure == null; i++) {
      await flush(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(failure, isNull);
    expect(downloaded, isNotNull);
    expect(await tester.runAsync(() => downloaded!.readAsBytes()), [1, 2, 3]);
    await flush(tester);
    expect(ssh.transports.first.isClosed, isTrue);
  });

  testRetention('deleting a retained SSH host closes its transport', (tester) async {
    final c = await create(tester);
    await connect(tester, c, sshHost);
    final transport = ssh.last;
    await leave(tester, c);
    await c.read(hostsProvider.notifier).removeSsh(sampleSsh.id);
    await flush(tester);
    await flush(tester);
    expect(transport.isClosed, isTrue);
  });

  testRetention('changing SSH credentials retires the retained connection', (tester) async {
    final c = await create(tester);
    await connect(tester, c, sshHost);
    final transport = ssh.last;
    await leave(tester, c);
    await c.read(hostsProvider.notifier).saveSsh(sampleSsh, secrets: const SshSecrets(password: 'replacement'));
    await flush(tester);
    await flush(tester);
    expect(transport.isClosed, isTrue);
    expect(ssh.connects, hasLength(1));
    await connect(tester, c, sshHost);
    expect(ssh.connects.last.secrets.password, 'replacement');
  });

  for (final authCase in ['password', 'private key', 'private key without passphrase']) {
    testRetention('metadata edits with unchanged $authCase preserve the live connection', (tester) async {
      final privateKey = authCase != 'password';
      final passphrase = authCase == 'private key' ? 'synthetic-passphrase' : null;
      final config = sampleSsh.copyWith(auth: privateKey ? SshAuthMethod.privateKey : SshAuthMethod.password);
      final secrets = MemorySecretStore({
        if (privateKey) SshSecrets.privateKeyKey(config.id): 'synthetic-key',
        if (!privateKey) SshSecrets.passwordKey(config.id): 'initial',
        SshSecrets.passphraseKey(config.id): ?passphrase,
      });
      final submitted = privateKey
          ? SshSecrets(privateKey: ' \nsynthetic-key\n', passphrase: passphrase ?? '', password: 'unused')
          : const SshSecrets(password: 'initial', privateKey: 'unused', passphrase: 'unused');
      final c = await create(tester, secrets: secrets, sshConfig: config);
      final first = await connect(tester, c, sshHost);
      final renamed = config.copyWith(name: 'Renamed computer');
      await c.read(hostsProvider.notifier).saveSsh(renamed, secrets: submitted);
      await flush(tester);
      expect(ssh.transports.first.isClosed, isFalse);
      expect(c.read(activeConnectionProvider).value?.client, same(first.client));
      expect(c.read(activeConnectionProvider).value?.name, 'Renamed computer');
      await c
          .read(hostsProvider.notifier)
          .saveSsh(renamed.copyWith(workingDirectory: () => '/home/me/project'), secrets: submitted);
      await flush(tester);
      expect(ssh.transports.first.isClosed, isFalse);
      expect(ssh.connects, hasLength(1));
      expect(c.read(activeConnectionProvider).value?.client, same(first.client));
      expect(c.read(activeConnectionProvider).value?.workingDirectory, '/home/me/project');
    });
  }

  for (final invalidate in [false, true]) {
    testRetention('an old connection after ${invalidate ? 'invalidation' : 'disposal'} preserves action results', (
      tester,
    ) async {
      final c = await create(tester, enabled: false);
      final old = await connect(tester, c, sshHost);
      if (invalidate) {
        c.invalidate(remoteConnectionProvider(sshHost));
        await flush(tester);
        expect(await connect(tester, c, sshHost), isNot(same(old)));
      } else {
        await leave(tester, c);
        expect(c.exists(remoteConnectionProvider(sshHost)), isFalse);
        expect(ssh.transports.first.isClosed, isTrue);
      }
      expect(await old.whileInUse(() async => 'completed'), 'completed');
      final failure = StateError('operation failed');
      await expectLater(old.whileInUse<void>(() async => throw failure), throwsA(same(failure)));
      await expectLater(old.whileInUse<void>(() => throw failure), throwsA(same(failure)));
    });
  }

  testRetention('a partially failed credential update also retires the old authenticated transport', (tester) async {
    final secrets = _PartialSecretFailure();
    final c = await create(tester, secrets: secrets);
    await connect(tester, c, sshHost);
    final transport = ssh.last;
    await leave(tester, c);
    await expectLater(
      c.read(hostsProvider.notifier).saveSsh(sampleSsh, secrets: const SshSecrets(password: 'replacement')),
      throwsStateError,
    );
    expect(secrets.values[SshSecrets.passwordKey(sampleSsh.id)], 'replacement');
    await flush(tester);
    await flush(tester);
    expect(transport.isClosed, isTrue);
  });

  testRetention('a credential comparison read failure leaves secrets, saved host and live connection untouched', (
    tester,
  ) async {
    final secrets = _SecretReadFailure();
    final config = sampleSsh.copyWith(auth: SshAuthMethod.privateKey);
    final c = await create(tester, secrets: secrets, sshConfig: config);
    final connection = await connect(tester, c, sshHost);
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(HostsController.prefsKey);
    final values = Map.of(secrets.values);
    secrets.failPassphraseRead = true;
    await expectLater(
      c
          .read(hostsProvider.notifier)
          .saveSsh(
            config.copyWith(name: 'Must not be saved', workingDirectory: () => '/new/path'),
            secrets: const SshSecrets(privateKey: 'synthetic-key', passphrase: ''),
          ),
      throwsA(same(secrets.failure)),
    );
    await flush(tester);
    expect(secrets.writes, 0);
    expect(secrets.deletes, 0);
    expect(secrets.values, values);
    expect(prefs.getString(HostsController.prefsKey), saved);
    expect(c.read(hostsProvider).sshById(config.id), config);
    expect(ssh.transports.first.isClosed, isFalse);
    expect(c.read(activeConnectionProvider).value?.client, same(connection.client));
    expect(ssh.connects, hasLength(1));
  });
}
