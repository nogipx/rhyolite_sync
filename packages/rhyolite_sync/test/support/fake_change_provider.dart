import 'package:rhyolite_sync/rhyolite_sync.dart';

/// No-op [IChangeProvider]. Records suppressed paths so a test can assert the
/// applier suppressed the watcher echo before writing.
class NoopChangeProvider implements IChangeProvider {
  final List<String> suppressed = [];

  @override
  Stream<FileChangeEvent> get changes => const Stream.empty();

  @override
  Stream<String> get typing => const Stream.empty();

  @override
  void suppress(
    String path, {
    int count = 1,
    Duration holdFor = const Duration(seconds: 2),
  }) {
    suppressed.add(path);
  }

  @override
  void unsuppress(String path) {}
}
