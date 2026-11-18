# Off-water trim suggestions

The local editor prototype uses a WaterKit classifier exercised with synthetic GPS and geometry. Call
`OffWaterSuggestions.suggest(in:using:)` with the original `RawSession` and an installed
`WaterBoundarySource`. An empty result means there is no interval supported by the available
evidence. All times are inclusive seconds from the original start, capped by the editor's existing
recording bound. The output contains only proposed removal intervals and review evidence.

## Evidence required

- Each land fix must pass WaterKit's GPS filter and have verified land geometry. Its clearance to
  water, ambiguous features and the edge of verified coverage must exceed 15 m plus twice its
  reported horizontal accuracy. The provider also allows for uncertainty in its source geometry.
- A land run needs at least 45 s and 24 fixes. Gaps over 2.5 s, rejected fixes, or missing coverage
  break the run and its context. A known dock mask or a fix with insufficient clearance breaks
  the run, leaving that interval out of the proposal. Consecutive supported areas must overlap
  along the direct step, protecting against small intervening water or coverage gaps.
- An adjacent run of confidently mapped water in the same usable block must last at least 20 s
  with 12 fixes and be within 120 s of the land run. Water on both sides adds corroboration.
  The thresholds are prototype defaults. The evidence levels carry no probability estimate.

Doppler speed is used by the existing GPS filter for plausibility. Stops, low speed, sparse
observations, pause events and distance to the recording endpoints provide no surface evidence.
The supported timestamps bound each proposal. The gaps between observations and the accuracy of
the source geometry limit what can be inferred about the actual route.

## Try the native editor

Run the MadeGood Debug scheme on an iPhone simulator with the launch argument `-demoOffWater`.
History opens with one synthetic kayak recording in a separate demo store. Open the recording,
then tap **Trim Session**, **Preview Cut**, and **Accept Cut**. Confirm with **Save**. The fixture
uses an in-memory synthetic boundary pack and a route drawn without map tiles.

The suggestion shows the original recording time, the shifted replay time when applicable, and
the land fixes and nearby water evidence. The preview compares the draft selection with the
selection that would result from acceptance. Both use the same replay and metrics as saved edits.
Only proposals strictly inside the keep handles can become middle cuts. A proposal that overlaps
or touches an existing cut previews the union. A proposal already covered by a cut is hidden.
The two boundaries of the resulting cut retain fixes exactly on them.

**Accept Cut** adds the ordinary editable cut to the draft. **Save** writes the sidecar. In
**Edit Trim**, use **Keep This Segment** and save to restore an individual cut, or select
**Restore Original** to remove the sidecar. [Local trim metadata](formats.md#local-trim-metadata)

For a fresh demo store, add `-demoOffWaterV1Trim` to seed an existing start trim and exercise
both clocks. Add `-demoUnsupportedBoundaryPack` to exercise the manual editor with a checksummed
but unsupported pack. The UI tests use a fresh demo store per test.

## Local boundary pack prototype

`PackedWaterBoundarySource` implements `WaterBoundarySource` in WaterKit. It takes in-memory bytes
or a local file URL, validates the entire pack on import, and exposes the manifest or a rejection
reason via `validation`. Rejected packs, uncovered fixes and unverified areas yield unknown.
Within verified coverage, docks, bridges and the uncertainty bands around those features and
water boundaries yield ambiguous evidence. Positive evidence uses the nearest coverage edge,
unverified area, mask or water ring, with the pack's combined uncertainty subtracted.

The CLI fixture pack contains only hand-authored geometry and lives in the WaterKit test resources.
The iPhone fixture is compiled only in Debug builds. The format admits only declared synthetic
provenance and uses CRC-32 to detect accidental damage.
See [Boundary pack v1](formats.md#boundary-pack-v1) for the format and limits.

From the repository root, validate the fixture and run the import-to-suggestion regression harness.

```sh
swift run --package-path packages/WaterKit waterkit-boundary-check \
  packages/WaterKit/Tests/WaterKitTests/Resources/synthetic-water-boundaries.mgwb
swift test --package-path packages/WaterKit --filter 'WaterBoundaryPackTests|OffWaterSuggestionsTests'
```

## Regional data dependency

Use a versioned, read-only vector pack installed on the phone. Build the first pack for a bounded,
audited pilot region selected independently of user recordings. Recommended inputs are the
full-resolution OSM-derived ocean polygons and OSM inland water multipolygons, including lakes,
reservoirs, canals and polygonal rivers. Preserve islands and polygon holes. Include uncertainty
masks for known piers, bridges, marinas, intermittent water and tidal areas. The coastal polygons
cover coastline-tagged water. Inland water requires a separate source layer. See
[ocean polygon downloads](https://osmdata.openstreetmap.de/data/water-polygons.html),
[Planet OSM downloads](https://planet.openstreetmap.org/),
[inland water tags](https://wiki.openstreetmap.org/wiki/Tag:natural%3Dwater) and
[pier tags](https://wiki.openstreetmap.org/wiki/Tag:man_made%3Dpier).

The downloads and derived OSM data are available under ODbL 1.0. Ship attribution and licence
notices with the pack and in the app. Plan to distribute the derived database under ODbL with the
access required by the licence, including an unrestricted copy if store terms impose technical
restrictions. See [OSM licensing](https://www.openstreetmap.org/copyright),
[OSMF attribution guidelines](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines),
and [ODbL 1.0 §4](https://opendatacommons.org/licenses/odbl/1-0/).

Select the pilot independently of user recordings. Check the specific releases' licenses and
redistribution terms together with the intended app and pack distribution. Record each input's
snapshot identifier, footprint, acquisition/processing date, datum, license and attribution.
OSM coastline processing may leave older downloads in place when repairs fail. For a U.S. pilot,
NOAA and USGS are candidate sources. NOAA publishes mean-high-water and mean-lower-low-water
shorelines in NAD83 without a product-wide absolute accuracy figure. A USGS 3DHP extract can mix
elevation-derived hydrography with older NHD sources. Inspect the selected work units and validate
water completeness and shoreline alignment before approving a coverage mask.
[OSM coastline processing notes](https://osmdata.openstreetmap.de/data/water-polygons.html),
[NOAA National Shoreline](https://shoreline.noaa.gov/national.html),
[USGS 3DHP downloadable collection](https://data.usgs.gov/datacatalog/data/USGS%3A4e10157a-e4fd-41bf-aff0-6c537d7efbdf)

Apple's terms restrict extraction, derived databases and long-term storage of Apple Maps data.
[Apple Developer Program License Agreement, Attachment 6](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)

For qualification, use independently sourced reference geometry and labeled synthetic transects
for shoreline, inland channels, holes, docks, bridges, tidal uncertainty and incomplete seams.
Measure false land evidence, false removal proposals and abstentions. Account for coverage
completeness separately from positional uncertainty. Include datum conversion, clipping,
simplification, snapping and quantization in the error budget, and leave gaps or stale areas
unverified. Benchmark pack size, import and lookup on the supported iPhone models before deciding
whether real packs need tiled geometry and an index.

For distribution, generate reproducible packs with input hashes and a signed manifest binding
the exact payload digest and byte count to a pack ID, region, revision, coverage, source metadata,
error allowance, freshness and reader compatibility. A future installer should verify against
a trusted app key before activation, handle rotation, revocation, expired and rolled-back packs,
and atomically activate only a fully verified revision. Test tampering, partial installs and
recovery while offline. CRC-32 provides no publisher authentication. [The Update Framework specification](https://theupdateframework.github.io/specification/latest/)

Install or select any future pack independently of session coordinates. Keep fixes, bounds and
classification results on device. Omit suggestions whenever a qualified pack or local evidence
is unavailable.
