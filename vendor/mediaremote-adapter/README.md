# mediaremote-adapter (vendored)

Source of [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
**v0.7.7** (commit `e3ff502`), BSD 3-Clause (see `LICENSE`). Only the adapter itself is kept:
the Perl script, the public header and `src/adapter`, `src/private`, `src/utility`, plus
`src/test/NowPlayingTest.h`, which `src/adapter/test.m` includes. The rest of the test client
and the CMake files are left out.

Since macOS 15.4 an app outside Apple cannot read the system's Now Playing information.
`/usr/bin/perl` still can, so Perch runs this script under it, the script loads the framework,
and the framework prints Now Playing updates as JSON lines. Perch's `NowPlaying.swift` reads them.

`build.sh` compiles the framework with plain `clang` (no CMake needed); `scripts/build-app.sh`
calls it and copies the result into `Perch.app/Contents/Resources/mediaremote/`.

To update: replace these files with a newer release's, keeping the same layout, bump the version
above and in `build.sh`, then check `/usr/bin/perl bin/mediaremote-adapter.pl <framework> get`.
