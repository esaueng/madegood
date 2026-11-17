# WaterKit

Pure-Swift models and algorithms shared by the MadeGood iPhone and Apple Watch apps.
It has no Apple-only framework dependencies, so it builds and tests on Linux.

```sh
swift test --package-path packages/WaterKit
```

On Linux, install the zlib headers first (`apt-get install zlib1g-dev`).

## Contents

- **Models:** `GPSFix`, `HRSample`, `MotionSample`, `HeadingSample`, `SessionEvent`,
  `Sample`, `Sport`, `Track`. SI units throughout.
- **Track v1:** `TrackCodec` reads and writes `track.json.gz`.
- **Raw recording v1:** `RawFormat` defines the files the recorder writes, and
  `RawSessionReader` loads a session folder onto one timeline.
- **Gzip:** `Gzip` compresses to and decompresses from the gzip container, using the
  system zlib.

The formats are specified in [docs/formats.md](../../docs/formats.md).
