import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/link_status.dart';
import 'hosts_state.dart';

typedef SshConnectionSnapshot = ({HostLinkStatus status, bool closed});

/// Passive observations: a host row must never own or create a connection.
class SshConnectionStatuses {
  final _snapshots = <HostRef, SshConnectionSnapshot>{};
  final _owners = <HostRef, Object>{};
  final _changes = StreamController<HostRef>.broadcast();

  SshConnectionSnapshot snapshot(HostRef host) => _snapshots[host] ?? (status: HostLinkStatus.idle, closed: false);

  Stream<SshConnectionSnapshot> watch(HostRef host) => Stream.multi((controller) {
    final sub = _changes.stream.where((changed) => changed == host).listen((_) => controller.add(snapshot(host)));
    controller.add(snapshot(host));
    controller.onCancel = sub.cancel;
  });

  void observe(Ref ref, HostRef host, HostLink link) {
    final owner = Object();
    _owners[host] = owner;
    void record(HostLinkStatus status) {
      if (_owners[host] != owner) return;
      final previous = snapshot(host);
      _snapshots[host] = status.phase == HostLinkPhase.idle
          ? (status: previous.status, closed: previous.status.phase != HostLinkPhase.idle)
          : (status: status, closed: false);
      _changes.add(host);
    }

    record(link.status);
    final sub = link.statuses.listen(record);
    ref.onDispose(() {
      record(HostLinkStatus.idle);
      if (_owners[host] == owner) _owners.remove(host);
      unawaited(sub.cancel());
    });
  }

  void retainHosts(HostsState hosts) {
    for (final host in {..._owners.keys, ..._snapshots.keys}) {
      if (hosts.sshById(host.id) != null) continue;
      _owners.remove(host);
      _snapshots.remove(host);
      _changes.add(host);
    }
  }

  void dispose() {
    _owners.clear();
    _snapshots.clear();
    unawaited(_changes.close());
  }
}

final sshConnectionStatusesProvider = Provider((ref) {
  final statuses = SshConnectionStatuses();
  ref.listen(hostsProvider, (_, hosts) => statuses.retainHosts(hosts));
  ref.onDispose(statuses.dispose);
  return statuses;
});

final sshConnectionStatusProvider = StreamProvider.autoDispose.family<SshConnectionSnapshot, HostRef>(
  (ref, host) => ref.watch(sshConnectionStatusesProvider).watch(host),
);
