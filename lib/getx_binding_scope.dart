import 'dart:async' show unawaited, Completer;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// Internal per-scope recorder used by [BindingScope].
///
/// Responsibilities:
/// - Tracks which registrations (by "key" = `Type::tag`) were created by this
///   scope and therefore must be deleted on dispose.
/// - Tracks in-flight async installs so that dispose can either wait briefly,
///   and/or attach a late-delete hook to clean them up when they finish.
/// - Preserves **registration order** so cleanup can run in **reverse order**,
///   ensuring dependent services can still access their dependencies during
///   their `onClose()` lifecycle.
class _Recorder {
  /// Futures keyed by "Type::tag" for async registrations created by this scope.
  final Map<String, Future<void>> _futures = {};

  /// Uninstaller callbacks keyed by "Type::tag".
  /// Each uninstaller performs `Get.delete<T>(force: true, tag: ...)`.
  final Map<String, Future<void> Function()> _uninstallers = {};

  /// Registration order (Type::tag) in creation sequence.
  /// We tear down in reverse order to preserve dependency access.
  final List<String> _order = [];

  /// Marks a registration "owned" by this scope.
  ///
  /// Called by [DI] when a `put`, `putAsync`, `lazyPut`, or `create` happens
  /// while this scope is the active recorder. Adds a keyed uninstaller and
  /// records the creation order on first sight.
  void ownInstance<T>({String? tag}) {
    final key = DI._key<T>(tag);
    if (!_uninstallers.containsKey(key)) {
      _order.add(key); // record first time we see this key
    }
    _uninstallers[key] = () async {
      await Get.delete<T>(tag: tag, force: true);
      if (kDebugMode) {
        debugPrint('✅ Deleted: ${T.toString()}${tag != null ? ':$tag' : ''}');
      }
    };
  }

  /// Associates an in-flight async install [f] with a specific "Type::tag" key.
  /// Used so dispose can (a) wait a little, (b) hook late cleanup.
  void trackForKey(String key, Future<void> f) {
    _futures[key] = f;
  }

  /// Back-compat no-key tracker (used rarely).
  void track(Future<void> f) => _futures['${DateTime.now().millisecondsSinceEpoch}'] = f;

  /// Waits for all tracked async installs to complete.
  Future<void> whenSettled() async {
    if (_futures.isEmpty) return;
    await Future.wait(_futures.values);
  }

  /// Cleans up everything this scope owns.
  ///
  /// Steps:
  /// 1) Best-effort short wait (300ms) for pending installs to settle.
  /// 2) For any still-running installs, attach a `whenComplete` hook that will
  ///    perform the delete when the install eventually finishes (prevents leaks).
  /// 3) Immediately attempt to delete owned registrations in **reverse order**.
  ///
  /// All delete errors are caught and logged in debug; the app won't crash.
  Future<void> disposeOwned() async {
    try {
      // Best effort wait for immediate completion
      await whenSettled().timeout(const Duration(milliseconds: 300));
    } catch (_) {
      if (kDebugMode) {
        debugPrint('⏱️ disposeOwned: timed out waiting for async regs, continuing teardown');
      }
    }

    // Ensure late-finishing installs get deleted when they finish (prevents leaks)
    _futures.forEach((key, fut) {
      final un = _uninstallers[key];
      if (un != null) {
        fut.whenComplete(() async {
          try {
            await un();
          } catch (e) {
            if (kDebugMode) debugPrint('❌ Late delete failed: $e');
          }
        });
      }
    });

    // IMPORTANT: delete now in REVERSE order (preserves dependency access)
    for (final key in _order.reversed) {
      final un = _uninstallers[key];
      if (un != null) {
        try {
          await un();
        } catch (e) {
          if (kDebugMode) debugPrint('❌ Delete failed: $e');
        }
      }
    }
  }
}

/// A thin facade over GetX's `Get` that enables **ownership tracking**.
///
/// When called inside a [BindingScope], `DI` records what the scope *actually
/// created* so the scope can delete exactly those on dispose. Outside any scope,
/// `DI` just delegates to `Get` without tracking.
///
/// Extra behavior:
/// - `putAsync<T>` implements **first-registrant-wins** semantics. While the
///   first async install is in flight, later callers wait and then borrow the
///   created instance. This prevents races and double-ownership.
/// - Async installs are tracked so scopes can clean up both immediately and
///   **even if the install completes after the scope is disposed**.
class DI {
  /// The currently active per-scope recorder, set by [BindingScope] during init.
  static _Recorder? _active;

  /// Global "in-flight" map keyed by "Type::tag" so that concurrent `putAsync`
  /// calls for the same key coordinate correctly (first wins).
  static final Map<String, Future<void>> _inFlight = {};

  /// Builds a stable key for (Type, tag), e.g. `MyType::myTag`.
  static String _key<T>(String? tag) => '${T.toString()}::${tag ?? ''}';

  /// Polls `Get.find<T>()` until the instance is ready, with a timeout.
  /// Used by borrowers waiting for the first registrant.
  static Future<T> _awaitReady<T>({String? tag, Duration timeout = const Duration(seconds: 3)}) async {
    final sw = Stopwatch()..start();
    while (true) {
      try {
        return Get.find<T>(tag: tag);
      } catch (_) {
        if (sw.elapsed >= timeout) rethrow;
        await Future.delayed(const Duration(milliseconds: 1)); // use real delay, not microtask
      }
    }
  }

  /// Registers (or reuses) an **instance**.
  ///
  /// If already registered, returns the existing one (does not claim ownership).
  /// Otherwise calls `Get.put<T>` and marks this scope as the owner.
  static T put<T>(
    T dependency, {
    String? tag,
    bool permanent = false,
    bool? overrideSmartManagement, // kept for signature parity; unused
  }) {
    if (Get.isRegistered<T>(tag: tag)) {
      return Get.find<T>(tag: tag);
    }
    final res = Get.put<T>(dependency, tag: tag, permanent: permanent);
    _active?.ownInstance<T>(tag: tag);
    return res;
  }

  /// Registers a **lazy factory** if absent, and records scope ownership.
  static void lazyPut<T>(InstanceBuilderCallback<T> builder, {String? tag, bool fenix = false}) {
    if (Get.isRegistered<T>(tag: tag)) return;
    Get.lazyPut<T>(builder, tag: tag, fenix: fenix);
    _active?.ownInstance<T>(tag: tag);
  }

  /// Registers an **async instance** with first-registrant-wins semantics.
  ///
  /// Behavior:
  /// - If a build is already in-flight for this (Type::tag), we **await** it and
  ///   then return the resulting instance (we are a borrower).
  /// - If already registered, we return the existing instance (borrow).
  /// - Otherwise we mark ourselves as the **creator**, register the in-flight
  ///   future in [_inFlight], track it on the current scope, and await it.
  ///
  /// Regardless of who finishes later, only one instance gets registered, and
  /// this scope’s cleanup will delete it iff this scope was the creator.
  static Future<T> putAsync<T>(AsyncInstanceBuilderCallback<T> builder, {String? tag, bool permanent = false}) async {
    final key = _key<T>(tag);

    // If someone is already installing (even if not yet "registered"), wait for them
    final inflight = _inFlight[key];
    if (inflight != null) {
      await inflight; // borrower waits
      return _awaitReady<T>(tag: tag); // borrow from creator
    }

    // If already registered, just borrow immediately
    if (Get.isRegistered<T>(tag: tag)) {
      return _awaitReady<T>(tag: tag);
    }

    // We are the first registrant: create a completer we can track
    final completer = Completer<void>();
    _inFlight[key] = completer.future;

    // Record ownership right now (so dispose() knows we own it)
    _active?.ownInstance<T>(tag: tag);

    try {
      // Start the real install and ensure our scope waits for it on dispose
      final fut = Get.putAsync<T>(builder, tag: tag, permanent: permanent);

      // Track keyed future so dispose can attach a late-delete hook (prevents leaks)
      _active?.trackForKey(key, fut.then((_) {}));

      final res = await fut;
      return res;
    } finally {
      // Release waiters (success or error), then clear the in-flight slot
      if (!completer.isCompleted) completer.complete();
      _inFlight.remove(key);
    }
  }

  /// Registers a **factory** that creates a new instance on each find, and
  /// records scope ownership of the factory registration.
  static void create<T>(InstanceBuilderCallback<T> builder, {String? tag}) {
    if (Get.isRegistered<T>(tag: tag)) return;
    Get.create<T>(builder, tag: tag);
    _active?.ownInstance<T>(tag: tag);
  }

  /// Convenience wrappers.
  static T find<T>({String? tag}) => Get.find<T>(tag: tag);

  static bool isRegistered<T>({String? tag}) => Get.isRegistered<T>(tag: tag);
}

/// A widget that installs a GetX [Bindings] on mount and **cleans up only what
/// it created** on dispose.
///
/// Typical usage:
///
/// ```dart
/// BindingScope(
///   binding: HomeBinding(), // calls DI.* inside
///   child: HomePage(),
/// )
/// ```
///
/// Lifecycle:
/// - `initState`: swaps `DI._active` to a new internal recorder and executes
///   `binding.dependencies()`. Any `DI.put/lazyPut/putAsync/create` inside are
///   recorded as *owned by this scope*. Then it restores the previous recorder
///   (so nested scopes don’t steal each other’s ownership).
/// - `dispose`: asks the recorder to clean up:
///   - waits briefly for in-flight async
///   - attaches late-delete hooks to still-running installs
///   - deletes owned registrations in reverse order
class BindingScope extends StatefulWidget {
  const BindingScope({super.key, required this.binding, required this.child});

  final Bindings binding;
  final Widget child;

  @override
  State<BindingScope> createState() => _BindingScopeState();
}

class _BindingScopeState extends State<BindingScope> {
  late final _Recorder _rec;

  @override
  void initState() {
    super.initState();
    _rec = _Recorder();

    // Activate per-scope recording, run binding, then restore previous.
    final prev = DI._active;
    DI._active = _rec;
    try {
      widget.binding.dependencies();
      if (kDebugMode) {
        debugPrint('🚀 BindingScope: Injected ${widget.binding.runtimeType}');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ BindingScope.dependencies threw: $e\n$st');
      }
      // swallow to avoid crashing the tree
    } finally {
      DI._active = prev;
    }
  }

  @override
  void dispose() {
    if (kDebugMode) {
      debugPrint('🧹 BindingScope: Cleaning up ${widget.binding.runtimeType}');
    }
    // Fire-and-forget; internal awaits keep order & safety.
    unawaited(_rec.disposeOwned()); // make it clear we don't block dispose
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
