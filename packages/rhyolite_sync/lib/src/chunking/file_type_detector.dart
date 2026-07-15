/// Determines whether a file should use chunked storage based on its extension.
///
/// Text files (markdown, json, etc.) use single-blob storage for 3-way merge.
/// Binary files (images, PDFs, etc.) use content-defined chunking.
class FileTypeDetector {
  const FileTypeDetector();

  static const _textExtensions = <String>{
    '.md',
    '.txt',
    '.json',
    '.canvas',
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

  bool shouldChunk(String path) {
    final ext = _extension(path);
    if (ext.isEmpty) return false;
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
    final ext = _extension(path);
    if (ext.isEmpty) return true;
    return _textExtensions.contains(ext);
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
