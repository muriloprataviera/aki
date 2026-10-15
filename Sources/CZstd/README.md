# Vendored Zstandard decoder

`zstddeclib.c` is Zstandard's official single-file decode-only amalgamation, v1.5.7
(https://github.com/facebook/zstd), BSD-3-Clause (`LICENSE` beside it), unedited.
Taken as vendored by Codenotch (MIT). The Claude desktop app keeps its HTTP responses
zstd-compressed in its cache, and macOS has no zstd a signed app can use; Aki reads
the account's usage (limits) from there, for people who use the app and not Claude Code.
