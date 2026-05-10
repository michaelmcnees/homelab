# Genealogy Stack Research — 2026-05-10

## Goal

Replace the legacy Gramps container on the old Docker host so the Docker LXC can
be retired. The replacement should be self-hosted, family-friendly, safe for
public exposure behind Traefik, and portable through GEDCOM export.

## Recommendation

Start with **webtrees** as the primary candidate.

webtrees is web-native, actively maintained, collaborative, GEDCOM-oriented, and
has fine-grained privacy controls for living people and sensitive facts. It fits
the desired user experience better than Gramps Web if the goal is a family
portal rather than a researcher-first Gramps database UI.

Keep **Gramps Web** as the fallback if the existing Gramps tree has import
details that do not survive GEDCOM export/import cleanly.

## Candidates

| Tool | Fit | Notes |
| --- | --- | --- |
| webtrees | Primary candidate | Mature web genealogy app, strong collaboration/privacy model, GEDCOM compatible, works with MariaDB/PostgreSQL/SQLite. Official distribution is a PHP app; Docker images are community-maintained, so we may build our own image or pin a maintained community image. |
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
- Migration:
  1. Export GEDCOM from the existing Gramps instance.
  2. Copy media/artifacts from the Gramps Docker volume.
  3. Deploy webtrees empty.
  4. Import GEDCOM.
  5. Verify people count, family count, media links, privacy behavior, and a few
     known relationships.
  6. Keep the Gramps export and Docker volume backup until webtrees has been
     used successfully for a confidence window.

## Open Questions

- Do we want family members to self-register, or should accounts be
  admin-created only?
- Should living-person data be private to logged-in family only, or should the
  whole tree require login?
- Where should genealogy media live long-term: a dedicated TrueNAS dataset or a
  K8s PVC backed by Ceph VM disks?

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
