# `cockpit` role

Installs Cockpit on Debian-family hosts and enables `cockpit.socket`.

Cockpit listens on HTTPS port `9090` with its local self-signed certificate by
default. In Kubernetes, route it through a Traefik `ServersTransport` with
`insecureSkipVerify: true` unless the host gets a trusted local certificate.
