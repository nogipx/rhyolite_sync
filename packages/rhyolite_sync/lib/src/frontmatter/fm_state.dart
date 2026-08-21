/// The frontmatter CRDT: a state that joins, and the two functions that
/// connect it to the disk — [materializeFm] out, [applyDiskFrontmatter] in.
///
/// The document types in `frontmatter_document.dart` say what a region MEANS;
/// these say who wrote it and when. Keeping them apart is what lets ingest
/// compare "what the file says now" with "what the state says" as an equality
/// between two values of one type (§8.6), instead of a hand-written walk.
library;

import 'package:convergent/convergent.dart';
import 'package:convergent/fugue.dart';

import 'frac_index.dart';
import 'frontmatter_document.dart';

/// One element of a list value. Identity is the item's own text, which is the
/// property that closes the original bug: two devices adding `work` to `tags`
/// add the SAME element, not two.
class FmItemState {
  const FmItemState({
    required this.addHlc,
    required this.order,
    required this.orderHlc,
    this.delHlc,
  });

  final Hlc addHlc;
  final Hlc? delHlc;
  final String order;
  final Hlc orderHlc;

  /// Add-wins on a tie: a concurrent add and delete of the same item keeps it
  /// only when the add is strictly newer.
  bool get isLive => delHlc == null || addHlc.compareTo(delHlc!) > 0;

  FmItemState join(FmItemState other) {
    final add = addHlc.compareTo(other.addHlc) >= 0 ? addHlc : other.addHlc;
    final Hlc? del;
    if (delHlc == null) {
      del = other.delHlc;
    } else if (other.delHlc == null) {
      del = delHlc;
    } else {
      del = delHlc!.compareTo(other.delHlc!) >= 0 ? delHlc : other.delHlc;
    }
    final orderWins = orderHlc.compareTo(other.orderHlc) >= 0;
    return FmItemState(
      addHlc: add,
      delHlc: del,
      order: orderWins ? order : other.order,
      orderHlc: orderWins ? orderHlc : other.orderHlc,
    );
  }
}

/// A value, as the CRDT holds it.
sealed class FmValueState {
  const FmValueState();

  /// Discriminator used by the entry join: a change of kind is resolved
  /// whole-value by clock rather than merged field by field.
  String get kindTag;
}

class FmScalarValue extends FmValueState {
  const FmScalarValue(this.kind, this.text);

  final ScalarKind kind;
  final String text;

  @override
  String get kindTag => 'scalar';
}

class FmListValue extends FmValueState {
  const FmListValue(this.items);

  /// Item text -> item. A map, not a list: order lives in each item's own
  /// fractional index so two concurrent inserts cannot fight over a slot.
  final Map<String, FmItemState> items;

  @override
  String get kindTag => 'list';
}

class FmOpaqueValue extends FmValueState {
  const FmOpaqueValue(this.raw);

  final String raw;

  @override
  String get kindTag => 'opaque';
}

/// One key.
class FmEntryState {
  const FmEntryState({
    required this.hlc,
    required this.value,
    required this.order,
    required this.orderHlc,
    this.lead = '',
    required this.leadHlc,
  });

  /// Bumped by any mutation of [value]. Null [value] is a tombstone.
  final Hlc hlc;
  final FmValueState? value;

  final String order;
  final Hlc orderHlc;
  final String lead;
  final Hlc leadHlc;

  bool get isLive => value != null;

  FmEntryState copyWith({
    Hlc? hlc,
    FmValueState? value,
    bool clearValue = false,
    String? order,
    Hlc? orderHlc,
    String? lead,
    Hlc? leadHlc,
  }) =>
      FmEntryState(
        hlc: hlc ?? this.hlc,
        value: clearValue ? null : (value ?? this.value),
        order: order ?? this.order,
        orderHlc: orderHlc ?? this.orderHlc,
        lead: lead ?? this.lead,
        leadHlc: leadHlc ?? this.leadHlc,
      );

  /// §4, join of two entries for one key.
  FmEntryState join(FmEntryState other) {
    // Position and lead merge on their OWN clocks, always, and independently
    // of the value — including for a tombstone. That is what brings a deleted
    // and re-added key back to its old place with its comment, and it is the
    // reason the join stays associative: a value decision never drags position
    // along with it.
    final orderWins = orderHlc.compareTo(other.orderHlc) >= 0;
    final leadWins = leadHlc.compareTo(other.leadHlc) >= 0;
    final mergedOrder = orderWins ? order : other.order;
    final mergedOrderHlc = orderWins ? orderHlc : other.orderHlc;
    final mergedLead = leadWins ? lead : other.lead;
    final mergedLeadHlc = leadWins ? leadHlc : other.leadHlc;

    FmEntryState wholeValueWinner() {
      final mine = hlc.compareTo(other.hlc) >= 0;
      final winner = mine ? this : other;
      return FmEntryState(
        hlc: winner.hlc,
        value: winner.value,
        order: mergedOrder,
        orderHlc: mergedOrderHlc,
        lead: mergedLead,
        leadHlc: mergedLeadHlc,
      );
    }

    final a = value;
    final b = other.value;
    // A tombstone on either side, or two different kinds of value: there is
    // nothing to merge field-wise, so the newer clock takes the value whole.
    if (a == null || b == null || a.kindTag != b.kindTag) {
      return wholeValueWinner();
    }

    if (a is FmListValue && b is FmListValue) {
      final items = <String, FmItemState>{...a.items};
      b.items.forEach((text, item) {
        final mine = items[text];
        items[text] = mine == null ? item : mine.join(item);
      });
      return FmEntryState(
        // max of both: the entry's clock has to dominate every contribution,
        // or a later whole-value write could lose to a merged list.
        hlc: hlc.compareTo(other.hlc) >= 0 ? hlc : other.hlc,
        value: FmListValue(items),
        order: mergedOrder,
        orderHlc: mergedOrderHlc,
        lead: mergedLead,
        leadHlc: mergedLeadHlc,
      );
    }

    // Two scalars, or two opaques: last writer wins. Named as a loss in §15,
    // not hidden.
    return wholeValueWinner();
  }
}

/// The frontmatter component of a document.
sealed class FmState {
  const FmState(this.fmHlc);

  /// When the SHAPE last changed. Only ever compared against another shape.
  final Hlc fmHlc;
}

/// A region that is a flat mapping.
class FmMapState extends FmState {
  const FmMapState({
    required this.entries,
    required Hlc fmHlc,
    this.trail = '',
    required this.trailHlc,
  }) : super(fmHlc);

  final Map<String, FmEntryState> entries;
  final String trail;
  final Hlc trailHlc;
}

/// A region that is not a mapping, held as its own small Fugue tree so it
/// keeps character-wise merging rather than degrading to last-writer-wins.
class FmRawState extends FmState {
  const FmRawState({required this.tree, required Hlc fmHlc}) : super(fmHlc);

  final Fugue<String> tree;
}

/// Drops tombstoned keys and deleted list items.
///
/// ONLY safe once every active device has pulled past the record carrying
/// those deletions — the caller establishes that, this function does not check
/// it. Called too early, a peer that never saw a delete re-adds the key on the
/// next join, which is a resurrection and looks to the user like a property
/// coming back from the dead.
///
/// Returns the same instance when there is nothing to drop, so a caller can
/// use identity to tell whether anything changed.
///
/// Never a REASON to write. The state lives inside the blob, so rewriting it
/// changes `blobRef` and pushes; a scheduled sweep over every file would be
/// the mass re-upload this design exists to avoid. Prune when the file is
/// being written anyway, and not otherwise.
FmState pruneFmTombstones(FmState state) {
  if (state is! FmMapState) return state;

  var changed = false;
  final entries = <String, FmEntryState>{};
  for (final e in state.entries.entries) {
    final entry = e.value;
    if (!entry.isLive) {
      changed = true;
      continue;
    }
    final value = entry.value;
    if (value is FmListValue) {
      final live = <String, FmItemState>{
        for (final i in value.items.entries)
          if (i.value.isLive) i.key: i.value,
      };
      if (live.length != value.items.length) {
        changed = true;
        entries[e.key] = entry.copyWith(value: FmListValue(live));
        continue;
      }
    }
    entries[e.key] = entry;
  }
  if (!changed) return state;
  return FmMapState(
    entries: entries,
    fmHlc: state.fmHlc,
    trail: state.trail,
    trailHlc: state.trailHlc,
  );
}

/// Whether this state is worth carrying at all.
///
/// A note that has never had a property produces an empty map, and writing
/// that costs ~80 bytes on every note in the vault to say "nothing here".
///
/// Tombstones COUNT as worth carrying, which is the whole subtlety: a note
/// whose properties were all deleted has no live entries but must still ship
/// its state, or a peer that never saw the delete simply adds them back.
bool fmStateIsWorthStoring(FmState state) => switch (state) {
      FmRawState() => true,
      FmMapState(:final entries, :final trail) =>
        entries.isNotEmpty || trail.isNotEmpty,
    };

/// §4, join of two frontmatter components.
FmState joinFm(FmState a, FmState b) {
  if (a is FmMapState && b is FmMapState) {
    final entries = <String, FmEntryState>{...a.entries};
    b.entries.forEach((key, entry) {
      final mine = entries[key];
      entries[key] = mine == null ? entry : mine.join(entry);
    });
    final trailWins = a.trailHlc.compareTo(b.trailHlc) >= 0;
    return FmMapState(
      entries: entries,
      fmHlc: a.fmHlc.compareTo(b.fmHlc) >= 0 ? a.fmHlc : b.fmHlc,
      trail: trailWins ? a.trail : b.trail,
      trailHlc: trailWins ? a.trailHlc : b.trailHlc,
    );
  }

  if (a is FmRawState && b is FmRawState) {
    final merged = Fugue<String>()
      ..merge(a.tree)
      ..merge(b.tree);
    return FmRawState(
      tree: merged,
      fmHlc: a.fmHlc.compareTo(b.fmHlc) >= 0 ? a.fmHlc : b.fmHlc,
    );
  }

  // Shapes disagree. One side sees a mapping where the other sees prose, and
  // there is no meaningful blend of the two — the newer shape takes it whole.
  return a.fmHlc.compareTo(b.fmHlc) >= 0 ? a : b;
}

/// Renders the state as the document it currently means.
///
/// Keys come out in `(order, key)` and list items in `(order, text)`; the
/// text tiebreak is what makes two concurrent inserts at the same position
/// land the same way everywhere.
FmDocument materializeFm(FmState state) {
  switch (state) {
    case FmRawState(:final tree):
      return FmRaw(tree.values.join());
    case FmMapState(:final entries, :final trail):
      final live = entries.entries.where((e) => e.value.isLive).toList()
        ..sort((x, y) {
          final byOrder = x.value.order.compareTo(y.value.order);
          return byOrder != 0 ? byOrder : x.key.compareTo(y.key);
        });
      return FmMap(
        [
          for (final e in live)
            FmEntry(
              key: e.key,
              value: _materializeValue(e.value.value!),
              lead: e.value.lead,
            ),
        ],
        trail: trail,
      );
  }
}

FmValue _materializeValue(FmValueState v) {
  switch (v) {
    case FmScalarValue(:final kind, :final text):
      return FmScalar(kind, text);
    case FmOpaqueValue(:final raw):
      return FmOpaque(raw);
    case FmListValue(:final items):
      final live = items.entries.where((e) => e.value.isLive).toList()
        ..sort((x, y) {
          final byOrder = x.value.order.compareTo(y.value.order);
          return byOrder != 0 ? byOrder : x.key.compareTo(y.key);
        });
      return FmList([for (final e in live) e.key]);
  }
}

/// Folds what the file says NOW into the state, stamping only what changed
/// with [now].
///
/// Diffing against the materialised state rather than a separate "last known
/// document" store is not an optimisation: that store is lost by a local wipe,
/// and after the loss every key would be re-added with a fresh clock, undoing
/// deletions that had already propagated.
FmState applyDiskFrontmatter(FmState state, FmDocument disk, Hlc now) {
  if (disk is FmRaw) {
    if (state is FmRawState) {
      final current = state.tree.values.join();
      if (current == disk.text) return state;
      // Character-level merge belongs to the caller that owns the tree; from
      // here the new text simply replaces it, and the shape clock does not
      // move because the shape did not change.
      return FmRawState(tree: seedFugueText(disk.text), fmHlc: state.fmHlc);
    }
    return FmRawState(tree: seedFugueText(disk.text), fmHlc: now);
  }

  final map = disk as FmMap;
  final wasMap = state is FmMapState;
  final old = wasMap ? state.entries : const <String, FmEntryState>{};
  final next = <String, FmEntryState>{};

  // Orders are assigned by position in the file. Reusing an existing key's
  // order keeps untouched keys from re-hashing the blob.
  String? previousOrder;
  for (var i = 0; i < map.entries.length; i++) {
    final e = map.entries[i];
    final prior = old[e.key];
    final order = prior != null && isValidFracIndex(prior.order)
        ? prior.order
        : fracIndexBetween(previousOrder, null);
    previousOrder = order;

    if (prior == null) {
      next[e.key] = FmEntryState(
        hlc: now,
        value: _stateValue(e.value, null, now),
        order: order,
        orderHlc: now,
        lead: e.lead,
        leadHlc: now,
      );
      continue;
    }

    final priorDoc = prior.isLive ? _materializeValue(prior.value!) : null;
    final valueChanged = priorDoc != e.value;
    next[e.key] = prior.copyWith(
      hlc: valueChanged || !prior.isLive ? now : prior.hlc,
      value: valueChanged || !prior.isLive
          ? _stateValue(e.value, prior.value, now)
          : prior.value,
      order: order,
      orderHlc: order != prior.order ? now : prior.orderHlc,
      lead: e.lead,
      leadHlc: e.lead != prior.lead ? now : prior.leadHlc,
    );
  }

  // A key that vanished from the file is a deletion, and a tombstone is what
  // makes it propagate. Its position and comment are kept so a re-add returns
  // to the same place.
  for (final entry in old.entries) {
    if (next.containsKey(entry.key)) continue;
    next[entry.key] = entry.value.isLive
        ? entry.value.copyWith(hlc: now, clearValue: true)
        : entry.value;
  }

  final trailChanged = !wasMap || state.trail != map.trail;
  return FmMapState(
    entries: next,
    fmHlc: wasMap ? state.fmHlc : now,
    trail: map.trail,
    trailHlc: trailChanged ? now : state.trailHlc,
  );
}

/// Builds the stored form of a value, reusing item metadata where the item is
/// unchanged so an untouched list does not re-clock every element.
FmValueState _stateValue(FmValue value, FmValueState? prior, Hlc now) {
  switch (value) {
    case FmScalar(:final kind, :final text):
      return FmScalarValue(kind, text);
    case FmOpaque(:final raw):
      return FmOpaqueValue(raw);
    case FmList(:final items):
      final priorItems =
          prior is FmListValue ? prior.items : const <String, FmItemState>{};
      final next = <String, FmItemState>{};
      String? previousOrder;
      for (final text in items) {
        final was = priorItems[text];
        final order = was != null && isValidFracIndex(was.order)
            ? was.order
            : fracIndexBetween(previousOrder, null);
        previousOrder = order;
        next[text] = FmItemState(
          // Re-adding a removed item has to beat its own tombstone.
          addHlc: was != null && was.isLive ? was.addHlc : now,
          delHlc: was != null && was.isLive ? was.delHlc : null,
          order: order,
          orderHlc: was != null && was.order == order ? was.orderHlc : now,
        );
      }
      // Items gone from the file get a tombstone rather than disappearing,
      // or a peer that still has them would simply add them back.
      priorItems.forEach((text, item) {
        if (next.containsKey(text)) return;
        next[text] = item.isLive
            ? FmItemState(
                addHlc: item.addHlc,
                delHlc: now,
                order: item.order,
                orderHlc: item.orderHlc,
              )
            : item;
      });
      return FmListValue(next);
  }
}

/// Lifts a region that arrived WITHOUT a state into one, stamping every part
/// of it with [at].
///
/// The case this exists for: a concurrent side whose blob carries no `\0fm1`
/// tail. Its frontmatter is not missing — it is sitting in that side's TEXT —
/// so the only thing absent is the typed view of it. Reading that view back
/// out is what lets the merge treat every side alike, instead of falling back
/// to a character join for the whole region because one side was quiet.
///
/// [at] MUST be the clock of the version the region came from — its
/// `FileState.hlc` — not the local clock. The stamp decides who wins a
/// per-key last-writer contest, so using "now" would let the side that merely
/// happens to lack a tail beat every side that has one.
///
/// DETERMINISTIC, and it has to be: two devices lifting the same blob must
/// produce equal states, or they disagree about the merged bytes and push at
/// each other forever. Orders come from [fracIndexForPosition] — position, not
/// a chained midpoint — so the result depends on nothing but (region, [at]).
FmState liftFm(FmDocument doc, Hlc at) {
  switch (doc) {
    case FmRaw(:final text):
      return FmRawState(tree: seedFugueText(text), fmHlc: at);
    case FmMap(:final entries, :final trail):
      return FmMapState(
        entries: {
          for (var i = 0; i < entries.length; i++)
            entries[i].key: FmEntryState(
              hlc: at,
              value: _liftValue(entries[i].value, at),
              order: fracIndexForPosition(i, entries.length),
              orderHlc: at,
              lead: entries[i].lead,
              leadHlc: at,
            ),
        },
        fmHlc: at,
        trail: trail,
        trailHlc: at,
      );
  }
}

FmValueState _liftValue(FmValue value, Hlc at) {
  switch (value) {
    case FmScalar(:final kind, :final text):
      return FmScalarValue(kind, text);
    case FmOpaque(:final raw):
      return FmOpaqueValue(raw);
    case FmList(:final items):
      return FmListValue({
        for (var i = 0; i < items.length; i++)
          items[i]: FmItemState(
            addHlc: at,
            order: fracIndexForPosition(i, items.length),
            orderHlc: at,
          ),
      });
  }
}

/// Deterministic seed of a Fugue tree from text — same bytes, same tree, on
/// any device.
Fugue<String> seedFugueText(String text) {
  final tree = Fugue<String>();
  if (text.isEmpty) return tree;
  final clk = LamportClock('fm-seed');
  tree.applyOps(
    [for (var i = 0; i < text.length; i++) FugueOp.insert(i, text[i])],
    clk,
  );
  return tree;
}
