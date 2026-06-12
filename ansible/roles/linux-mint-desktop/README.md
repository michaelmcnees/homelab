# `linux-mint-desktop` role

Configures baseline maintenance tooling for Linux Mint personal desktops.

The role is intentionally separate from `signage-client`, which owns kiosk
behavior and display-session changes. This role does not modify the active
desktop session or browser settings.

The role can also manage DOSBox launchers for the primary desktop user. Game
content lives under `/srv/dos-games` and launchers are rendered into that user's
application menu and, by default, Desktop folder.

## Variables

| Variable | Default | What |
|---|---|---|
| `linux_mint_desktop_enable_cockpit` | `true` | Include the shared `cockpit` role from the desktop playbook. |
| `linux_mint_desktop_enable_host_monitoring` | `true` | Include the shared `host-monitoring` role from the desktop playbook. |
| `linux_mint_desktop_user` | `""` | Primary desktop user that receives managed launchers. |
| `linux_mint_desktop_shared_games_group` | `dosgames` | Shared group for DOS game content. |
| `linux_mint_desktop_dos_games_dir` | `/srv/dos-games` | Shared DOS game content directory. |
| `linux_mint_desktop_packages` | baseline admin packages | Packages installed for remote maintenance. |
| `linux_mint_desktop_launchers` | `[]` | Managed DOSBox desktop/application launchers. |

Launcher entries use this shape:

```yaml
linux_mint_desktop_launchers:
  - name: "Example DOS Game"
    slug: example-dos-game
    command: "/usr/bin/dosbox -conf /srv/dos-games/example-dos-game/dosbox.conf"
    icon: dosbox
    comment: "Launch Example DOS Game in DOSBox"
    categories:
      - Game
      - Emulator
    desktop: true
```

Only `name`, `slug`, and `command` are required. `desktop` defaults to true.

Desktops without Beszel credentials should set `host_monitoring_enable_beszel: false`, as `lucas-minimint` does in host vars.
