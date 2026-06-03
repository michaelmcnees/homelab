# `signage-client` role

Configures a Debian-family host as a single-purpose browser kiosk for household
signage. The role is intended for small x86 clients such as the Dell Optiplex
Micro paired with a touch monitor.

## What it installs

- Chromium
- Xorg + `xinit`
- Openbox
- `unclutter`
- A dedicated `signage` user
- A `signage-kiosk.service` systemd unit that owns `tty1`

## Variables

| Variable | Default | What |
|---|---|---|
| `signage_url` | `about:blank` | URL opened by Chromium in kiosk mode. |
| `signage_user` | `signage` | Local unprivileged user that runs Xorg/Chromium. |
| `signage_extra_chromium_flags` | `[]` | Additional Chromium flags appended to the default kiosk flags. |
| `signage_disable_sleep` | `true` | Masks sleep targets and writes logind idle policy. |
| `signage_wait_for_url` | `true` | Waits for HTTP(S) `signage_url` to return before launching Chromium. |
| `signage_url_check_interval_sec` | `10` | Seconds between URL readiness checks. |
| `signage_url_check_timeout_sec` | `10` | Per-request URL readiness timeout. |
| `signage_enable_host_monitoring` | `false` | Includes the existing `host-monitoring` role when true. |
| `signage_enable_cockpit` | `false` | Includes the `cockpit` role when true. |

## Operating notes

The role does not install Tailscale or create the administrative SSH user. Do
that during Debian installation or with a separate bootstrap step.

The kiosk session is deliberately URL-driven. Point `signage_url` at Questboard,
Home Assistant, Grafana, Anthias, or a future in-cluster signage router without
changing the client role.
