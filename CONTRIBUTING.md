# Contributing to Tidewake

Thank you for helping build Tidewake. The project is intentionally small and values changes that are easy to understand, test, and operate.

## Before you start

Open an issue for changes that alter public behavior, data modeling, delivery semantics, or architecture. Small documentation and maintenance fixes can go directly to a pull request.

Do not include credentials, production data, real webhook secrets, or copied code from Ironhold.

## Development setup

Use the versions in .tool-versions, then run:

    docker compose up -d db
    mix setup
    mix phx.server

The application is available at http://localhost:4000.

## Design principles

- Prefer explicit names and small functions.
- Add abstractions only when real behavior needs them.
- Keep contexts focused on business responsibilities.
- Use pattern matching where it makes control flow clearer.
- Avoid generic Helpers, Utils, Services, and Repositories modules.
- Do not introduce distributed infrastructure before the workload requires it.
- Do not present planned capabilities as implemented.

## Tests and quality

Add or update ExUnit tests for behavioral changes. Before opening a pull request, run:

    mix precommit

The equivalent individual commands are:

    mix compile --warnings-as-errors
    mix deps.unlock --check-unused
    mix format --check-formatted
    mix credo --strict
    mix sobelow
    mix test

When a check cannot run, describe the exact command and reason in the pull request.

## Database changes

Generate migrations with:

    mix ecto.gen.migration descriptive_name

Keep migrations reversible. Do not add future domain tables until a vertical slice needs them.

## Commits

Use Conventional Commits with a concise scope:

- feat: introduces user-visible behavior
- fix: corrects broken behavior
- docs: changes documentation only
- test: adds or changes tests
- refactor: changes structure without behavior
- chore: changes tooling or maintenance
- ci: changes continuous integration

Each commit should represent one coherent purpose.

## Pull requests

Use the repository template. Explain what changed, why it changed, and how it was verified. Keep pull requests focused and do not merge with failing or unexecuted required checks.
