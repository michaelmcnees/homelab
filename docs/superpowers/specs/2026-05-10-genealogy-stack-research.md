# Genealogy Stack Research — 2026-05-10

## Goal

Replace the legacy Gramps container on the old Docker host so the Docker LXC can
be retired. The replacement should be self-hosted, family-friendly, safe for
public exposure behind Traefik, and portable through GEDCOM export.

## Recommendation

Deploy **webtrees** as the primary candidate.

webtrees is web-native, actively maintained, collaborative, GEDCOM-oriented, and
has fine-grained privacy controls for living people and sensitive facts. It fits
the desired user experience better than Gramps Web if the goal is a family
portal rather than a researcher-first Gramps database UI.

No Gramps migration is needed because there is no useful legacy genealogy data.
Keep **Gramps Web** only as a fallback if webtrees proves unpleasant in daily
use.

## Candidates

| Tool | Fit | Notes |
| --- | --- | --- |
| webtrees | Selected | Mature web genealogy app, strong collaboration/privacy model, GEDCOM compatible, works with MariaDB/PostgreSQL/SQLite. Deployed with the maintained `ghcr.io/nathanvaughn/webtrees` image. |
| Gramps Web | Fallback | Best continuity with the existing Gramps data model. More complex runtime and more researcher-oriented. Good if GEDCOM import into webtrees loses too much structure. |
| GeneWeb | Maybe later | Lightweight and self-hostable, but older UX and smaller ecosystem. |
| Genea.app | Not a service replacement | Excellent local-first GEDCOM editor/viewer, but browser/local-file/Git oriented rather than a shared server-side family portal. |
| Geneac | Not ready | Interesting wiki-like direction, but GEDCOM import is still planned rather than ready. |

## Proposed webtrees Shape

- Namespace: `apps` unless it grows into a dedicated `genealogy` namespace.
- Hostname: `family.mcnees.me`.
- Exposure: external Traefik entrypoint with `public-chain`; rely on webtrees
  built-in users/roles/privacy rather than oauth2-proxy.
- Database: `registeel` MariaDB, database/user `webtrees`.
- Storage:
  - PVC for app-local data/cache.
  - NFS-backed media directory if imported records reference many files.
- Initial bring-up:
  1. Create the `webtrees` database and user on `registeel`.
  2. Deploy webtrees empty at `family.mcnees.me`.
  3. Sign in with the bootstrap admin.
  4. Create a fresh tree from the web UI.
  5. Verify public/private visibility for living people before inviting anyone.

## Open Questions

- Do we want family members to self-register, or should accounts be
  admin-created only?
- Should living-person data be private to logged-in family only, or should the
  whole tree require login?
- If this becomes media-heavy, should genealogy media move to a dedicated
  TrueNAS dataset instead of the current local-path PVC?

## Sources

- webtrees features and privacy documentation:
  https://webtrees.net/features/
  https://webtrees.net/user/privacy/
- webtrees server requirements:
  https://webtrees.net/install/requirements/
- Gramps Web install/setup:
  https://www.grampsweb.org/install_setup/setup/
- Gramps Web Docker deployment:
  https://www.grampsweb.org/install_setup/deployment/
- Genea.app:
  https://www.genea.app/
- GeneWeb:
  https://github.com/geneweb/geneweb
