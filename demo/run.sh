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
RESET_MINUTES=${RESET_MINUTES:-60}

# no config file while the demo runs, so the settings page is the usual one
# and only DEMO_MODE keeps it from saving. One is only used to build the data.
export CONFIG_FILE=/opt/demo/state/none.yaml
export TRUST_PROXY=${TRUST_PROXY:-true}
export ANONYMIZE_IP=mask
export CLAMAV_HOST=127.0.0.1
export APP_URL=${APP_URL:-http://localhost:3000}

trap 'kill 0' INT TERM

random() {
  node -e 'process.stdout.write(require("crypto").randomBytes(24).toString("base64url"))'
}

# initUser creates the admin while the data is built. A json string is valid
# yaml, so any password survives the trip.
write_init_user() {
  mkdir -p /opt/demo/state
  node -e '
    require("fs").writeFileSync(
      process.argv[1],
      [
        "initUser:",
        "  enabled: true",
        "  username: admin",
        "  email: admin@example.com",
        `  password: ${JSON.stringify(process.env.ADMIN_PASSWORD)}`,
        "  isAdmin: true",
        "",
      ].join("\n"),
      { mode: 0o600 },
    );
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

# the backend only looks for ClamAV once a minute, so it has to be up first.
# Without it shares are simply not scanned.
clamav_up() {
  clamd -c /opt/demo/clamav/clamd.conf &
  for _ in $(seq 50); do
    node -e 'require("net").connect(3310, "127.0.0.1")
      .on("connect", () => process.exit(0))
      .on("error", () => process.exit(1))' && return 0
    sleep 0.2
  done
  echo "ClamAV did not start, shares are not scanned"
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
  export CONFIG_FILE=/opt/demo/state/init.yaml
  write_init_user
  rm -rf "$DATA" && mkdir -p "$DATA"
  (cd "$APP/backend" &&
    ./node_modules/.bin/prisma migrate deploy >/dev/null &&
    node dist/prisma/seed/config.seed.js >/dev/null)
  node /opt/demo/db.mjs settings "$DATA/pingvin-share.db"
  # the seeded shares are scanned like any other
  clamav_up
  # the seed makes a few thousand calls from one address
  export DISABLE_RATE_LIMIT=true
  backend_up
  API_URL="${HEALTH%/health}" node /opt/demo/seed.mjs
  backend_down
  kill %1 2>/dev/null || pkill clamd || true
  rm -rf "$TEMPLATE" && mv "$DATA" "$TEMPLATE"
  rm -f "$CONFIG_FILE"
  exit 0
fi

# Everyone who has the image has the same data, so the admin password and the
# key that signs sessions are replaced before anything is served. Without an
# ADMIN_PASSWORD the admin account gets a password nobody knows.
if [ -z "${ADMIN_PASSWORD:-}" ]; then
  echo "ADMIN_PASSWORD is not set, the admin account stays locked"
  ADMIN_PASSWORD=$(random)
fi
node /opt/demo/db.mjs password "$TEMPLATE/pingvin-share.db" admin "$ADMIN_PASSWORD"
node /opt/demo/db.mjs secret "$TEMPLATE/pingvin-share.db" jwtSecret "$(random)"
unset ADMIN_PASSWORD

# settings, the logo, passwords and accounts cannot be changed from here on
export DEMO_MODE=true

# the proxy, the frontend and the micro ClamAV hold no state, they run for the
# whole container
clamav_up
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
  # every page. The backend reads the banner from the database when it starts.
  DEMO_ADMIN_PASSWORD=$(node -e '
    const c = require("crypto");
    const words = ["lorem", "ipsum", "dolor", "amet", "tempor", "magna", "velit"];
    process.stdout.write(`${words[c.randomInt(words.length)]}-${c.randomInt(1000, 10000)}`);
  ')
  export DEMO_ADMIN_PASSWORD
  node /opt/demo/db.mjs password "$DATA/pingvin-share.db" demoadmin "$DEMO_ADMIN_PASSWORD"
  node /opt/demo/db.mjs settings "$DATA/pingvin-share.db"

  backend_up
  echo "Demo data restored, next reset in $RESET_MINUTES minutes"
  # a backend that crashes is put back right away instead of at the reset
  deadline=$(($(date +%s) + RESET_MINUTES * 60))
  while [ "$(date +%s)" -lt "$deadline" ] && kill -0 "$BACKEND" 2>/dev/null; do
    sleep 5
  done
  backend_down
done
