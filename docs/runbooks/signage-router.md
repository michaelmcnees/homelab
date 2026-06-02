# Signage Router

Rotom currently runs Chromium in kiosk mode against Questboard:

```yaml
signage_url: "https://questboard.home.mcnees.me"
```

The next useful step is to point Rotom at a small internal signage router instead of directly at one app. The router should be a cluster app with a simple ConfigMap-driven page list:

- `Questboard`: `https://questboard.home.mcnees.me`
- `Homey`: `https://homey.home.mcnees.me`
- `Grafana`: a focused dashboard URL, not the full Grafana home page
- `Family Calendar`: a future custom app or calendar view
- `Homepage`: `https://dashboard.home.mcnees.me`

Recommended behavior:

- Fullscreen touch UI with large previous/next controls and a compact page picker.
- Per-device default page, so Rotom can boot to Questboard while other displays could boot elsewhere.
- Optional playlist mode with page duration and active hours.
- Avoid embedding apps that reject iframes; for those, the router should navigate the top-level window instead.
- Keep the router behind the same internal HTTPS/TLS path as other home services.

Operational path:

1. Build `signage-router` as a tiny static or Next.js app in the cluster.
2. Add a ConfigMap for pages and schedules.
3. Change `ansible/inventory/host_vars/rotom.yml` to use the router URL.
4. Keep Questboard as the first/default page until the family calendar and smart-home views exist.
