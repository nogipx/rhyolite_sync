import 'dart:typed_data';

/// Chunks a pull has fetched and not yet applied, held in memory.
///
/// The pull used to stage them in SQLite: prefetch wrote every chunk of a
/// batch into the local blob cache, the apply read them straight back, and the
/// file went to disk. On a vault averaging a megabyte a file that is a
/// gigabyte written to the database purely in transit, and on a host whose
/// SQLite sits on an IndexedDB VFS it is worse than slow — the VFS performs
/// writes from a queue on the same event loop, the queue never emptied, and
/// nothing the pull banked ever reached durable storage. Every session
/// restarted from where the one before it had, which was nowhere.
///
/// So the transit copy stops being a write. What is genuinely worth keeping —
/// the file on disk, and the row that says which version it holds — is
/// unaffected, and stops competing with a gigabyte of bytes nobody will read
/// twice.
///
/// Not a cache: it holds exactly one batch and is cleared when that batch has
/// been applied. Anything wanted after that is fetched again, which is what
/// the round-trip batching in `ChunkedBlobIO.prefetchAll` is for.
class BlobStaging {
  BlobStaging({this.budgetBytes = 24 * 1024 * 1024});

  /// The ceiling this area will not knowingly exceed.
  ///
  /// Enforced HERE rather than by the caller sizing its batch, because here is
  /// the first place the real sizes are known: a record carries a chunk list,
  /// not a size, so a batch can only be estimated in advance — and estimating
  /// a note's single chunk at the chunker's four-megabyte maximum made batches
  /// six files long and the pull five times slower for no memory saved.
  final int budgetBytes;

  /// Whether staging more would exceed the budget.
  ///
  /// A full area is not an error: the prefetch simply stops warming, and the
  /// apply fetches what it is missing per file. Slower for those files, and
  /// bounded, which is the trade this exists to make.
  bool get isFull => _bytes >= budgetBytes;

  final Map<String, Uint8List> _chunks = {};
  int _bytes = 0;

  /// Bytes currently held. The pull sizes its batches so this stays bounded;
  /// see `StatePuller`'s batch budget.
  int get bytes => _bytes;

  int get count => _chunks.length;

  Uint8List? read(String hash) => _chunks[hash];

  bool contains(String hash) => _chunks.containsKey(hash);

  void write(String hash, Uint8List bytes) {
    final existing = _chunks[hash];
    if (existing != null) _bytes -= existing.length;
    _chunks[hash] = bytes;
    _bytes += bytes.length;
  }

  /// Drops everything. Called once a batch is applied — holding it any longer
  /// is the memory cost of a copy nothing will read.
  void clear() {
    _chunks.clear();
    _bytes = 0;
  }
}
