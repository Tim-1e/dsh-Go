import 'dart:async';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/ssh_connection_status.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _StatusLink extends HostLink {
  final changes = StreamController<HostLinkStatus>.broadcast(sync: true);

  @override
  HostLinkStatus status = HostLinkStatus.idle;

  void emit(HostLinkStatus next) {
    status = next;
    changes.add(next);
  }

  @override
  Stream<HostLinkStatus> get statuses => changes.stream;
  @override
  DshClient? get currentClient => null;
  @override
  Stream<DshClient> get clients => const Stream.empty();
  @override
  Future<DshClient> open() => throw UnsupportedError('Status-only test link');
  @override
  void kick() {}
  @override
  void retry() {}
  @override
  Future<void> close() => changes.close();
}

void main() {
  test('a replacement owner ignores old link events and disposal while continuing to publish', () async {
    const host = HostRef.ssh('shared-host');
    final statuses = SshConnectionStatuses();
    final oldLink = _StatusLink();
    final newLink = _StatusLink();
    final c = ProviderContainer(overrides: [sshConnectionStatusesProvider.overrideWithValue(statuses)]);
    addTearDown(() async {
      c.dispose();
      statuses.dispose();
      await oldLink.close();
      await newLink.close();
    });
    final oldOwner = Provider.autoDispose<void>((ref) {
      ref.read(sshConnectionStatusesProvider).observe(ref, host, oldLink);
    });
    final newOwner = Provider.autoDispose<void>((ref) {
      ref.read(sshConnectionStatusesProvider).observe(ref, host, newLink);
    });
    Future<void> settle() async {
      await Future<void>.delayed(Duration.zero);
      await c.pump();
    }

    c.listen(sshConnectionStatusProvider(host), (_, _) {});
    final oldObserver = c.listen(oldOwner, (_, _) {});
    oldLink.emit(const HostLinkStatus(HostLinkPhase.connected));
    c.listen(newOwner, (_, _) {});
    const replacement = HostLinkStatus(HostLinkPhase.connected, detail: 'replacement');
    newLink.emit(replacement);
    await settle();

    void expectReplacement(HostLinkStatus expected) {
      final snapshot = c.read(sshConnectionStatusProvider(host)).requireValue;
      expect(snapshot.status, same(expected));
      expect(snapshot.closed, isFalse);
    }

    expect(oldLink.changes.hasListener, isTrue, reason: 'Old events must reach a still-subscribed observer');
    expectReplacement(replacement);
    oldLink.emit(const HostLinkStatus(HostLinkPhase.failed));
    await settle();
    expectReplacement(replacement);
    oldLink.emit(HostLinkStatus.idle);
    await settle();
    expectReplacement(replacement);

    oldObserver.close();
    await settle();
    expect(oldLink.changes.hasListener, isFalse);
    expectReplacement(replacement);
    const updated = HostLinkStatus(HostLinkPhase.connected, detail: 'replacement still owns updates');
    newLink.emit(updated);
    await settle();
    expectReplacement(updated);
    expect(c.exists(hostsProvider), isFalse);
  });
}
