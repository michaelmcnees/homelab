# Lucas DOSBox Launcher Design

## Goal

Extend the Linux Mint desktop Ansible role so it can manage DOSBox game launchers for Lucas's desktop session without making `mmcnees` the visible desktop user.

## User Model

`mmcnees` remains the administrative SSH and Ansible account on `lucas-minimint`.
Lucas's primary desktop account is `lmcnees`, with home directory `/home/lmcnees`.
Shortcut files should be installed for `lmcnees`, not for `mmcnees`.

## Storage Model

DOS game content should live in a shared system location:

- Directory: `/srv/dos-games`
- Group: `dosgames`
- Members: `lmcnees`, `mmcnees`
- Mode: group-writable with setgid (`2775`) so new content remains shared.

Each game should have its own subdirectory under `/srv/dos-games/<game-slug>/`.
Ansible should create the base directory but should not upload or invent game
content in this pass.

## Launcher Model

The role should accept structured launcher entries and render `.desktop` files
into Lucas's application launcher directory:

- Application launcher path: `/home/lmcnees/.local/share/applications`
- Optional desktop icon path: `/home/lmcnees/Desktop`
- Owner/group: `lmcnees`
- Mode: executable user desktop entry (`0755`)

Launcher entries should support:

- `name`: visible launcher name.
- `slug`: stable file and folder slug.
- `command`: full command to run, such as `/usr/bin/dosbox -conf /srv/dos-games/example/dosbox.conf`.
- `icon`: optional icon path or icon name.
- `comment`: optional desktop-entry comment.
- `categories`: optional desktop categories.
- `desktop`: boolean, default `true`, to also place a copy on Lucas's Desktop.

The role should not require launchers to exist. An empty launcher list is valid.

## Safety

The role should validate required desktop variables before mutating the host. It
should not touch Lucas's browser settings, login session, existing desktop files,
or game content outside managed launcher files and `/srv/dos-games`.
