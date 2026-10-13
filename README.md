# Pingvin Share Vault demo

A public demo of [Pingvin Share Vault](https://github.com/dzaczek/pingvin-share-vault), a self hosted file sharing platform, running on Fly.io at https://pingvin-share-vault-demo.fly.dev.

Everything is reset every 15 minutes. Whatever you upload is gone after that.

## Try it

- Sign in as `demo` with the password `demo1234`, or share files without an account.
- To look around the admin pages, sign in as `demoadmin`. Its password changes at every reset and is shown at the top of every page.
- The demo runs with `DEMO_MODE=true`: settings, the logo, passwords and accounts cannot be changed. Creating users and two factor login still work.
- Nothing is kept. The data is put back when the app starts and at every reset, two factor login included.
- A share can hold at most 1 MB.
- 300 shares with lorem ipsum files are already there. A few of them are protected with the password `demo`.
- The `admin` account is private.

- Upload the [EICAR test file](https://www.eicar.org/download-anti-malware-testfile/) to see the virus scan remove a share.

## Privacy

The demo runs with `ANONYMIZE_IP=mask`, so only the first and the last part of every address is stored, `203.*.*.57` for `203.0.113.57`. The share history and the audit log never see more. All data, logs included, is deleted at every reset.

## Virus scan

A micro ClamAV runs inside the container. It only knows the EICAR test file (`demo/clamav/demo.ndb`), so it uses a few MB of memory and starts at once instead of loading the full signature database. It shows how a share with a malicious file is removed. It does not protect against real malware, which the 1 MB limit and the reset every 15 minutes keep out of reach anyway.

## Costs

The demo is set up so it cannot grow on its own:

- One machine only. Auto start wakes the machines that exist and never creates new ones, and the deploy runs with `--ha=false`.
- `shared-cpu-1x` with 512 MB of memory and 512 MB of swap. The demo uses about 220 MB.
- The machine stops when nobody uses it (`min_machines_running = 0`) and starts again on the next request, in a few seconds.
- No volume and no dedicated IPv4 address.

## How it works

| File | What it does |
|---|---|
| `Dockerfile` | Adds the demo on top of the app image and builds the demo data into the image |
| `demo/settings.yaml` | Demo settings, written into the database. The admin pages show them as usual, `DEMO_MODE` refuses to save a change |
| `demo/db.mjs` | Writes the settings and the passwords into the demo database |
| `demo/run.sh` | `run.sh template` builds the demo data. Without an argument it serves the demo and copies the data back every `RESET_MINUTES` |
| `demo/seed.mjs` | Creates the demo account, a few made up users and the lorem ipsum shares through the API |
| `fly.toml` | The Fly.io app: one small machine, auto stop and auto start |
| `.github/workflows/build.yml` | Builds the app from the `demo` branch, builds the demo on top and deploys it |

Everyone who has the image has the same data. That is why the admin password and the key that signs sessions are replaced every time the container starts.

## Settings

| Name | Where | Default | Meaning |
|---|---|---|---|
| `ADMIN_PASSWORD` | `fly secrets set` | random | Password of the `admin` account. Without it the account is locked |
| `APP_URL` | `fly.toml` | `https://pingvin-share-vault-demo.fly.dev` | Public address of the demo |
| `RESET_MINUTES` | `fly.toml` | `15` | Minutes between two resets |
| `DEMO_SHARES` | build environment | `300` | Number of shares the seed creates |
| `FLY_API_TOKEN` | GitHub secret | none | Deploy token for the app, from `fly tokens create deploy` |

## Run it locally

```bash
podman build -t pingvin-demo .
podman run --rm -p 3000:3000 -e ADMIN_PASSWORD=change-me -e APP_URL=http://localhost:3000 pingvin-demo
```

Then open http://localhost:3000.
