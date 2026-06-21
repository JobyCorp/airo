# Deploying Airo

Agent-facing deployment guide. Read top-to-bottom before deploying. Mirrors the
incogito deploy pattern (prod release → tarball over SSH → systemd).

## TL;DR

```bash
cd ~/airo
bin/deploy-docker.sh
```

Builds a prod release **inside an `ubuntu:24.04` container** (so it links the
VM's glibc), ships it to the VM (SSH alias `airo`), migrates, and restarts.
Exit 0 = success.

### Which script? (read this — it has bitten us)

- **`bin/deploy-docker.sh` — use this.** The local dev host runs Ubuntu 26.04
  (**glibc 2.43**); the VM runs Ubuntu 24.04 (**glibc 2.39**). A release built
  natively bundles an ERTS + native NIFs (ortex, tokenizers) linked against
  glibc 2.43 — `beam.smp` then dies on the VM with
  `libm.so.6: version GLIBC_2.43 not found` and the service won't boot.
  Building inside `ubuntu:24.04` makes ERTS and every NIF link glibc 2.39,
  matching the target. The builder image (`bin/docker-build/Dockerfile`)
  mirrors the VM toolchain: mise `erlang 28.5` + `elixir 1.19.5-otp-28`,
  `node 24` (for the `vega-embed` perf-chart deps), and rustup stable (ortex).
- **`bin/deploy.sh` — only safe when the build host's glibc ≤ the VM's** (2.39).
  Once your laptop is on a newer glibc, this produces releases that can't boot
  on the VM. Kept for that case and for reference.

**Caution:** both scripts `systemctl stop` the service and overwrite `/opt/airo`
*before* migrating, with no rollback. If the build is broken, fix it locally
**before** running — a failed run leaves prod down (there is no backup of the
prior release).

### deploy-docker.sh flags

```bash
bin/deploy-docker.sh                  # build + ship + migrate + restart
SKIP_MIGRATE=1 bin/deploy-docker.sh   # skip the migration step
SSH_HOST=other bin/deploy-docker.sh   # override the SSH alias
REBUILD_IMAGE=1 bin/deploy-docker.sh  # force-rebuild the builder image
```

Rebuild the image (`REBUILD_IMAGE=1`) whenever you change the toolchain in
`bin/docker-build/Dockerfile` — the script otherwise reuses the cached image
and your toolchain change silently won't apply.

## Architecture

Airo is **private to the LAN — no public tunnel.** It runs as a Mix release
under systemd on the VM reached by the SSH alias **`airo`**.

- Release at `/opt/airo/`, run by systemd unit `airo.service`
  (`/opt/airo/bin/server`), which sets `PHX_SERVER=true` and binds Bandit to
  `PORT` (4000) on all interfaces.
- Runtime env from `/etc/airo.env` (0640, root:airo).
- Postgres `airo_prod` (role `airo`) on `127.0.0.1:5432`, reached via
  `DATABASE_URL` (scram password) in that env file.
- **Traefik** terminates TLS at **`https://airo.local.joby.gg`** and forwards to
  the app at **`192.168.68.74:4000`** (plain HTTP). It sets
  `X-Forwarded-Proto: https`, which `config/prod.exs`'s
  `force_ssl: [rewrite_on: [:x_forwarded_proto]]` trusts — so the app stays HTTP
  behind the proxy without redirect loops. (Hitting `192.168.68.74:4000`
  directly over HTTP will redirect to https; reach it via the hostname.)

The release bundles ERTS, so the VM needs no Erlang/Elixir installed.

## Admin is unauthenticated (LAN-only by design)

`/v1/*` (the OpenAI-compatible gateway + realtime) is client-key authenticated,
but **`/admin/*` (providers, deployments, aliases, keys, usage) has no auth.**
That's acceptable here only because Airo is private to the LAN. **Do not expose
Airo to the public internet** (a tunnel, a port-forward) without first gating
`/admin` (a proxy auth layer) or adding auth to the admin pipeline.

## Prerequisites (verify before deploying)

1. **You're on Linux.** The release binary must match the VM target
   (Linux x86_64). `bin/deploy.sh` enforces `uname -s == Linux`.
2. **SSH alias `airo` works** and allows passwordless sudo:
   `ssh airo true` exits 0; `ssh airo sudo -n true` exits 0.
3. **`mise`/`.tool-versions` runtimes match the VM** (Erlang/Elixir/OTP).
4. **`/etc/airo.env`** exists (0640, root:airo) with at least:
   - `PHX_SERVER=true`
   - `PHX_HOST=<airo's public host>`
   - `PORT=4000`
   - `DATABASE_URL=ecto://USER:PASS@HOST/airo_prod`
   - `SECRET_KEY_BASE` (generate: `mix phx.gen.secret`)
   - `CLOAK_KEY` (base64 32-byte AES-GCM key — encrypts provider credentials;
     generate: `mix run -e 'IO.puts(32 |> :crypto.strong_rand_bytes() |> Base.encode64())'`).
     **Rotating `CLOAK_KEY` invalidates every Cloak-encrypted column** — rotate
     with care.

   `config/runtime.exs` raises on a missing `DATABASE_URL`, `SECRET_KEY_BASE`,
   or `CLOAK_KEY`, so the migrate step will fail loudly if the env file is
   incomplete or unreadable by sudo.

## What `bin/deploy-docker.sh` does (in order)

1. Builds the cached builder image from `bin/docker-build/Dockerfile` if it's
   missing (or `REBUILD_IMAGE=1`). First build compiles OTP from source — slow;
   reused after that.
2. `git archive HEAD` → a clean source tree (no host `_build`/`deps`, which are
   glibc-2.43). **The build is exactly committed `HEAD` — commit before you
   deploy, or your change won't ship.**
3. In the container (`MIX_ENV=prod`): `mix deps.get --only prod` →
   `mix deps.compile` → `npm --prefix assets ci` → `mix assets.deploy`
   (compile + tailwind + esbuild, minified + digested) → `mix release --overwrite`
   → `tar` the release → `_out_/airo-<stamp>-<sha>.tar.gz`.
4. `scp` the tarball to `airo:/tmp/`.
5. Over SSH, with passwordless sudo: stop service → extract into `/opt/airo` →
   chown → run `bin/migrate` (`Airo.Release.migrate`) → start service → status.
6. Local temp dirs + remote tarball cleaned up.

`bin/deploy.sh` (the non-container path) is the same pipeline minus the
container and the `npm ci` step, building natively into `_build/prod/`.

Two build steps that are easy to miss and have broken deploys before:
- **`npm --prefix assets ci`** — `assets/package.json` pulls `vega-embed`
  (perf chart); without `node_modules`, esbuild fails to resolve it.
- **`compile` is the first step of the `assets.deploy` mix alias** — it
  generates Phoenix's `phoenix-colocated/airo` hooks dir that esbuild imports.
  Don't remove it.

## Verification (after deploy)

```bash
ssh airo 'systemctl is-active airo.service'                                 # active
ssh airo 'journalctl -u airo -n20 --no-pager | grep -E "Running.*Endpoint|Bandit"'
ssh airo 'curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4000/'  # 200/302
```

## Common failure modes

- **`beam.smp: libm.so.6: version 'GLIBC_2.43' not found`** on the VM at the
  migrate/start step — you built natively (`bin/deploy.sh`) on a host with a
  newer glibc than the VM. Use `bin/deploy-docker.sh`. Note the failed run
  already stopped the service, so **prod is down until a good release lands** —
  re-run `bin/deploy-docker.sh`.
- **esbuild `Could not resolve "vega-embed"`** — `npm ci` didn't run in
  `assets/` (or Node is missing from the builder image; `REBUILD_IMAGE=1`).
- **esbuild `Could not resolve "phoenix-colocated/airo"`** — `compile` isn't
  running before esbuild; check the `assets.deploy` alias in `mix.exs`.
- **builder image `mise: not found` / toolchain not on PATH** — the Dockerfile
  needs `/root/.local/bin` on `PATH` and a `mise reshim` after `mise install`.
- **toolchain change in the Dockerfile didn't take effect** — the script
  reuses the cached image; re-run with `REBUILD_IMAGE=1`.
- **`uname -s` not Linux** (`bin/deploy.sh` only) — build on Linux/WSL.
- **`mix release` "elixir version mismatch"** — `mise install` in the repo root.
- **migrate exits with `DATABASE_URL/SECRET_KEY_BASE/CLOAK_KEY is missing`** —
  `/etc/airo.env` unreadable by sudo or incomplete; check
  `ssh airo 'sudo cat /etc/airo.env'`.
- **LiveView socket / `check_origin` rejected** — the endpoint URL host must
  match the public host (`PHX_HOST`).

## Rollback

No built-in rollback, and the deploy keeps no backup of the prior release. To
revert: `git checkout <prev-sha>` then `bin/deploy-docker.sh`.
For a migration rollback, on the VM:

```bash
ssh airo 'sudo -u airo env $(sudo grep -v "^#" /etc/airo.env | xargs -d "\n") \
  /opt/airo/bin/airo eval "Airo.Release.rollback(Airo.Repo, <version>)"'
```

## What you must NOT do

- Don't edit `/opt/airo/` directly on the VM — always deploy a tarball.
- Don't run `mix ecto.migrate` against `airo_prod` from your laptop — migrate
  through `bin/migrate` on the VM so the release env is loaded.
- Don't commit `*.env`, `*.tar.gz`, or `_build/`.
