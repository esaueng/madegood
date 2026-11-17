# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Report it privately through GitHub: open the repository's **Security** tab and choose
**Report a vulnerability**, or go straight to
[the private report form](https://github.com/esaueng/madegood/security/advisories/new).
Only the maintainers can see the report. Include what you found, how to reproduce it,
and what an attacker could do with it.

We aim to acknowledge reports within 3 working days and to agree on a fix and
disclosure date with you in the private advisory. We credit reporters in the advisory
and release notes unless you ask us not to.

## Scope

- The iPhone and Apple Watch apps.
- The website and API at madegood.app (one Cloudflare Worker).
- The code in this repository, including the self-hosting setup.

Of particular interest: access to another person's sessions, tracks, or location
(including bypassing privacy zones or visibility settings), authentication and
token handling, and data that survives account deletion.

## Out of scope

- Findings that need a jailbroken device or physical access to an unlocked device.
- Denial of service through traffic volume.
- Reports from automated scanners without a demonstrated impact.
- Self-hosted copies run by other people; report those to their operators.

## Supported versions

Only the latest App Store release and the current `main` branch receive fixes.
