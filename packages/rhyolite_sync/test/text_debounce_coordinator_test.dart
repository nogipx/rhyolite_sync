import 'package:fake_async/fake_async.dart';
import 'package:rhyolite_sync/src/sync_v3/text_debounce_coordinator.dart';
import 'package:test/test.dart';

void main() {
  group('TextDebounceCoordinator', () {
    test('fires reconcile once after quiet period when disk event seen', () {
      fakeAsync((async) {
        final reconciled = <String>[];
        final c = TextDebounceCoordinator(
          debounce: const Duration(seconds: 1),
          onReconcile: (path) async => reconciled.add(path),
        );
        c.onDiskEvent('a.md');
        async.elapse(const Duration(milliseconds: 500));
        expect(reconciled, isEmpty);
        async.elapse(const Duration(milliseconds: 600));
        expect(reconciled, ['a.md']);
      });
    });

    test('typing keeps extending the window', () {
      fakeAsync((async) {
        final reconciled = <String>[];
        final c = TextDebounceCoordinator(
          debounce: const Duration(seconds: 1),
          onReconcile: (path) async => reconciled.add(path),
        );
        c.onDiskEvent('a.md');
        for (var i = 0; i < 10; i++) {
          async.elapse(const Duration(milliseconds: 700));
          c.onTypingEvent('a.md');
        }
        expect(reconciled, isEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(reconciled, ['a.md']);
      });
    });

    test('typing without disk event never reconciles', () {
      fakeAsync((async) {
        final reconciled = <String>[];
        final c = TextDebounceCoordinator(
          debounce: const Duration(seconds: 1),
          onReconcile: (path) async => reconciled.add(path),
        );
        c.onTypingEvent('a.md');
        async.elapse(const Duration(seconds: 5));
        expect(reconciled, isEmpty);
        expect(c.pendingCount, 0);
      });
    });

    test('forget cancels pending push', () {
      fakeAsync((async) {
        final reconciled = <String>[];
        final c = TextDebounceCoordinator(
          debounce: const Duration(seconds: 1),
          onReconcile: (path) async => reconciled.add(path),
        );
        c.onDiskEvent('a.md');
        async.elapse(const Duration(milliseconds: 500));
        c.forget('a.md');
        async.elapse(const Duration(seconds: 5));
        expect(reconciled, isEmpty);
      });
    });

    test('paths debounce independently', () {
      fakeAsync((async) {
        final reconciled = <String>[];
        final c = TextDebounceCoordinator(
          debounce: const Duration(seconds: 1),
          onReconcile: (path) async => reconciled.add(path),
        );
        c.onDiskEvent('a.md');
        async.elapse(const Duration(milliseconds: 500));
        c.onDiskEvent('b.md');
        async.elapse(const Duration(milliseconds: 600));
        expect(reconciled, ['a.md']);
        async.elapse(const Duration(milliseconds: 500));
        expect(reconciled, ['a.md', 'b.md']);
      });
    });

    test('cancelAll stops pending timers but keeps coordinator usable', () {
      fakeAsync((async) {
        final reconciled = <String>[];
        final c = TextDebounceCoordinator(
          debounce: const Duration(seconds: 1),
          onReconcile: (path) async => reconciled.add(path),
        );
        c.onDiskEvent('a.md');
        async.elapse(const Duration(milliseconds: 500));
        c.cancelAll();
        async.elapse(const Duration(seconds: 5));
        expect(reconciled, isEmpty);

        c.onDiskEvent('b.md');
        async.elapse(const Duration(seconds: 2));
        expect(reconciled, ['b.md']);
      });
    });
  });
}
