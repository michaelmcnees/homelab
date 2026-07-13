# Media Quality & Compatibility Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop Recyclarr from letting Sonarr/Radarr grab Dolby-Vision-profile-7-only or oversized releases, and build a Tdarr flow that fixes DV7, bitrate, and audio-compatibility problems in the existing movie library.

**Architecture:** Two independent halves. (A) Recyclarr config changes, entirely in-repo YAML, applied via the existing Recyclarr CronJob/sync mechanism. (B) A single Tdarr Flow built around one custom JS decision/action module, applied to the already-existing "Movies" Tdarr library (switched from its current unused classic-plugin-stack mode into Flow mode).

**Tech Stack:** Recyclarr (YAML, TRaSH Guides trash_ids), Tdarr 2.81.01 (Flow plugins + one Custom JS Function node), Node.js (>=18, for `node:test`/`node:assert` — no npm/package.json needed), ffmpeg (QSV hardware encode), `dovi_tool`, `mkvmerge`.

## Global Constraints

- Bitrate ceilings: **60 Mbps for 4K** (`width >= 3800`), **20 Mbps for 1080p** (`width >= 1900 && < 3800`). Do not touch 720p/sub720p files.
- Audio: a file is compatible if it has at least one track in `aac, ac3, eac3, pcm_s16le, pcm_s24le, flac`. Incompatible (DTS-family-only) files get their primary track transcoded to **EAC3 5.1 @ 640k**, original DTS track dropped (not kept alongside).
- Audio track pruning: keep tracks tagged `language: eng`; if none are tagged `eng`, keep only the first audio track. Drop any track whose `tags.title` contains "commentary" (case-insensitive), even from the keep set.
- DV: convert **profile 7 only** to profile 8.1 via `dovi_tool -m 2 convert --discard`. Leave profile 5, 8, and no-DV files untouched.
- Only re-encode video (QSV HEVC) when the bitrate ceiling is exceeded — never re-encode a file that's already compliant just to touch it.
- This plan only touches the **movies** Tdarr library (`/media/movies`) and the two Recyclarr-managed profiles that already exist in `kubernetes/apps/recyclarr/configmap.yaml`. TV/anime and any other Radarr/Sonarr profiles are out of scope for this plan.

---

## Current State (verified live during planning, 2026-07-13)

**Recyclarr / Radarr / Sonarr:**
- `kubernetes/apps/recyclarr/configmap.yaml` currently manages exactly two profiles: Radarr `HD Bluray + WEB` (trash_id `d1d67249d3890e49bc12e275d989a7e9`) and Sonarr `WEB-1080p` (trash_id `72dae194fc92bf828f32cde7744e51a1`).
- Confirmed live via Radarr/Sonarr API (`GET /api/v3/qualityprofile`): Radarr's `HD Bluray + WEB` only allows up to `Bluray-1080p`/`WEB 1080p` — it never grabs 2160p releases, so DV metadata is a non-issue for it. Radarr already has a **hand-managed, Recyclarr-unaware** profile called `UltraHD - 4K` that allows everything up to `Remux-2160p` — this is almost certainly where the 696 4K movies (and all 134 DV-profile-7 files) in the library came from. Sonarr similarly has a hand-managed `Ultra-HD 4K` profile Recyclarr doesn't touch.
- Because of this, adding the DV-blocking custom format only to the existing two managed profiles would protect nothing (they never see 2160p releases). This plan adds Recyclarr management of a **new, separate** 4K profile for each app instead of touching the existing hand-made ones — Recyclarr matches/creates profiles by name, and the trash preset names (`UHD Bluray + WEB` for Radarr, `WEB-2160p` for Sonarr) differ from the existing hand-made names (`UltraHD - 4K`, `Ultra-HD 4K`), so this is additive and won't touch or rename the existing profiles.
- **Manual follow-up required after this plan lands** (not part of this plan — a profile-default/reassignment change in the Radarr/Sonarr UI, not a repo change): point Radarr's default profile (and any per-movie overrides) at the new Recyclarr-managed `UHD Bluray + WEB` profile instead of `UltraHD - 4K` so new 4K grabs actually get the DV/size protections. Same for Sonarr's marquee-show overrides.

**Tdarr (`10.0.1.1:30028`, not managed by any Ansible role or k8s manifest in this repo — only `kubernetes/apps/external-services/tdarr.yaml` proxies to it):**
- Version `2.81.01`, single node named `Server` (internal node, `remoteAddress: 127.0.0.1`, `nodeType: mapped`).
- Node's `gpuSelect` is currently `"-"` (no GPU selected) and `schedule` has all 24 hourly slots zeroed for every worker type — the node is fully idle by design, not broken.
- Exactly one library exists: `Movies` (`folder: /media/movies`, `output: /media/optimized/movies`, `pluginStackOverview: false` — i.e. still on the old classic single-plugin-stack system, not the newer Flow system). It has a pre-existing but never-run classic plugin stack, including a `qsv: true`-configured "DrDD H265 MKV AC3 Audio Subtitles" plugin that was clearly an earlier abandoned attempt at something similar to this plan — it will be replaced, not reused (it doesn't handle DV profile 7 at all, and it downmixes to AC3 instead of EAC3, and it's a black-box script, not something we can unit test or reason about precisely).
- `FlowsJSONDB` (the Flow-mode config collection) is empty — no Flow has ever been built.
- Read/write access confirmed via `POST /api/v2/cruddb` with `{"data":{"collection":"<Name>","mode":"getAll","docID":"","obj":{}}}` (collections seen so far: `LibrarySettingsJSONDB`, `FlowsJSONDB`, `NodeJSONDB`). Update/insert modes were not exercised during planning — verify the exact `mode` value (`update`, `insert`, or similar) against the Tdarr source or by trial when a task below calls for a write.
- No SSH/Ansible access exists to whatever host actually runs this Tdarr instance (confirmed during the design/brainstorming phase — the box isn't in `ansible/inventory/hosts.yml` and isn't reachable). Anything requiring shell access to that host (installing `dovi_tool`/`mkvmerge`, checking `/dev/dri` passthrough) is a **manual task for whoever has hands-on access to that box** — flagged explicitly in the tasks below, not something an agent executing this plan purely through `kubectl`/API calls can complete unattended.

---

### Task 1: Recyclarr — add DV/HDR custom formats and size ceilings to the two existing managed profiles

**Files:**
- Modify: `kubernetes/apps/recyclarr/configmap.yaml`

**Interfaces:**
- Produces: the `custom_formats:` and `quality_definition:` blocks other tasks in this plan don't depend on directly, but which the follow-up 4K-profile task (Task 2) mirrors.

- [ ] **Step 1: Add the `quality_definition` size ceiling to both apps**

Edit `kubernetes/apps/recyclarr/configmap.yaml` so the `sonarr.tv-web-1080p` block gains a `quality_definition` size ceiling (20 Mbps ≈ 150 MB/min) and the `radarr.movies-hd-bluray-web` block keeps its existing 1080p-only `quality_definition` at the same ceiling (it never sees 2160p, so no 60 Mbps entry is needed here — that goes on the new profile in Task 2):

```yaml
    sonarr:
      tv-web-1080p:
        base_url: http://sonarr.media.svc.cluster.local:8989
        api_key: !secret sonarr_api_key
        quality_definition:
          type: series
          qualities:
            - name: WEBDL-1080p
              max: 150
              preferred: 140
            - name: Bluray-1080p
              max: 150
              preferred: 140
        quality_profiles:
          - trash_id: 72dae194fc92bf828f32cde7744e51a1 # WEB-1080p
            reset_unmatched_scores:
              enabled: true

    radarr:
      movies-hd-bluray-web:
        base_url: http://radarr.media.svc.cluster.local:7878
        api_key: !secret radarr_api_key
        quality_definition:
          type: movie
          qualities:
            - name: WEBDL-1080p
              max: 150
              preferred: 140
            - name: Bluray-1080p
              max: 150
              preferred: 140
        quality_profiles:
          - trash_id: d1d67249d3890e49bc12e275d989a7e9 # HD Bluray + WEB
            reset_unmatched_scores:
              enabled: true
```

**Step 1 note:** `max`/`preferred` are in **MB per minute of runtime** (confirmed against https://recyclarr.dev/reference/configuration/quality-definition/). 20 Mbps = 20 / 8 * 60 = 150 MB/min; we set `preferred` slightly under `max` (140) so Sonarr/Radarr don't sit right at the edge.

- [ ] **Step 2: Run `recyclarr` in preview mode to check the diff before committing**

The Recyclarr container image ships the `recyclarr` binary. Run it against the edited config with the dry-run flag so nothing is pushed to Sonarr/Radarr yet:

```bash
export KUBECONFIG=/Users/michael/Developer/homelab/talos/kubeconfig
kubectl create configmap recyclarr-config-preview -n apps --dry-run=client -o yaml \
  --from-file=recyclarr.yml=<(yq '.data."recyclarr.yml"' -r kubernetes/apps/recyclarr/configmap.yaml) > /tmp/recyclarr-preview-cm.yaml
kubectl get cronjob -n apps -o name | grep -i recyclarr
```

Find the actual Recyclarr CronJob name from the second command's output, then run a one-off Job from that CronJob's pod spec with `--preview` appended to its args (check the CronJob's `command`/`args` first with `kubectl get cronjob <name> -n apps -o yaml` — Recyclarr's CLI flag for dry-run preview is `--preview` / `-p`, append it to whatever `recyclarr sync` invocation the CronJob already uses).

Expected: preview output shows a diff adding the `DV (w/o HDR fallback)` custom format is **not** part of this step's diff yet (that's Task 2) — this step's diff should only show the new `quality_definition` size entries. If the diff shows something unexpected (e.g. it also touches `UltraHD - 4K` or `Ultra-HD 4K`), stop and re-check — those profiles must not be touched by this plan.

- [ ] **Step 3: Apply and commit**

```bash
export KUBECONFIG=/Users/michael/Developer/homelab/talos/kubeconfig
kubectl apply -f kubernetes/apps/recyclarr/configmap.yaml
git add kubernetes/apps/recyclarr/configmap.yaml
git commit -m "Add 1080p size ceiling to Recyclarr-managed Sonarr/Radarr profiles"
```

---

### Task 2: Recyclarr — add new Recyclarr-managed 4K profiles with DV/HDR custom formats and 60 Mbps ceiling

**Files:**
- Modify: `kubernetes/apps/recyclarr/configmap.yaml`

**Interfaces:**
- Consumes: nothing from Task 1 beyond the same file.
- Produces: two new profiles — Radarr `UHD Bluray + WEB`, Sonarr `WEB-2160p` — that the manual follow-up (documented in Current State above) will need to be assigned to movies/shows in place of the existing hand-made 4K profiles.

- [ ] **Step 1: Add the new profiles and custom formats**

```yaml
    sonarr:
      tv-web-1080p:
        # ...(unchanged from Task 1)...

      tv-web-2160p:
        base_url: http://sonarr.media.svc.cluster.local:8989
        api_key: !secret sonarr_api_key
        quality_definition:
          type: series
          qualities:
            - name: WEBDL-2160p
              max: 450
              preferred: 420
            - name: Bluray-2160p
              max: 450
              preferred: 420
        quality_profiles:
          - trash_id: d1498e7d189fbe6c7110ceaabb7473e6 # WEB-2160p
            reset_unmatched_scores:
              enabled: true
        custom_formats:
          - trash_ids:
              - 9b27ab6498ec0f31a3353992e19434ca # DV (w/o HDR fallback)
            assign_scores_to:
              - name: WEB-2160p
                score: -10000
          - trash_ids:
              - 505d871304820ba7106b693be6fe4a9e # HDR
            assign_scores_to:
              - name: WEB-2160p
                score: 0

    radarr:
      movies-hd-bluray-web:
        # ...(unchanged from Task 1)...

      movies-uhd-bluray-web:
        base_url: http://radarr.media.svc.cluster.local:7878
        api_key: !secret radarr_api_key
        quality_definition:
          type: movie
          qualities:
            - name: WEBDL-2160p
              max: 450
              preferred: 420
            - name: Bluray-2160p
              max: 450
              preferred: 420
            - name: Remux-2160p
              max: 450
              preferred: 420
        quality_profiles:
          - trash_id: 64fb5f9858489bdac2af690e27c8f42f # UHD Bluray + WEB
            reset_unmatched_scores:
              enabled: true
        custom_formats:
          - trash_ids:
              - 923b6abef9b17f937fab56cfcf89e1f1 # DV (w/o HDR fallback)
            assign_scores_to:
              - name: UHD Bluray + WEB
                score: -10000
          - trash_ids:
              - 493b6d1dbec3c3364c59d7607f7e3405 # HDR
            assign_scores_to:
              - name: UHD Bluray + WEB
                score: 0
```

`-10000` matches TRaSH Guides' own convention for "must not grab" custom formats (it's the score TRaSH's own preset profiles use for equivalent block-list formats), so a release scoring this CF only gets grabbed if literally nothing else is available and the profile's minimum format score allows negative totals — in practice this makes DV7-only releases rank below every alternative. `HDR` is scored `0` (informational/tie-break, not a blocker) since we want DV7 to be the blocking signal, not HDR presence itself.

- [ ] **Step 2: Preview, then apply and commit**

Same preview mechanism as Task 1 Step 2. This time expect the diff to show two brand-new profiles being created (`WEB-2160p` in Sonarr, `UHD Bluray + WEB` in Radarr) — it must **not** show any change to `UltraHD - 4K` or `Ultra-HD 4K`. If it does, stop; that means the trash_id's preset name matches an existing profile name more closely than expected and would overwrite hand-tuned settings.

```bash
export KUBECONFIG=/Users/michael/Developer/homelab/talos/kubeconfig
kubectl apply -f kubernetes/apps/recyclarr/configmap.yaml
git add kubernetes/apps/recyclarr/configmap.yaml
git commit -m "Add Recyclarr-managed 4K profiles with DV7 blocking for movies/marquee TV"
```

- [ ] **Step 3: Note the manual follow-up (do not skip silently)**

Tell the user (or leave a clear note in the PR/commit description) that new 4K acquisitions will still land under the old hand-managed `UltraHD - 4K` / `Ultra-HD 4K` profiles until someone manually repoints Radarr's/Sonarr's default profile (or specific movie/series overrides) at the new `UHD Bluray + WEB` / `WEB-2160p` profiles in the Radarr/Sonarr UI. This is an application-level setting, not something in this repo, so it's out of scope for this plan to change automatically.

---

### Task 3: Tdarr quality-remediation module — pure decision logic (TDD)

**Files:**
- Create: `scripts/tdarr-quality-remediation-plugin.js`
- Create: `scripts/tdarr-quality-remediation-plugin.test.js`

**Interfaces:**
- Produces: `classifyFile(ffprobeData, fileSizeBytes)`, `needsDoviConversion(videoStream)`, `needsBitrateReduction(videoStream, formatBitrateBps, durationSec, fileSizeBytes)`, `needsAudioTranscode(audioStreams)`, `pickAudioTracksToKeep(audioStreams)`, `resBucket(width)` — all pure functions, no I/O. Task 4 imports these plus adds command-building functions to the same file.
- Field names consumed (`side_data_list[].dv_profile`, `tags.language`, `tags.title`, `codec_name`, `width`, `format.duration`, `format.bit_rate`) are the exact ffprobe JSON fields already validated empirically against this library's real files during the design/brainstorming dry-run scan — not guessed.

- [ ] **Step 1: Write the failing tests**

```javascript
// scripts/tdarr-quality-remediation-plugin.test.js
const test = require('node:test');
const assert = require('node:assert/strict');
const {
  resBucket,
  needsDoviConversion,
  needsBitrateReduction,
  needsAudioTranscode,
  pickAudioTracksToKeep,
  classifyFile,
} = require('./tdarr-quality-remediation-plugin');

test('resBucket classifies by width', () => {
  assert.equal(resBucket(3840), '4k');
  assert.equal(resBucket(1920), '1080p');
  assert.equal(resBucket(1280), '720p');
  assert.equal(resBucket(640), 'sub720p');
  assert.equal(resBucket(undefined), 'unknown');
});

test('flags DV profile 7 for conversion, leaves profile 8 and 5 alone', () => {
  assert.equal(needsDoviConversion({ side_data_list: [{ dv_profile: 7 }] }), true);
  assert.equal(needsDoviConversion({ side_data_list: [{ dv_profile: 8 }] }), false);
  assert.equal(needsDoviConversion({ side_data_list: [{ dv_profile: 5 }] }), false);
  assert.equal(needsDoviConversion({ side_data_list: [] }), false);
});

test('flags 4K file over 60 Mbps ceiling, leaves file under ceiling alone', () => {
  const video = { width: 3840 };
  const over = needsBitrateReduction(video, 70_000_000, 3600, 0);
  const under = needsBitrateReduction(video, 40_000_000, 3600, 0);
  assert.equal(over.needed, true);
  assert.equal(over.ceiling, 60);
  assert.equal(under.needed, false);
});

test('flags 1080p file over 20 Mbps ceiling', () => {
  const video = { width: 1920 };
  const over = needsBitrateReduction(video, 25_000_000, 3600, 0);
  assert.equal(over.needed, true);
  assert.equal(over.ceiling, 20);
});

test('never flags 720p/sub720p, regardless of bitrate', () => {
  const video = { width: 1280 };
  const result = needsBitrateReduction(video, 999_000_000, 3600, 0);
  assert.equal(result.needed, false);
});

test('estimates bitrate from file size when format bit_rate is missing/zero', () => {
  const video = { width: 1920 };
  // 10 GB over 3600s ~= 22.2 Mbps, over the 20 Mbps 1080p ceiling
  const result = needsBitrateReduction(video, 0, 3600, 10 * 1e9);
  assert.equal(result.needed, true);
});

test('flags DTS-only audio for transcode, leaves AC3/EAC3 alone', () => {
  assert.equal(needsAudioTranscode([{ codec_name: 'dts' }]), true);
  assert.equal(needsAudioTranscode([{ codec_name: 'dts' }, { codec_name: 'ac3' }]), false);
  assert.equal(needsAudioTranscode([{ codec_name: 'eac3' }]), false);
});

test('keeps only eng-tagged audio tracks, drops the rest including a commentary eng track', () => {
  const streams = [
    { index: 1, codec_name: 'eac3', tags: { language: 'eng' } },
    { index: 2, codec_name: 'ac3', tags: { language: 'fre' } },
    { index: 3, codec_name: 'ac3', tags: { language: 'eng', title: 'Director Commentary' } },
  ];
  const keep = pickAudioTracksToKeep(streams);
  assert.deepEqual(keep.map((a) => a.index), [1]);
});

test('keeps first track when no track is tagged eng', () => {
  const streams = [
    { index: 1, codec_name: 'ac3', tags: { language: 'jpn' } },
    { index: 2, codec_name: 'dts', tags: { language: 'fre' } },
  ];
  const keep = pickAudioTracksToKeep(streams);
  assert.deepEqual(keep.map((a) => a.index), [1]);
});

test('classifyFile end-to-end: DV7 + oversized 4K + DTS-only audio', () => {
  const ffprobeData = {
    format: { duration: '7200', bit_rate: '0' },
    streams: [
      { codec_type: 'video', width: 3840, side_data_list: [{ dv_profile: 7 }] },
      { codec_type: 'audio', index: 1, codec_name: 'dts', tags: { language: 'eng' } },
      { codec_type: 'audio', index: 2, codec_name: 'dts', tags: { language: 'fre' } },
    ],
  };
  // 90 GB / 7200s ~= 100 Mbps, over the 60 Mbps 4K ceiling
  const result = classifyFile(ffprobeData, 90 * 1e9);
  assert.equal(result.needsDoviConversion, true);
  assert.equal(result.needsBitrateReduction, true);
  assert.equal(result.needsAudioTranscode, true);
  assert.deepEqual(result.audioTracksToKeepIndexes, [1]);
  assert.deepEqual(result.audioTracksToDropIndexes, [2]);
  assert.equal(result.actionRequired, true);
});

test('classifyFile: fully compliant file needs no action', () => {
  const ffprobeData = {
    format: { duration: '3600', bit_rate: '15000000' },
    streams: [
      { codec_type: 'video', width: 1920, side_data_list: [] },
      { codec_type: 'audio', index: 1, codec_name: 'ac3', tags: { language: 'eng' } },
    ],
  };
  const result = classifyFile(ffprobeData, 6 * 1e9);
  assert.equal(result.actionRequired, false);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
node --test scripts/tdarr-quality-remediation-plugin.test.js
```

Expected: FAIL — `Cannot find module './tdarr-quality-remediation-plugin'`.

- [ ] **Step 3: Write the implementation**

```javascript
// scripts/tdarr-quality-remediation-plugin.js
const COMPATIBLE_AUDIO_CODECS = ['aac', 'ac3', 'eac3', 'pcm_s16le', 'pcm_s24le', 'flac'];
const BITRATE_CEILING_MBPS = { '4k': 60, '1080p': 20 };

function resBucket(width) {
  if (!width) return 'unknown';
  if (width >= 3800) return '4k';
  if (width >= 1900) return '1080p';
  if (width >= 1200) return '720p';
  return 'sub720p';
}

function getDvProfile(videoStream) {
  const sideData = videoStream.side_data_list || [];
  const dv = sideData.find((sd) => Object.prototype.hasOwnProperty.call(sd, 'dv_profile'));
  return dv ? dv.dv_profile : null;
}

function needsDoviConversion(videoStream) {
  return getDvProfile(videoStream) === 7;
}

function needsBitrateReduction(videoStream, formatBitrateBps, durationSec, fileSizeBytes) {
  const bucket = resBucket(videoStream.width);
  const ceiling = BITRATE_CEILING_MBPS[bucket];
  if (!ceiling) {
    return { needed: false, bucket, ceiling: null, mbps: null };
  }
  let bitrateBps = formatBitrateBps;
  if (!bitrateBps && durationSec > 0) {
    bitrateBps = Math.floor((fileSizeBytes * 8) / durationSec);
  }
  const mbps = bitrateBps / 1e6;
  return { needed: mbps > ceiling, mbps, ceiling, bucket };
}

function needsAudioTranscode(audioStreams) {
  return !audioStreams.some((a) => COMPATIBLE_AUDIO_CODECS.includes(a.codec_name));
}

function pickAudioTracksToKeep(audioStreams) {
  const engTracks = audioStreams.filter((a) => a.tags && a.tags.language === 'eng');
  const base = engTracks.length > 0 ? engTracks : audioStreams.slice(0, 1);
  return base.filter((a) => {
    const title = ((a.tags && a.tags.title) || '').toLowerCase();
    return !title.includes('commentary');
  });
}

function classifyFile(ffprobeData, fileSizeBytes) {
  const streams = ffprobeData.streams || [];
  const videoStream = streams.find((s) => s.codec_type === 'video');
  const audioStreams = streams.filter((s) => s.codec_type === 'audio');
  const duration = parseFloat((ffprobeData.format && ffprobeData.format.duration) || '0');
  const formatBitrate = parseInt((ffprobeData.format && ffprobeData.format.bit_rate) || '0', 10);

  const dovi = videoStream ? needsDoviConversion(videoStream) : false;
  const bitrateCheck = videoStream
    ? needsBitrateReduction(videoStream, formatBitrate, duration, fileSizeBytes)
    : { needed: false };
  const audioTranscode = needsAudioTranscode(audioStreams);
  const keepTracks = pickAudioTracksToKeep(audioStreams);
  const keepIndexes = new Set(keepTracks.map((a) => a.index));
  const dropTracks = audioStreams.filter((a) => !keepIndexes.has(a.index));

  return {
    needsDoviConversion: dovi,
    needsBitrateReduction: bitrateCheck.needed,
    bitrateInfo: bitrateCheck,
    needsAudioTranscode: audioTranscode,
    audioTracksToKeepIndexes: keepTracks.map((a) => a.index),
    audioTracksToDropIndexes: dropTracks.map((a) => a.index),
    actionRequired: dovi || bitrateCheck.needed || audioTranscode || dropTracks.length > 0,
  };
}

module.exports = {
  COMPATIBLE_AUDIO_CODECS,
  BITRATE_CEILING_MBPS,
  resBucket,
  getDvProfile,
  needsDoviConversion,
  needsBitrateReduction,
  needsAudioTranscode,
  pickAudioTracksToKeep,
  classifyFile,
};
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
node --test scripts/tdarr-quality-remediation-plugin.test.js
```

Expected: PASS, all 11 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/tdarr-quality-remediation-plugin.js scripts/tdarr-quality-remediation-plugin.test.js
git commit -m "Add pure decision logic for Tdarr quality remediation flow"
```

---

### Task 4: Tdarr quality-remediation module — command builders (TDD)

**Files:**
- Modify: `scripts/tdarr-quality-remediation-plugin.js`
- Modify: `scripts/tdarr-quality-remediation-plugin.test.js`

**Interfaces:**
- Consumes: `classifyFile` output shape from Task 3 (`audioTracksToKeepIndexes`, `bitrateInfo.ceiling`).
- Produces: `buildDoviConvertCommands(inputPath, tmpDir)`, `buildDoviRemuxCommand(inputPath, convertedHevcPath, outputPath)`, `buildBitrateReduceCommand(inputPath, outputPath, ceilingMbps)`, `buildAudioTranscodeCommand(inputPath, outputPath)`, `buildAudioPruneCommand(inputPath, outputPath, keepAudioIndexes)` — each returns `{ cmd: string, args: string[] }` or an array of those, never executes anything itself.

- [ ] **Step 1: Write the failing tests**

```javascript
// append to scripts/tdarr-quality-remediation-plugin.test.js
const {
  buildDoviConvertCommands,
  buildDoviRemuxCommand,
  buildBitrateReduceCommand,
  buildAudioTranscodeCommand,
  buildAudioPruneCommand,
} = require('./tdarr-quality-remediation-plugin');

test('buildDoviConvertCommands extracts HEVC then converts RPU with dovi_tool mode 2', () => {
  const cmds = buildDoviConvertCommands('/media/movies/Foo.mkv', '/tmp/foo');
  assert.equal(cmds.length, 2);
  assert.equal(cmds[0].cmd, 'ffmpeg');
  assert.ok(cmds[0].args.includes('-bsf:v'));
  assert.ok(cmds[0].args.includes('hevc_mp4toannexb'));
  assert.equal(cmds[1].cmd, 'dovi_tool');
  assert.deepEqual(cmds[1].args.slice(0, 4), ['-m', '2', 'convert', '--discard']);
});

test('buildDoviRemuxCommand uses mkvmerge to swap in the converted video track', () => {
  const result = buildDoviRemuxCommand('/media/movies/Foo.mkv', '/tmp/foo/bl_rpu81.hevc', '/tmp/foo/Foo.out.mkv');
  assert.equal(result.cmd, 'mkvmerge');
  assert.deepEqual(result.args, ['-o', '/tmp/foo/Foo.out.mkv', '-D', '/media/movies/Foo.mkv', '/tmp/foo/bl_rpu81.hevc']);
});

test('buildBitrateReduceCommand sets QSV hevc_qsv bitrate/maxrate/bufsize from the ceiling', () => {
  const result = buildBitrateReduceCommand('/media/movies/Foo.mkv', '/tmp/foo/Foo.out.mkv', 60);
  assert.equal(result.cmd, 'ffmpeg');
  assert.ok(result.args.includes('hevc_qsv'));
  assert.ok(result.args.includes('60000k'));
  assert.ok(result.args.includes('120000k')); // bufsize = 2x ceiling
});

test('buildAudioTranscodeCommand transcodes to eac3 640k and copies everything else', () => {
  const result = buildAudioTranscodeCommand('/media/movies/Foo.mkv', '/tmp/foo/Foo.out.mkv');
  assert.equal(result.cmd, 'ffmpeg');
  assert.ok(result.args.includes('eac3'));
  assert.ok(result.args.includes('640k'));
  assert.ok(result.args.includes('copy')); // video stream copy
});

test('buildAudioPruneCommand maps only the kept audio stream indexes plus all video/subs', () => {
  const result = buildAudioPruneCommand('/media/movies/Foo.mkv', '/tmp/foo/Foo.out.mkv', [1]);
  assert.equal(result.cmd, 'ffmpeg');
  assert.ok(result.args.includes('0:v'));
  assert.ok(result.args.includes('0:1'));
  assert.equal(result.args.filter((a) => a === '0:2').length, 0);
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
node --test scripts/tdarr-quality-remediation-plugin.test.js
```

Expected: FAIL — the five new `build*` functions are `undefined`.

- [ ] **Step 3: Write the implementation**

```javascript
// append to scripts/tdarr-quality-remediation-plugin.js, add to module.exports below

function buildDoviConvertCommands(inputPath, tmpDir) {
  const rawHevc = `${tmpDir}/bl_el.hevc`;
  const convertedHevc = `${tmpDir}/bl_rpu81.hevc`;
  return [
    {
      cmd: 'ffmpeg',
      args: ['-y', '-i', inputPath, '-map', '0:v:0', '-c:v', 'copy', '-bsf:v', 'hevc_mp4toannexb', '-f', 'hevc', rawHevc],
    },
    {
      cmd: 'dovi_tool',
      args: ['-m', '2', 'convert', '--discard', rawHevc, '-o', convertedHevc],
    },
  ];
}

function buildDoviRemuxCommand(inputPath, convertedHevcPath, outputPath) {
  return { cmd: 'mkvmerge', args: ['-o', outputPath, '-D', inputPath, convertedHevcPath] };
}

function buildBitrateReduceCommand(inputPath, outputPath, ceilingMbps) {
  const kbps = ceilingMbps * 1000;
  return {
    cmd: 'ffmpeg',
    args: [
      '-y', '-hwaccel', 'qsv', '-hwaccel_output_format', 'qsv', '-i', inputPath,
      '-map', '0', '-c:v', 'hevc_qsv', '-b:v', `${kbps}k`, '-maxrate', `${kbps}k`, '-bufsize', `${kbps * 2}k`,
      '-c:a', 'copy', '-c:s', 'copy', outputPath,
    ],
  };
}

function buildAudioTranscodeCommand(inputPath, outputPath) {
  return {
    cmd: 'ffmpeg',
    args: ['-y', '-i', inputPath, '-map', '0', '-c:v', 'copy', '-c:a', 'eac3', '-b:a', '640k', '-c:s', 'copy', outputPath],
  };
}

function buildAudioPruneCommand(inputPath, outputPath, keepAudioIndexes) {
  const args = ['-y', '-i', inputPath, '-map', '0:v', '-map', '0:s?'];
  for (const idx of keepAudioIndexes) {
    args.push('-map', `0:${idx}`);
  }
  args.push('-c', 'copy', outputPath);
  return { cmd: 'ffmpeg', args };
}
```

Add the five new names to the existing `module.exports = { ... }` block.

- [ ] **Step 4: Run tests to verify they pass**

```bash
node --test scripts/tdarr-quality-remediation-plugin.test.js
```

Expected: PASS, all 16 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/tdarr-quality-remediation-plugin.js scripts/tdarr-quality-remediation-plugin.test.js
git commit -m "Add ffmpeg/dovi_tool/mkvmerge command builders for Tdarr remediation flow"
```

---

### Task 5: Verify Tdarr node prerequisites (manual, host-level — flag if blocked)

**Files:** none (verification only; produces findings for Task 7's runbook).

- [ ] **Step 1: Confirm QSV actually works in the Tdarr node's environment**

This must be run by whoever has shell/docker access to the box hosting Tdarr (no SSH path exists via this repo's Ansible inventory — see Current State above). Exact command, confirmed against Tdarr's own hardware-transcoding docs:

```bash
docker exec <tdarr-container-name> bash -c \
  'ffmpeg -hwaccel qsv -f lavfi -i color=c=black:s=256x256:d=1:r=30 -c:v:0 hevc_qsv -f null /dev/null'
```

Expected: ffmpeg runs to completion without a `-hwaccel qsv` initialization error. If it fails, `/dev/dri` isn't passed through to the container — fix by adding `--device=/dev/dri:/dev/dri` (Docker) or the container platform's equivalent device passthrough, then re-run.

- [ ] **Step 2: Confirm `dovi_tool` and `mkvmerge` are available inside the same container**

```bash
docker exec <tdarr-container-name> bash -c 'dovi_tool --version && mkvmerge --version'
```

Expected: both print version strings. If either is missing, install inside the container (or rebuild the image with them baked in — this repo has no Ansible/Docker automation for this host, so document whatever approach is taken in Task 7's runbook rather than scripting it here blind):

```bash
# dovi_tool: download the matching release binary from
# https://github.com/quietvoid/dovi_tool/releases and place it on PATH
# mkvmerge: apt-get install -y mkvtoolnix (Debian/Ubuntu-based images)
```

- [ ] **Step 3: Record the outcome**

Whatever the result of Steps 1-2, write it down (pass/fail + any fix applied) — Task 7's runbook needs this to be accurate about whether the flow can actually run end to end yet.

---

### Task 6: Wire the Tdarr Flow (manual, Tdarr UI — no verified raw Flow-JSON schema to script against)

**Files:** none in this repo (Tdarr's Flow config lives in its own `FlowsJSONDB`, not in git). Task 7 documents this in a runbook.

This task is manual because the exact Flow-graph JSON schema for this Tdarr version was not empirically verified during planning (only the high-level plugin/architecture facts were) — building it blind via the API risks silently-wrong config with no local way to validate it before it runs against real files. The Tdarr web UI's Flow builder is the safe way to construct it.

- [ ] **Step 1: Switch the `Movies` library to Flow mode**

In the Tdarr UI (`https://tdarr.home.mcnees.me`), open Library Settings for `Movies`, and switch it from the classic plugin stack to Flow mode (this is the `pluginStackOverview` toggle confirmed present on the library's settings object during planning). Leave the existing disabled classic plugin stack in place untouched — it's inert once Flow mode is on.

- [ ] **Step 2: Create a new Flow**

Create a Flow named `Movie Quality Remediation`. Add:
1. A "Custom JS Function" node as the entry point. Paste in the full contents of `scripts/tdarr-quality-remediation-plugin.js` (Tasks 3-4) plus a thin wrapper that calls `classifyFile` on `args.inputFileObj.ffProbeData` and `args.inputFileObj.file_size`, and routes to one of two outputs: output 1 = "action required" (`actionRequired === true`), output 2 = "no action" (skip/end).
2. From output 1, chain the four action steps conditionally (DV convert → bitrate reduce → audio transcode → audio prune), each only running the corresponding `build*Command` from Task 4 when `classifyFile`'s matching flag is true, executing via Tdarr's standard "Execute Cli"/custom-command flow node type (each node passes the file along to the next).
3. From output 2, route straight to a "no further processing" / success terminal node.

- [ ] **Step 2 note on execution order:** DV conversion (if needed) must run **before** the bitrate-reduce re-encode, since the bitrate reduce step re-encodes video and the DV RPU conversion is meant to be lossless (stream-copy) — doing it after a re-encode would mean converting RPU data that no longer matches the actual encoded bitstream. Audio transcode and audio prune can run in either order relative to each other but must both run after any video-affecting steps so they operate on the final video track.

- [ ] **Step 2 note on rollout staging vs. the spec:** the design spec's Rollout section suggested landing audio-track pruning library-wide first, as a cheap de-risking step, before adding the heavier DV/bitrate re-encode steps. This plan builds all four steps into one Flow at once instead, because Task 8's spot-check (three sample files covering DV7, DTS-audio, and over-ceiling bitrate, played back on a real Apple TV before the node schedule is enabled) already serves the same de-risking purpose without a separate rollout phase. If the Task 8 spot-check surfaces a problem specific to one step, disable that step's node in the Flow (leave the others active) rather than reverting the whole Flow.

- [ ] **Step 3: Assign the Flow to the `Movies` library and leave the node schedule at all-zero for now**

Don't enable the schedule yet — that's Task 8, after a spot-check.

---

### Task 7: Write the Tdarr runbook

**Files:**
- Create: `docs/runbooks/tdarr.md`

- [ ] **Step 1: Write the runbook**

```markdown
# Tdarr Runbook

## Topology

Tdarr server + a single internal node ("Server") run on a host outside this
repo's Ansible/Kubernetes management — reachable at `10.0.1.1:30028`
(`tdarr.home.mcnees.me` via the Traefik IngressRoute in
`kubernetes/apps/external-services/tdarr.yaml`). That host is not in
`ansible/inventory/hosts.yml`; there's no SSH access path documented anywhere
in this repo. Any host-level change (installing `dovi_tool`/`mkvmerge`,
`/dev/dri` passthrough) has to be done by hand directly on that box.

## Quality Remediation Flow

Library: `Movies` (`/media/movies` → `/media/optimized/movies`), Flow mode,
Flow name `Movie Quality Remediation`. Decision logic and ffmpeg/dovi_tool/
mkvmerge command construction live in
`scripts/tdarr-quality-remediation-plugin.js` in this repo (unit tested via
`node --test scripts/tdarr-quality-remediation-plugin.test.js`) — that file
is the source of truth; the copy pasted into Tdarr's Custom JS Function node
must be kept in sync with it by hand (Tdarr has no way to load a Flow-node
script from an external file or URL).

Rules encoded in that module:
- 4K (width ≥ 3800) bitrate ceiling: 60 Mbps. 1080p (width ≥ 1900): 20 Mbps.
  720p and below: untouched regardless of bitrate.
- Dolby Vision profile 7 → converted to profile 8.1 via `dovi_tool -m 2
  convert --discard` (lossless, drops the enhancement layer). Profiles 5, 8,
  and non-DV files are untouched.
- Audio: if no track is in `aac, ac3, eac3, pcm_s16le, pcm_s24le, flac`
  (i.e. DTS-family only), the primary track is transcoded to EAC3 5.1 @
  640k and the original DTS track is dropped.
- Audio track pruning: keep `eng`-tagged tracks (first track if none are
  tagged `eng`), drop everything else including any track whose title
  contains "commentary".

## Prerequisites checked <DATE Task 5 was actually run>

- QSV hardware encode: <pass/fail, from Task 5 Step 1>
- `dovi_tool` present: <pass/fail>
- `mkvmerge` present: <pass/fail>

## Rollout status

- [ ] Flow built and assigned to `Movies` library (Task 6)
- [ ] Spot-checked in Plex app and Infuse on an actual Apple TV (Task 8)
- [ ] Node schedule enabled for unattended runs (Task 8)
- [ ] Recyclarr side: new `UHD Bluray + WEB` (Radarr) / `WEB-2160p` (Sonarr)
      profiles exist but are not yet the default/assigned profile for new
      4K acquisitions — see
      `kubernetes/apps/recyclarr/configmap.yaml` and the design spec at
      `docs/superpowers/specs/2026-07-12-media-quality-remediation-design.md`
      for why, and reassign manually in the Radarr/Sonarr UI when ready.
```

Fill in the `<...>` fields with the actual results from Task 5 before committing — this is documentation of what was actually done, not a template to ship with placeholders left in.

- [ ] **Step 2: Commit**

```bash
git add docs/runbooks/tdarr.md
git commit -m "Add Tdarr runbook documenting the quality remediation flow"
```

---

### Task 8: Spot-check, then enable the schedule

**Files:** none (verification + a live Tdarr node-config change via API).

- [ ] **Step 1: Run the flow against a small, known-bad sample set first**

In the Tdarr UI, use "Process files now" (or equivalent manual per-file trigger) against three specific files, one per condition, so each code path gets exercised before turning on unattended processing:
- One confirmed DV-profile-7 file (cross-reference `dv_profile` column in the earlier dry-run CSV for a `7`).
- One confirmed DTS-only-audio file (`audio_compatible == False` in the same CSV).
- One confirmed over-ceiling 4K file (`res_bucket == 4k` and `mbps > 60` in the same CSV).

- [ ] **Step 2: Verify playback**

Play all three resulting files in both the Plex app and Infuse on an actual Apple TV. Confirm: video plays (no DV-related black screen/crash), audio is audible with correct language, no unexpected extra audio tracks show up in the track picker.

- [ ] **Step 3: Enable the node schedule**

Once Step 2 passes, turn on processing hours via the API (verify the exact write `mode` — `update` is the most likely value based on Tdarr's CRUD conventions, confirm against the response before trusting it silently):

```bash
curl -s -X POST http://10.0.1.1:30028/api/v2/update-node \
  -H "Content-Type: application/json" \
  -d '{"nodeID": "qh91lZmfr", "nodeUpdates": {"schedule": [ /* set desired hourly transcodecpu/transcodegpu values, e.g. 1 during overnight hours */ ]}}'
```

Confirm via `curl -s http://10.0.1.1:30028/api/v2/get-nodes` that the schedule changed as expected before walking away — this is a single QSV node with no parallelism to fall back on, so watch the first real overnight run's queue depth the next day rather than assuming it worked.

- [ ] **Step 4: Update the runbook rollout checklist**

Check off the completed boxes in `docs/runbooks/tdarr.md`'s "Rollout status" section and commit.

```bash
git add docs/runbooks/tdarr.md
git commit -m "Mark Tdarr quality remediation flow as live"
```
