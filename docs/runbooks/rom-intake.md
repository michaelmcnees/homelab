# ROM Intake

This runbook covers the practical workflow for building the shared RomM and Batocera library from physical games we own.

## Storage Layout

TrueNAS is the source of truth:

```text
/mnt/data/media/library/games/
  import/
  roms/
  bios/
  _batocera/
```

RomM mounts the same root at `/romm/library`. Batocera boxes should use the existing TrueNAS SMB share:

- ROMs: `//truenas/media/library/games/roms`
- BIOS: `//truenas/media/library/games/bios`

Use `import/` as the landing zone for fresh dumps or replacement backup files. Only move files into `roms/<platform>` or `bios/<platform>` after naming, format, and hash checks are done.

## Platform Paths

| Platform | Library path | Preferred format |
| --- | --- | --- |
| NES | `roms/nes` | `.nes` |
| SNES | `roms/snes` | `.sfc` or `.smc` |
| Nintendo 64 | `roms/n64` | `.z64` |
| Game Boy | `roms/gb` | `.gb` |
| Game Boy Color | `roms/gbc` | `.gbc` |
| Game Boy Advance | `roms/gba` | `.gba` |
| Nintendo DS | `roms/nds` | `.nds` |
| Genesis / Mega Drive | `roms/genesis` or `roms/megadrive` | `.md`, `.gen`, or `.bin` |
| Master System | `roms/mastersystem` | `.sms` |
| Game Gear | `roms/gamegear` | `.gg` |
| PlayStation 1 | `roms/psx` | `.chd`; keep `.cue/.bin` only as staging |
| PlayStation 2 | `roms/ps2` | `.chd`; `.iso` only when compatibility requires it |
| PSP | `roms/psp` | `.chd`, `.cso`, or `.iso` |
| Dreamcast | `roms/dreamcast` | `.chd` |
| GameCube | `roms/gamecube` | `.rvz` |
| Wii | `roms/wii` | `.rvz` |
| Arcade | `roms/mame` or `roms/fbneo` | version-matched zipped ROM sets |
| ScummVM | `roms/scummvm` | game directory plus `.scummvm` marker |
| DOS / PC ports | `roms/ports` or Batocera's DOS-specific path if split later | game directory |

Avoid mixing emulator set families. `mame` and `fbneo` should stay separate because they expect different DATs and set versions.

## Intake Workflow

1. Put new files in `import/<source-or-date>/`.
2. Confirm the file belongs to a game we own.
3. Normalize archive/extraction state:
   - Cartridge systems: one ROM file per game, unzipped unless the emulator explicitly expects zip.
   - Disc systems: preserve the raw dump until conversion is verified.
   - Arcade: keep the expected zipped set shape.
4. Verify against the appropriate preservation DAT:
   - No-Intro for cartridge and handheld systems.
   - Redump for disc systems.
   - MAME or FBNeo DATs for arcade.
5. Convert bulky disc formats:
   - PS1, PS2, Saturn, Dreamcast, PSP: prefer `.chd` when compatible.
   - GameCube and Wii: prefer `.rvz`.
6. Rename to a clean canonical title, keeping region/version where useful:
   - `Game Title (USA).ext`
   - `Game Title (USA) (Rev 1).ext`
   - `Game Title (Japan) (Translated En).ext`
7. Move the file into the platform folder under `roms/`.
8. Place BIOS files under `bios/<platform>` and run Batocera's BIOS checker.
9. Trigger a RomM library scan and scrape metadata from Batocera after batches land.
10. Update `docs/reference/batocera-collection-checklist.md` as games are completed.

## Verification Tools

Recommended tools to install on a workstation or temporary utility container:

- `igir`: DAT-driven ROM manager for No-Intro, Redump, MAME, and FBNeo sets.
- `chdman`: converts `.cue/.bin`, `.gdi`, and `.iso` disc dumps to `.chd`.
- Dolphin: converts GameCube/Wii images to `.rvz`.
- `sha1sum`, `md5sum`, or `shasum`: quick manual checksum checks.
- RomM: library-level visibility, metadata, and duplicate review after import.
- Batocera BIOS checker: final runtime check for BIOS placement.

Keep DAT files outside the ROM library, for example:

```text
/mnt/data/media/library/games/_batocera/dats/
  no-intro/
  redump/
  mame/
  fbneo/
```

## Source Guidance

Cleanest source order:

1. Dump our own physical cartridge or disc.
2. Use digital purchases for PC/DOS and adventure titles where available through GOG, Steam, or ScummVM-supported freeware releases.
3. For backup images sourced elsewhere, verify against No-Intro, Redump, MAME, or FBNeo before adding them to the library.

Do not treat random archive names as trustworthy. If a file cannot be verified, leave it in `import/unverified/` until it can be checked or replaced.

## BIOS Handling

BIOS files are not interchangeable between every emulator/core. Keep them organized by platform:

```text
bios/
  gba/
  psx/
  ps2/
  psp/
  dreamcast/
  gamecube/
  wii/
  nds/
  3ds/
  arcade/
  mame/
  fbneo/
```

After adding BIOS files:

1. Reboot or refresh the Batocera client if needed.
2. Run Batocera's BIOS checker.
3. Leave notes in `_batocera/bios-notes.md` for any emulator-specific filename quirks.

## Batch Order

Follow the checklist's recommended gathering order, but process in small batches:

1. SNES, GBA, and DOS edutainment.
2. Pokemon GB/GBC/GBA/DS.
3. N64 and PS1.
4. NES and Genesis.
5. GameCube and Wii.
6. Atari and arcade showcase.
7. PSP and DS.
8. Dreamcast, Saturn, and TurboGrafx.
9. PS2 last, curated tightly.

Each batch should end with:

- DAT verification complete.
- Batocera launches at least one game from the batch.
- RomM scan sees the files.
- Checklist boxes updated.

