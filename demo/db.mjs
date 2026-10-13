// Small writes to the demo database, made while the backend is stopped.
//
//   db.mjs settings <db>                 settings.yaml into the Config table
//   db.mjs password <db> <user> <pass>   a new password for one account
//   db.mjs secret <db> <name> <value>    an internal value, like jwtSecret
//
// The settings live in the database rather than in a config file, so the
// admin pages look like those of any instance. DEMO_MODE refuses to save
// them. APP_URL and DEMO_ADMIN_PASSWORD fill in the placeholders.

import { readFileSync } from "fs";
import { createRequire } from "module";

const require = createRequire("/opt/app/backend/package.json");
const Database = require("better-sqlite3");
const argon = require("argon2");
const { parse } = require("yaml");

const [command, file, ...args] = process.argv.slice(2);
const db = new Database(file);
const setConfig = db.prepare(
  "UPDATE Config SET value = ? WHERE category = ? AND name = ?",
);

if (command === "settings") {
  const text = readFileSync(new URL("settings.yaml", import.meta.url), "utf8")
    .replaceAll("__APP_URL__", process.env.APP_URL ?? "")
    .replaceAll("__DEMO_ADMIN_PASSWORD__", process.env.DEMO_ADMIN_PASSWORD ?? "");
  for (const [category, values] of Object.entries(parse(text)))
    for (const [name, value] of Object.entries(values)) {
      const { changes } = setConfig.run(String(value), category, name);
      // a renamed setting would otherwise just stop applying
      if (!changes) throw new Error(`No setting ${category}.${name}`);
    }
} else if (command === "password") {
  const [username, password] = args;
  db.prepare("UPDATE User SET password = ? WHERE username = ?").run(
    await argon.hash(password),
    username,
  );
} else if (command === "secret") {
  const [name, value] = args;
  setConfig.run(value, "internal", name);
} else {
  throw new Error(`Unknown command ${command}`);
}

db.close();
