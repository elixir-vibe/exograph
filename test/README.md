# Exograph test layout

Tests mirror `lib/` by default:

- `lib/exograph/foo.ex` -> `test/exograph/foo_test.exs`
- `lib/exograph/foo/bar.ex` -> `test/exograph/foo/bar_test.exs`

Use the established exceptions only when a test spans a real end-to-end flow:

- `test/features/` for web/API feature tests.
- `test/integration/` for cross-module integration and environment/compile scenarios.
- `test/support/` for ExUnit cases and shared fixtures/helpers.

Do not add new root-level `test/*_test.exs` files. If a test targets a module, put it in the mirrored path under `test/exograph/`.
