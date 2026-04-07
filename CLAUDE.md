# CLAUDE.md

Project context for AI assistants working on this codebase.

## What this project is

NixOS module and Nix package for [OpenZiti](https://openziti.io), a programmable zero-trust networking platform. The flake provides:

- A Nix package that builds the `ziti` CLI binary from source via `buildGoModule`
- NixOS modules for three components: **controller**, **router**, and **tunnel**
- A NixOS VM integration test that validates the controller starts with auto-generated PKI

The `ziti` source is fetched from GitHub (pinned to a release tag), not vendored locally. The `ziti/` directory in the repo is a leftover clone and is not used by the flake.

## Project structure

```
flake.nix                      — Flake entry point (packages, nixosModules, checks, devShells)
flake.lock                     — Pinned nixpkgs input
nix/
  package.nix                  — buildGoModule derivation for ziti v1.6.14
  modules/
    controller.nix             — services.openziti.controller NixOS module
    router.nix                 — services.openziti.router NixOS module
    tunnel.nix                 — services.openziti.tunnel NixOS module
  tests/
    default.nix                — NixOS VM test (controller with PKI + DB auto-init)
```

## Key commands

```bash
nix build .#ziti                                          # Build the ziti binary
./result/bin/ziti version                                  # Verify version (v1.6.14)
nix flake show                                             # Show all flake outputs
nix flake check                                            # Evaluate + run checks
nix build .#checks.x86_64-linux.controller-router-test     # Run the VM integration test
nix develop                                                # Enter dev shell with go + ziti
```

## Architecture decisions

- **Single binary**: OpenZiti ships one `ziti` binary for all components (controller, router, tunnel, pki, edge CLI). No separate derivations needed.
- **Module pattern**: Each NixOS module is a function `flake: { config, lib, pkgs, ... }:` where `flake` is the self reference, passed via `import ./nix/modules/foo.nix self` in flake.nix. This lets each module default `package` to the flake's own `ziti` derivation.
- **Config generation**: Modules use `pkgs.formats.yaml {}` to convert a Nix attrset (`settings`) to YAML. A `configFile` escape hatch lets users pass a raw YAML path instead.
- **Secrets by path**: Passwords (`adminPasswordFile`) and JWT tokens (`enrollment.tokenFile`) are always referenced as file paths — never stored in the Nix store. Compatible with sops-nix, agenix, etc.
- **PKI auto-generation**: The controller module's `preStart` script calls `ziti pki create {ca,intermediate,server,client}` commands. It is idempotent (checks for existing cert files before creating). Server cert generation also creates its own key — do NOT add a separate `ziti pki create key` step (causes "bundle already exists" conflicts).
- **systemd hardening**: Services run as dedicated system users with `ProtectHome`, `ProtectSystem=strict`, `NoNewPrivileges`, `PrivateTmp`. The router gets `CAP_NET_ADMIN` when `tunnelerMode = "tproxy"`.

## Updating the ziti version

1. Change `version` in `nix/package.nix`
2. Update `src.hash`: run `nix-prefetch-url --unpack https://github.com/openziti/ziti/archive/refs/tags/v<NEW>.tar.gz`, convert with `nix hash convert --hash-algo sha256 --to sri <hash>`
3. Set `vendorHash = lib.fakeHash;` temporarily
4. Run `nix build .#ziti` — it will fail and print the correct `vendorHash`
5. Replace the hash with the real one
6. Rebuild and run the test
7. Check the upstream go.mod module path — v1.x uses `github.com/openziti/ziti`, v2.x uses `github.com/openziti/ziti/v2` (the ldflags `-X` path must match)

## Gotchas

- The `ziti/` directory has its own `.git` — git treats it as a nested repo. Nix flakes can't see files inside it. That's why the package uses `fetchFromGitHub` instead of local source.
- `mkPackageOption` doesn't work here because `ziti` isn't in nixpkgs. The modules use plain `lib.mkOption { type = lib.types.package; }` instead.
- The VM test takes ~3–4 minutes. PKI generation + DB init happen in the systemd `preStart` script, so the service startup is slow on first boot.
- `ziti pki create server` generates its own private key. Don't call `ziti pki create key` separately for the same name — it creates conflicting bundles.
- `vendorHash` will change whenever Go dependencies change. Always re-derive it when bumping versions.

## Upstream references

- OpenZiti repo: https://github.com/openziti/ziti
- Controller config schema: `ziti/etc/ctrl.with.edge.yml` in the upstream repo
- Router config schema: `ziti/etc/edge.router.yml` in the upstream repo
- Systemd units upstream models: `ziti/dist/dist-packages/linux/openziti-{controller,router}/`
- PKI bootstrap logic: `ziti/dist/dist-packages/linux/openziti-controller/bootstrap.bash`

## Not yet implemented

- HA/Raft cluster orchestration
- Certificate renewal timer (systemd timer for periodic `ziti pki create server --allow-overwrite`)
- Web console bundling
- Let's Encrypt integration (`ziti pki lets-encrypt`)
- The separate `ziti-edge-tunnel` C binary (different upstream repo: openziti/ziti-edge-tunnel)
