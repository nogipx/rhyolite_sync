/// Canonical wire encoding for the frontmatter component.
///
/// Canonical is not cosmetic here. `blobRef` is a hash of the bytes, so two
/// devices holding an equal [FmState] MUST produce identical bytes — otherwise
/// they disagree about the blob id, push at each other forever, lose chunk
/// dedup, and the lift-convergence test of §13 becomes unreachable.
///
/// `CborCodec` already gives all three properties the spec asks for: map keys
/// sorted by their UTF-8 bytes, definite lengths, minimum-width integers. Dart
/// map iteration order therefore cannot leak into the output, and no custom
/// encoder is needed.
library;

import 'package:convergent/convergent.dart';
import 'package:convergent/fugue.dart';
import 'package:rpc_dart/rpc_dart.dart';

import 'fm_state.dart';
import 'frontmatter_document.dart';

const _binary = FugueTextBinaryCodec();

/// Bumped only when the SHAPE below changes. A reader that meets a version it
/// does not know refuses the blob rather than guessing, which the blob
/// classifier then reports as a client that needs updating.
const fmCodecVersion = 1;

const _shapeMap = 0;
const _shapeRaw = 1;

const _valueTombstone = 0;
const _valueScalar = 1;
const _valueList = 2;
const _valueOpaque = 3;

/// Thrown when bytes cannot be read as an [FmState] this build understands.
class FmDecodeException implements Exception {
  const FmDecodeException(this.reason);

  final String reason;

  @override
  String toString() => 'FmDecodeException: $reason';
}

/// Encodes [state] as canonical CBOR.
Uint8List encodeFmState(FmState state) {
  // Every Hlc carries a nodeId, which in this engine is the 36-character
  // deviceId. Written out in full that is roughly 150 bytes of metadata per
  // key — a kilobyte of clocks for a header holding a hundred bytes of data,
  // and a list of fifty tags triples in size. So the ids are pooled once and
  // referenced by index. The pool is sorted, which canonical encoding wants
  // anyway.
  final nodes = _NodeTable(_collectNodeIds(state)).._build();
  final payload = <String, dynamic>{
    'v': fmCodecVersion,
    'n': nodes.sorted,
    'h': nodes.pack(state.fmHlc),
  };

  switch (state) {
    case FmRawState(:final tree):
      payload['s'] = _shapeRaw;
      payload['r'] = _binary.encode(tree);
    case FmMapState(:final entries, :final trail, :final trailHlc):
      payload['s'] = _shapeMap;
      payload['t'] = trail;
      payload['th'] = nodes.pack(trailHlc);
      payload['e'] = {
        for (final e in entries.entries) e.key: _packEntry(e.value, nodes),
      };
  }

  return CborCodec.encode(payload);
}

/// Decodes bytes produced by [encodeFmState].
FmState decodeFmState(Uint8List bytes) {
  final Map<String, dynamic> payload;
  try {
    payload = CborCodec.decode(bytes);
  } catch (e) {
    throw FmDecodeException('not CBOR: $e');
  }

  final version = payload['v'];
  if (version != fmCodecVersion) {
    throw FmDecodeException('fm codec version $version is not supported');
  }
  final nodes = (payload['n'] as List?)?.cast<String>();
  if (nodes == null) throw const FmDecodeException('missing node table');

  Hlc unpack(Object? packed) => _unpackHlc(packed, nodes);

  final shape = payload['s'];
  if (shape == _shapeRaw) {
    final raw = payload['r'];
    if (raw is! Uint8List) throw const FmDecodeException('raw tree missing');
    return FmRawState(tree: _binary.decode(raw), fmHlc: unpack(payload['h']));
  }
  if (shape != _shapeMap) {
    throw FmDecodeException('unknown frontmatter shape $shape');
  }

  final rawEntries = (payload['e'] as Map?) ?? const {};
  return FmMapState(
    entries: {
      for (final e in rawEntries.entries)
        e.key as String: _unpackEntry(e.value, nodes),
    },
    fmHlc: unpack(payload['h']),
    trail: (payload['t'] as String?) ?? '',
    trailHlc: unpack(payload['th']),
  );
}

// ── Entries ─────────────────────────────────────────────────────────────────

List<dynamic> _packEntry(FmEntryState e, _NodeTable nodes) {
  final head = <dynamic>[
    nodes.pack(e.hlc),
    e.order,
    nodes.pack(e.orderHlc),
    e.lead,
    nodes.pack(e.leadHlc),
  ];
  final value = e.value;
  if (value == null) return [...head, _valueTombstone];
  switch (value) {
    case FmScalarValue(:final kind, :final text):
      return [...head, _valueScalar, kind.index, text];
    case FmOpaqueValue(:final raw):
      return [...head, _valueOpaque, raw];
    case FmListValue(:final items):
      return [
        ...head,
        _valueList,
        {for (final i in items.entries) i.key: _packItem(i.value, nodes)},
      ];
  }
}

FmEntryState _unpackEntry(Object? packed, List<String> nodes) {
  if (packed is! List || packed.length < 6) {
    throw const FmDecodeException('malformed entry');
  }
  final tag = packed[5];
  final FmValueState? value;
  switch (tag) {
    case _valueTombstone:
      value = null;
    case _valueScalar:
      final kindIndex = packed[6] as int;
      if (kindIndex < 0 || kindIndex >= ScalarKind.values.length) {
        throw FmDecodeException('unknown scalar kind $kindIndex');
      }
      value = FmScalarValue(ScalarKind.values[kindIndex], packed[7] as String);
    case _valueOpaque:
      value = FmOpaqueValue(packed[6] as String);
    case _valueList:
      final raw = (packed[6] as Map?) ?? const {};
      value = FmListValue({
        for (final i in raw.entries)
          i.key as String: _unpackItem(i.value, nodes),
      });
    default:
      throw FmDecodeException('unknown value tag $tag');
  }
  return FmEntryState(
    hlc: _unpackHlc(packed[0], nodes),
    value: value,
    order: packed[1] as String,
    orderHlc: _unpackHlc(packed[2], nodes),
    lead: packed[3] as String,
    leadHlc: _unpackHlc(packed[4], nodes),
  );
}

/// A live item is three fields; a tombstoned one is four. The length carries
/// the distinction, so no null has to be written for the common case.
List<dynamic> _packItem(FmItemState i, _NodeTable nodes) => [
      nodes.pack(i.addHlc),
      i.order,
      nodes.pack(i.orderHlc),
      if (i.delHlc != null) nodes.pack(i.delHlc!),
    ];

FmItemState _unpackItem(Object? packed, List<String> nodes) {
  if (packed is! List || packed.length < 3) {
    throw const FmDecodeException('malformed list item');
  }
  return FmItemState(
    addHlc: _unpackHlc(packed[0], nodes),
    order: packed[1] as String,
    orderHlc: _unpackHlc(packed[2], nodes),
    delHlc: packed.length > 3 ? _unpackHlc(packed[3], nodes) : null,
  );
}

// ── Clocks ──────────────────────────────────────────────────────────────────

/// The node-id pool, built BEFORE anything is packed.
///
/// Assigning indices in encounter order and sorting afterwards does not work:
/// the references already written keep the old numbers. And the order has to
/// be the sorted one, or two devices that met the same ids in a different
/// sequence emit different bytes for an equal state — which is precisely the
/// phantom divergence this file exists to prevent.
class _NodeTable {
  _NodeTable(Set<String> ids)
      : sorted = (ids.toList()..sort()),
        _index = {};

  final List<String> sorted;
  final Map<String, int> _index;

  void _build() {
    for (var i = 0; i < sorted.length; i++) {
      _index[sorted[i]] = i;
    }
  }

  List<dynamic> pack(Hlc h) => [h.millis, h.counter, _index[h.nodeId]!];
}

/// Every node id the state mentions.
Set<String> _collectNodeIds(FmState state) {
  final ids = <String>{state.fmHlc.nodeId};
  switch (state) {
    case FmRawState():
      break;
    case FmMapState(:final entries, :final trailHlc):
      ids.add(trailHlc.nodeId);
      for (final e in entries.values) {
        ids
          ..add(e.hlc.nodeId)
          ..add(e.orderHlc.nodeId)
          ..add(e.leadHlc.nodeId);
        final v = e.value;
        if (v is FmListValue) {
          for (final i in v.items.values) {
            ids..add(i.addHlc.nodeId)..add(i.orderHlc.nodeId);
            final d = i.delHlc;
            if (d != null) ids.add(d.nodeId);
          }
        }
      }
  }
  return ids;
}

Hlc _unpackHlc(Object? packed, List<String> nodes) {
  if (packed is! List || packed.length != 3) {
    throw const FmDecodeException('malformed clock');
  }
  final idx = packed[2] as int;
  if (idx < 0 || idx >= nodes.length) {
    throw FmDecodeException('clock references node $idx, table has ${nodes.length}');
  }
  return Hlc(packed[0] as int, packed[1] as int, nodes[idx]);
}
