# SottoKey Agent Guide

Follow [AGENTS.md](AGENTS.md). Read [docs/PLAN.md](docs/PLAN.md), [PRIVACY.md](PRIVACY.md),
and [SECURITY.md](SECURITY.md) before changing product behavior.

## Skill routing

When the request matches an installed gstack skill, use it.

- Product ideas and scope: `office-hours` or `plan-ceo-review`
- Architecture: `plan-eng-review`
- UI and interaction: `design-consultation` or `plan-design-review`
- Full plan pipeline: `autoplan`
- Bugs: `investigate`
- QA: `qa` or `qa-only`
- Review: `review`
- Release: `ship`
- GBrain: `setup-gbrain` and `sync-gbrain`
