# Contributing

## Workflow

1. Create a short-lived branch from `main`: `feature/<topic>` or `fix/<topic>`.
2. Make small, focused commits using [Conventional Commits](https://www.conventionalcommits.org):
   `feat: ...`, `fix: ...`, `docs: ...`, `test: ...`, `chore: ...`, `ci: ...`.
3. Run `make verify` locally. It must pass before you open a pull request.
4. Open a pull request into `main`. CI must be green and one review is required.
5. Merge with "Squash and merge" so history on `main` stays readable.

## Versioning and releases

We use [Semantic Versioning](https://semver.org): `vMAJOR.MINOR.PATCH`.
Releases are made by tagging `main` (for example `git tag v1.2.0`). Record the
change in `CHANGELOG.md`.

## Code style

- Go code must pass `gofmt`, `go vet` and `golangci-lint`.
- Keep functions small and names descriptive. Prefer plain, readable code over clever code.
- Add or update tests for every behaviour change.
