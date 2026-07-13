# Media Quality & Compatibility Remediation Design

## Goal

Stop accumulating media files that Apple TV clients (Plex app primarily, Infuse as
fallback) can't play cleanly, and reclaim space on the 160TB RAIDZ2 pool by
trimming files that are far larger than they need to be for the quality they
actually deliver. Two parts: fix the acquisition rules so new grabs don't
reintroduce these problems, and remediate the existing library.

## Constraints

- All viewing devices are 4K Apple TVs. 4K is preferred, especially for movies
  and "big" TV shows (Game of Thrones, The Handmaid's Tale, Star Wars, Marvel),
  but compatibility beats resolution — an unplayable 4K file is worse than a
  playable 1080p one.
- Apple TV audio: only plays multichannel PCM, Dolby Digital (AC3), Dolby
  Digital Plus (EAC3), and Dolby Atmos natively. DTS/DTS-HD/DTS:X are never
  supported and must be transcoded. TrueHD passthrough works on newer models
  via HDMI to a compatible AVR, but isn't reliable enough to depend on.
- Dolby Vision profile 7 (dual-layer BL+EL, common in UHD BD remuxes) has no
  HDR10 fallback layer and is the main source of DV playback failures. Profile
  8/8.1 (single-layer, HDR10-compatible fallback) plays everywhere. `dovi_tool`
  mode 2 converts 7→8.1 losslessly (no video re-encode needed for the
  conversion itself).
- Transcode hardware is a dedicated i3-13100 box specifically chosen for
  QuickSync — re-encodes should use QSV HEVC, not software x265.
- Tdarr is already deployed (`tdarr.home.mcnees.me`) but currently idle — no
  scheduled hours, no active flow.

## Dry-Run Data (movies library, 1158 files, 32.6 TB)

Bitrate distribution by resolution bucket:

| bucket | files | total size | p25 | median | p75 | p90 | max (Mbps) |
|---|---|---|---|---|---|---|---|
| 4K | 696 | 26.4 TB | 19.8 | 41.4 | 61.4 | 77.4 | 98.6 |
| 1080p | 417 | 6.2 TB | 7.8 | 19.7 | 32.1 | 36.7 | 41.2 |

Compatibility issues found:

- DV profile 7 (no HDR10 fallback): 134 files
- DV profile 8 (fine as-is): 225 files
- DV profile 5: 21 files — no confirmed playback problem, out of scope for now
- Audio-incompatible (DTS-family only, no AC3/EAC3/AAC/PCM/FLAC track): 143 files

Space-reclaim simulation at candidate bitrate ceilings (movies only):

| 4K cap | 1080p cap | files touched | space reclaimed |
|---|---|---|---|
| 60 Mbps | 20 Mbps | 394 | ~4.0 TB |
| 50 Mbps | 18 Mbps | 522 | ~6.4 TB |
| 40 Mbps | 15 Mbps | 593 | ~9.8 TB |

Chosen ceiling: **60 Mbps for 4K, 20 Mbps for 1080p.** Dial down later
(50/18, then 40/15) if more space is needed — the same flow logic applies,
only the threshold changes.

Audio-track stripping (drop non-English tracks, keep first track if no
`eng`-tagged track exists; drop commentary-tagged tracks) was evaluated
separately: only ~0.37 TB reclaimable across the whole movie library, an
order of magnitude smaller than the bitrate ceiling. It's still worth doing
because it's a lossless remux (stream-copy, no re-encode cost) that can ride
along in the same pass. Savings concentrate in outlier titles with many
dubbed tracks (Marvel, Harry Potter, Interstellar — up to 15 GB per file), plus
52.8 GB across 215 commentary tracks.

TV and anime libraries were not separately scanned. Rather than run a second
dry-run cycle, the remediation flow (below) evaluates files individually
against the same rules, so it naturally "scans" TV/anime as it processes them.
If TV data turns out meaningfully different once real numbers are visible in
Tdarr, ceilings can be adjusted the same way movies' were.

## Part A — Acquisition Rules (Recyclarr)

Applies going forward so new grabs don't reintroduce the problems above.

- Add the TRaSH Guides `DV (w/o HDR fallback)` custom format to both Sonarr
  and Radarr quality profiles, scored to block/strongly deprioritize
  profile-7-only releases in favor of alternatives with an HDR10 fallback.
  Keep the general `HDR` custom format as-is (positive score).
- Set Recyclarr `quality_definition` size ceilings (preferred/max, expressed
  as MB/min) on the 2160p and 1080p quality tiers to match the chosen bitrate
  ceilings (60 Mbps ≈ 450 MB/min, 20 Mbps ≈ 150 MB/min), so Sonarr/Radarr stop
  grabbing releases that would just need to be shrunk immediately after.
  Exact tuning happens in the implementation plan against Recyclarr's actual
  size-definition mechanics.
- Radarr (movies): default profile continues to prefer 4K when available,
  within the new size ceiling.
- Sonarr (TV): default profile stays 1080p-first (most shows don't need 4K).
  "Big" marquee shows (GoT, Handmaid's Tale, Star Wars/Marvel-adjacent series)
  get a manual per-series override to a 4K-preferred profile, applied by hand
  to the specific series rather than a blanket rule — there's no reliable
  automated signal for "this show matters enough for 4K."

## Part B — Library Remediation (Tdarr)

One Tdarr flow, applied library-wide (movies first, since that's the data
we've validated; TV/anime follow using the same rules). Per file, in order,
skipping any step that doesn't apply:

1. **DV profile 7 → 8.1**: convert via `dovi_tool` mode 2. Lossless,
   no video re-encode.
2. **Bitrate ceiling**: if video bitrate exceeds 60 Mbps (4K) / 20 Mbps
   (1080p), re-encode video via QSV HEVC down to at/below the ceiling.
   Skip if already under ceiling — most files won't need this step.
3. **Audio compatibility**: if no AC3/EAC3/AAC/PCM/FLAC track exists (i.e.
   DTS-family only), transcode the primary audio track to EAC3 5.1. Original
   DTS track is dropped, not kept alongside — it's the same track re-encoded,
   not an addition.
4. **Audio track pruning**: drop audio tracks not tagged `eng` (keep the
   first track if none are tagged `eng`), and drop anything tagged
   commentary. Applies even to files that don't need steps 2 or 3.

Files that already satisfy all four conditions are left untouched — Tdarr
should skip them quickly rather than needlessly re-processing.

## Rollout

1. Audio-track pruning first, library-wide — cheap, lossless, immediate
   partial win, and de-risks the flow logic before adding the heavier
   re-encode steps.
2. Add DV7→8.1 conversion and bitrate-ceiling re-encode steps, run against
   movies first (already validated with dry-run data).
3. Extend to TV and anime once movies are running cleanly.
4. Recyclarr acquisition-rule changes can land independently/in parallel —
   they don't depend on the Tdarr flow being done.

## Verification

- Spot-check a handful of remediated files (at least one DV7 conversion, one
  DTS-transcode, one bitrate-downconvert) in both the Plex app and Infuse on
  an actual Apple TV before letting the flow run unattended at scale.
- Watch Tdarr queue depth/throughput given this is a single QSV node (i3-13100)
  — no parallelism to lean on if the queue backs up.

## Non-Goals

- DV profile 5 files (21 in movies) — no confirmed compatibility problem,
  not touched by this pass.
- TrueHD passthrough handling — not relying on it; anything TrueHD-only
  falls under the same "no compatible track" rule as DTS.
- Automated "is this show a big show" detection for the 4K Sonarr override —
  stays a manual per-series decision.
