/// What a plugin load needs from the pieces of itself that live in Obsidian.
///
/// Narrow on purpose, and JS-free on purpose. [PluginSession] holds these three
/// and tears them down; naming them concretely made the session import
/// `obsidian_dart`, which meant the one property the session exists for — that
/// teardown detaches everything before its first await — could not be run
/// anywhere, because the whole file needs a browser to load.
///
/// Each lists exactly what is called on it from outside the object that built
/// it. Anything else stays on the concrete class, where the caller has it.
library;

import '../settings/plugin_code_overview.dart';
import 'plan_status.dart';

/// The status-bar circle.
abstract interface class SessionIndicator {
  /// Shows that settings sync, not note sync, is what is moving.
  void setSettingsActivity(bool active);

  void dispose();
}

/// The docked side panel.
abstract interface class SessionPanel {
  /// Settings sync has work outstanding, or no longer does.
  void setSettingsActivity(bool active);

  /// Re-renders from current engine state.
  void refresh();

  /// The subscription strip. Quiet is a valid notice, not an absence.
  void setPlanNotice(PlanNotice notice);

  /// Closes every leaf holding this view. Separate from [dispose] because the
  /// order matters at teardown: detach from the workspace, then release.
  void closeLeaves();

  void dispose();
}

/// `.obsidian` settings sync.
abstract interface class SessionConfigSync {
  /// How many settings categories this vault syncs.
  int get enabledCategoryCount;

  /// Whether plugin code (not just plugin settings) is synced.
  bool get pluginCodeEnabled;

  /// Whether settings sync has work in flight or left over.
  bool get hasOutstandingWork;

  /// Re-arms after the engine rebuilt its connection.
  void handleReconnect();

  /// The vault's plugin set joined with this device's disk.
  Future<PluginCodeOverview> pluginOverview();

  /// Drops a plugin from the vault for every device.
  Future<bool> removeFromVault(String resourceId);

  /// Every blob the synced settings still reference, or null before the
  /// settings store has loaded. Null and empty are different answers: the blob
  /// GC must refuse to run on the first, since a live set missing this half
  /// would nominate everything settings sync owns for deletion.
  Set<String>? liveBlobIds();

  Future<void> sync();

  /// Makes this device's `.obsidian` the vault's, discarding what was there.
  Future<void> resetFromThisDevice();

  /// The reverse: takes the vault's over this device's.
  Future<void> restoreFromServer();

  void dispose();
}
