/// User-configurable source-file limit for Quick App RPK packages.
///
/// This controls only the compressed source file accepted for installation.
/// ZIP entry-count, expanded-size, manifest, and resource safety checks remain
/// fixed in [InstallMetadataReader].
class RpkInstallLimit {
  static const int defaultBytes = 100 * 1024 * 1024;
  static const int minimumBytes = 16 * 1024 * 1024;
  static const int maximumBytes = 100 * 1024 * 1024;

  static int _sourceBytes = defaultBytes;

  static int get sourceBytes => _sourceBytes;

  static void setSourceBytes(int value) {
    _sourceBytes = value.clamp(minimumBytes, maximumBytes).toInt();
  }
}
