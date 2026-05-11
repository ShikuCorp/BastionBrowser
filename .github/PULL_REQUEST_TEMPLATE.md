## Summary

<!-- One sentence description of the change. -->

## Motivation

<!-- Why is this change needed? Link to a related issue with "Closes #NNN" if applicable. -->

## Changes

<!-- Bullet list of what was changed and why. -->

-

## Testing

<!-- How was this tested? Include the docker run command and RDP client used. -->

- [ ] Built successfully with `docker build -t ghcr.io/shikucorp/bastionbrowser .`
- [ ] Connected via RDP and verified the browser loads the target URL
- [ ] No regressions in existing behaviour

## Checklist

- [ ] `CONTRIBUTING.md` updated if conventions, env vars, or key files changed
- [ ] New env vars documented in `README.md` and `CONTRIBUTING.md`
- [ ] Chromium policy changes use valid [enterprise policy names](https://chromeenterprise.google/policies/)
- [ ] No secrets or credentials included
