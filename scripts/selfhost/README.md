# Self-hosted builds

This public snapshot contains application code, reusable build scripts and
synthetic tests. Machine-specific launch agents, deployment units, operational
records and upstream maintenance instructions remain in the private source.
The `.example` files here are templates; configure paths and endpoints before
using them. They are not installed or enabled by the macOS build.

The `Homelab macOS build` workflow runs script tests and packages an Apple Silicon
DMG and ZIP as a GitHub Actions artifact. A preview builds the selected main
snapshot with a unique prerelease version. It does not create a release, upload
to Forgejo, install the app or deploy a server. Release dispatch remains managed
by the private publisher after its promotion checks.

The built app contains its configured API, WebSocket and update endpoints.
These endpoints are public configuration, not credentials.

## Disabled accounts

Set `MULTICA_DISABLED_USER_IDS` and `MULTICA_DISABLED_USER_EMAILS` in private
server configuration. Both accept comma-separated values with surrounding
whitespace ignored; matching is case-insensitive. A matching ID or email denies
login/session authentication and authenticated realtime access. Empty lists
disable no accounts. Never place real account identifiers in source or tests.

Before deploying a server that switches from an embedded list, migrate its
existing rules into private configuration and verify denial for those accounts.
This export and the desktop build do not perform that production migration.
