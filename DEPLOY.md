# Deploying Airo

Agent-facing deployment guide. Read top-to-bottom before deploying. Mirrors the
incogito deploy pattern (local prod release → tarball over SSH → systemd).

## TL;DR

```bash
cd ~/airo
bin/deploy.sh
```

Builds a prod release locally, ships it to the VM (SSH alias `airo`), migrates,
and restarts. Exit 0 = success.

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

## What `bin/deploy.sh` does (in order)

1. `mix deps.get --only prod`
2. `MIX_ENV=prod mix deps.compile`
3. `MIX_ENV=prod mix assets.deploy` (tailwind + esbuild, minified + digested)
4. `MIX_ENV=prod mix release --overwrite` → `_build/prod/rel/airo/`
   (picks up `rel/overlays/bin/{server,migrate}`)
5. `tar` the release dir → `airo-<stamp>-<sha>.tar.gz`
6. `scp` to `airo:/tmp/`
7. Over SSH, with passwordless sudo: stop service → extract into `/opt/airo` →
   chown → run `bin/migrate` (`Airo.Release.migrate`) → start service → status
8. Local + remote tarballs cleaned up

Skip migrations: `SKIP_MIGRATE=1 bin/deploy.sh`. Override the target:
`SSH_HOST=other bin/deploy.sh`.

## Verification (after deploy)

```bash
ssh airo 'systemctl is-active airo.service'                                 # active
ssh airo 'journalctl -u airo -n20 --no-pager | grep -E "Running.*Endpoint|Bandit"'
ssh airo 'curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4000/'  # 200/302
```

## Common failure modes

- **`uname -s` not Linux** — build on Linux/WSL; cross-OS releases don't work.
- **`mix release` "elixir version mismatch"** — `mise install` in the repo root.
- **migrate exits with `DATABASE_URL/SECRET_KEY_BASE/CLOAK_KEY is missing`** —
  `/etc/airo.env` unreadable by sudo or incomplete; check
  `ssh airo 'sudo cat /etc/airo.env'`.
- **LiveView socket / `check_origin` rejected** — the endpoint URL host must
  match the public host (`PHX_HOST`).

## Rollback

No built-in rollback. To revert: `git checkout <prev-sha>` then `bin/deploy.sh`.
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
