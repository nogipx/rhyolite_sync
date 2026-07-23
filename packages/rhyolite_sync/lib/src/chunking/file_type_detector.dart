/// Determines whether a file should use chunked storage based on its extension.
///
/// Text files (markdown, json, etc.) use single-blob storage for 3-way merge.
/// Binary files (images, PDFs, etc.) use content-defined chunking.
class FileTypeDetector {
  const FileTypeDetector({this.extraBinaryExtensions = const <String>{}});

  /// User-configured extensions (lowercase, WITHOUT the leading dot, e.g.
  /// `excalidraw`) forced onto the binary LWW + conflict-copy path, ON TOP OF
  /// the built-in [_textExtensions] / [_forceBinarySuffixes] rules. This list
  /// is vault-global and synced across devices (via the encrypted vault-meta
  /// slot), so every device classifies a given file identically — a per-device
  /// mismatch would route the same file through different conflict resolvers
  /// (Fugue-join vs LWW) and fail to converge. The set only ADDS force-binary
  /// entries; it can never move a file back onto the text path.
  final Set<String> extraBinaryExtensions;

  static const _textExtensions = <String>{
    '.md',
    '.txt',
    '.json',
    // NOTE: `.canvas` (Obsidian canvas) is deliberately NOT here — it is a
    // structured JSON document where a character-level Fugue merge of two
    // concurrent boards yields invalid JSON. It takes the binary LWW +
    // conflict-copy path instead, same rationale as [_forceBinarySuffixes].
    '.csv',
    '.tsv',
    '.xml',
    '.html',
    '.htm',
    '.css',
    '.js',
    '.ts',
    '.yaml',
    '.yml',
    '.toml',
    '.ini',
    '.cfg',
    '.conf',
    '.log',
    '.sh',
    '.bash',
    '.zsh',
    '.py',
    '.rb',
    '.rs',
    '.go',
    '.java',
    '.kt',
    '.swift',
    '.dart',
    '.c',
    '.h',
    '.cpp',
    '.hpp',
    '.tex',
    '.bib',
    '.org',
    '.rst',
    '.adoc',
    '.svg',
    // Screenwriting / authoring formats — plain-text under the hood,
    // edited in Obsidian like notes. Without these the binary path
    // applies LWW and races with live disk edits.
    '.fountain',
    '.fdx',
    '.lua',
    '.r',
    '.scala',
    '.php',
    '.pl',
    '.markdown',
    '.mdx',
    '.qmd',
    '.tsx',
    '.jsx',
    '.vue',
    '.sql',
    '.gql',
    '.graphql',
    '.proto',
    '.lock',
    '.gitignore',
    '.env',
    '.makefile',
    '.dockerfile',
  };

  /// Compound suffixes that FORCE the binary (LWW + conflict-copy) path even
  /// though their final extension would otherwise classify as text.
  ///
  /// `.excalidraw.md` is the Obsidian Excalidraw plugin's default format: a
  /// Markdown wrapper around a structured (often base64+deflate compressed)
  /// Excalidraw JSON. The last-dot rule would route it through Fugue as `.md`,
  /// but a character-level CRDT merge of two concurrent drawings interleaves
  /// their bytes and yields invalid JSON — an unopenable drawing. LWW +
  /// conflict-copy keeps both versions intact instead, which is what a drawing
  /// needs. This is a WIRE-FORMAT decision and must stay identical across all
  /// devices and releases.
  static const _forceBinarySuffixes = <String>{
    '.excalidraw.md',
  };

  bool shouldChunk(String path) {
    if (_isForcedBinary(path)) return true;
    final ext = _extension(path);
    if (ext.isEmpty) return false;
    if (extraBinaryExtensions.contains(ext.substring(1))) return true;
    return !_textExtensions.contains(ext);
  }

  /// Whether [path] should be synced through the text CRDT (Fugue)
  /// path instead of the state-based binary blob path.
  ///
  /// Files with no extension default to text — Makefiles, LICENSE,
  /// `.gitignore` etc. are virtually always text and Fugue overhead
  /// on a misclassified small binary is negligible. Known text
  /// extensions go through Fugue; everything else stays binary.
  bool isText(String path) {
    if (_isForcedBinary(path)) return false;
    final ext = _extension(path);
    if (ext.isEmpty) return true;
    // A user-forced binary extension (synced policy) wins over the built-in
    // text list, so e.g. adding `json` routes every .json through LWW.
    if (extraBinaryExtensions.contains(ext.substring(1))) return false;
    return _textExtensions.contains(ext);
  }

  /// Whether [path]'s filename ends with a [_forceBinarySuffixes] entry
  /// (case-insensitive). Matched against the filename, not the whole path,
  /// so a directory named `foo.excalidraw.md/` can't misclassify its children.
  static bool _isForcedBinary(String path) {
    final lastSlash = path.lastIndexOf('/');
    final name = (lastSlash >= 0 ? path.substring(lastSlash + 1) : path)
        .toLowerCase();
    for (final suffix in _forceBinarySuffixes) {
      if (name.endsWith(suffix)) return true;
    }
    return false;
  }

  /// The file's lowercase extension WITHOUT the leading dot (e.g. `pdf`), or ''
  /// when it has none. Used by the per-device type-exclusion filter to match a
  /// path against a denylist of extensions.
  static String extensionOf(String path) {
    final ext = _extension(path);
    return ext.isEmpty ? '' : ext.substring(1);
  }

  static String _extension(String path) {
    final lastSlash = path.lastIndexOf('/');
    final name = lastSlash >= 0 ? path.substring(lastSlash + 1) : path;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot).toLowerCase();
  }
}
