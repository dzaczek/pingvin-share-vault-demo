#!/bin/sh
# Runs the public demo.
#
#   run.sh template   builds the demo data, once, while the image is built
#   run.sh            serves the demo and copies that data back every
#                     RESET_MINUTES, so nothing a visitor uploads stays long
#
# Building the data takes a minute or two. Doing it in the image means a
# machine that was stopped for being idle is back in a few seconds.
set -eu

APP=/opt/app
DATA=$APP/backend/data
TEMPLATE=/opt/demo/template
HEALTH=http://localhost:${BACKEND_PORT:-8080}/api/health
RESET_MINUTES=${RESET_MINUTES:-10}

export CONFIG_FILE=/opt/demo/state/config.yaml
export TRUST_PROXY=${TRUST_PROXY:-true}
export ANONYMIZE_IP=true
export APP_URL=${APP_URL:-http://localhost:3000}

trap 'kill 0' INT TERM

random() {
  node -e 'process.stdout.write(require("crypto").randomBytes(24).toString("base64url"))'
}

# initUser creates the admin when the data is built. A json string is valid
# yaml, so any password survives the trip.
write_config() {
  mkdir -p /opt/demo/state
  node -e '
    const fs = require("fs");
    let yaml = fs
      .readFileSync("/opt/demo/config.yaml", "utf8")
      .replace("__APP_URL__", JSON.stringify(process.env.APP_URL))
      .replace("__DEMO_ADMIN_PASSWORD__", process.env.DEMO_ADMIN_PASSWORD ?? "");
    if (process.env.ADMIN_PASSWORD)
      yaml += [
        "initUser:",
        "  enabled: true",
        "  username: admin",
        "  email: admin@example.com",
        `  password: ${JSON.stringify(process.env.ADMIN_PASSWORD)}`,
        "  isAdmin: true",
        "",
      ].join("\n");
    fs.writeFileSync(process.argv[1], yaml, { mode: 0o600 });
  ' "$CONFIG_FILE"
}

backend_up() {
  (cd "$APP/backend" && exec node dist/src/main) &
  BACKEND=$!
  until curl -fs "$HEALTH" >/dev/null 2>&1; do
    kill -0 "$BACKEND" 2>/dev/null || { echo "The backend did not start"; exit 1; }
    sleep 1
  done
}

backend_down() {
  kill "$BACKEND" 2>/dev/null || true
  wait "$BACKEND" 2>/dev/null || true
}

if [ "${1:-}" = "template" ]; then
  # this admin password only lives for the build, the real one is set when
  # the container starts
  ADMIN_PASSWORD=$(random)
  export ADMIN_PASSWORD
  write_config
  rm -rf "$DATA" && mkdir -p "$DATA"
  (cd "$APP/backend" &&
    ./node_modules/.bin/prisma migrate deploy >/dev/null &&
    node dist/prisma/seed/config.seed.js >/dev/null)
  # the seed makes a few thousand calls from one address
  export DISABLE_RATE_LIMIT=true
  backend_up
  API_URL="${HEALTH%/health}" node /opt/demo/seed.mjs
  backend_down
  rm -rf "$TEMPLATE" && mv "$DATA" "$TEMPLATE"
  rm -f "$CONFIG_FILE"
  exit 0
fi

# Sets one column of the demo database, a password is hashed first. Run from
# the backend folder, where better-sqlite3 and argon2 are installed.
db_set() {
  (cd "$APP/backend" && node -e '
    const Database = require("better-sqlite3");
    const argon = require("argon2");
    const [file, what, key, value] = process.argv.slice(1);
    (async () => {
      const db = new Database(file);
      if (what === "password")
        db.prepare("UPDATE User SET password = ? WHERE username = ?").run(
          await argon.hash(value),
          key,
        );
      else
        db.prepare(
          "UPDATE Config SET value = ? WHERE category = ? AND name = ?",
        ).run(value, "internal", key);
      db.close();
    })();
  ' "$@")
}

# Everyone who has the image has the same data, so the admin password and the
# key that signs sessions are replaced before anything is served. Without an
# ADMIN_PASSWORD the admin account gets a password nobody knows.
if [ -z "${ADMIN_PASSWORD:-}" ]; then
  echo "ADMIN_PASSWORD is not set, the admin account stays locked"
  ADMIN_PASSWORD=$(random)
fi
db_set "$TEMPLATE/pingvin-share.db" password admin "$ADMIN_PASSWORD"
db_set "$TEMPLATE/pingvin-share.db" config jwtSecret "$(random)"
unset ADMIN_PASSWORD

# settings, the logo, passwords and accounts cannot be changed from here on
export DEMO_MODE=true

# the proxy and the frontend hold no state, they run for the whole container
cp -rn /tmp/img/* "$APP/frontend/public/img" 2>/dev/null || true
if [ "$TRUST_PROXY" = "true" ]; then
  caddy start --adapter caddyfile --config "$APP/reverse-proxy/Caddyfile.trust-proxy"
else
  caddy start --adapter caddyfile --config "$APP/reverse-proxy/Caddyfile"
fi
(cd "$APP/frontend" && PORT=3333 HOSTNAME=0.0.0.0 exec node server.js) &

while true; do
  # the folder itself belongs to root, only what is in it can go
  find "$DATA" -mindepth 1 -delete && cp -a "$TEMPLATE/." "$DATA/"

  # the public admin gets a new password at every reset, shown at the top of
  # every page. The backend reads the banner from the config when it starts.
  DEMO_ADMIN_PASSWORD=$(node -e '
    const c = require("crypto");
    const words = ["lorem", "ipsum", "dolor", "amet", "tempor", "magna", "velit"];
    process.stdout.write(`${words[c.randomInt(words.length)]}-${c.randomInt(1000, 10000)}`);
  ')
  export DEMO_ADMIN_PASSWORD
  db_set "$DATA/pingvin-share.db" password demoadmin "$DEMO_ADMIN_PASSWORD"
  write_config

  backend_up
  echo "Demo data restored, next reset in $RESET_MINUTES minutes"
  # a backend that crashes is put back right away instead of at the reset
  deadline=$(($(date +%s) + RESET_MINUTES * 60))
  while [ "$(date +%s)" -lt "$deadline" ] && kill -0 "$BACKEND" 2>/dev/null; do
    sleep 5
  done
  backend_down
done
