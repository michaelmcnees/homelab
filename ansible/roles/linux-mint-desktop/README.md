# `linux-mint-desktop` role

Configures baseline maintenance tooling for Linux Mint personal desktops.

The role is intentionally separate from `signage-client`, which owns kiosk
behavior and display-session changes. This role does not modify the active
desktop session, browser settings, game files, or user launchers in its first
pass.

## Variables

| Variable | Default | What |
|---|---|---|
| `linux_mint_desktop_enable_cockpit` | `true` | Include the shared `cockpit` role from the desktop playbook. |
| `linux_mint_desktop_enable_host_monitoring` | `true` | Include the shared `host-monitoring` role from the desktop playbook. |
| `linux_mint_desktop_packages` | baseline admin packages | Packages installed for remote maintenance. |
| `linux_mint_desktop_launchers` | `[]` | Reserved for future managed desktop shortcuts. Must stay empty until launcher tasks exist. |

Future launcher entries should use a structured shape with fields such as
`name`, `desktop_file`, `command`, `icon`, `working_directory`, and
`categories`.
