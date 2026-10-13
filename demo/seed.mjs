// Fills a fresh demo instance through its own API: the demo account, a few
// made up users and a few hundred shares of lorem ipsum files. run.sh calls
// it once per container start, the result is copied back on every reset.

const API = process.env.API_URL ?? "http://localhost:8080/api";
const SHARES = Number(process.env.DEMO_SHARES ?? 300);
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD;

const WORDS = (
  "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod " +
  "tempor incididunt ut labore et dolore magna aliqua enim ad minim veniam " +
  "quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo " +
  "consequat duis aute irure in reprehenderit voluptate velit esse cillum " +
  "fugiat nulla pariatur excepteur sint occaecat cupidatat non proident sunt " +
  "culpa qui officia deserunt mollit anim id est laborum"
).split(" ");

// a fixed seed, so every container start builds the same demo
let state = 20261013;
const rand = () => {
  state = (state * 1103515245 + 12345) % 2 ** 31;
  return state / 2 ** 31;
};
const pick = (list) => list[Math.floor(rand() * list.length)];
const between = (min, max) => min + Math.floor(rand() * (max - min + 1));
const capitalize = (s) => s[0].toUpperCase() + s.slice(1);
const words = (n) => Array.from({ length: n }, () => pick(WORDS)).join(" ");
const sentence = () => `${capitalize(words(between(6, 14)))}.`;
const paragraph = () =>
  Array.from({ length: between(3, 7) }, sentence).join(" ");

const FILES = [
  (title) => ({
    name: `${title}.txt`,
    content: Array.from({ length: between(2, 8) }, paragraph).join("\n\n"),
  }),
  (title) => ({
    name: `${title}.md`,
    content: [
      `# ${capitalize(words(3))}`,
      paragraph(),
      `## ${capitalize(words(2))}`,
      ...Array.from({ length: between(3, 6) }, () => `- ${sentence()}`),
      paragraph(),
    ].join("\n\n"),
  }),
  (title) => ({
    name: `${title}.csv`,
    content: [
      "id,name,amount,status",
      ...Array.from(
        { length: between(10, 80) },
        (_, i) =>
          `${i + 1},${capitalize(words(2))},${between(1, 9999)},${pick(["open", "done", "late"])}`,
      ),
    ].join("\n"),
  }),
  (title) => ({
    name: `${title}.json`,
    content: JSON.stringify(
      Array.from({ length: between(3, 12) }, (_, i) => ({
        id: i + 1,
        title: capitalize(words(3)),
        body: sentence(),
      })),
      null,
      2,
    ),
  }),
];

// one cookie jar per actor, anonymous ones included: the api keeps who
// created a share in cookies
const actor = () => {
  const jar = new Map();
  const call = async (path, { method = "GET", json, body, type } = {}) => {
    const res = await fetch(`${API}${path}`, {
      method,
      headers: {
        cookie: [...jar].map(([k, v]) => `${k}=${v}`).join("; "),
        ...(json ? { "content-type": "application/json" } : {}),
        ...(type ? { "content-type": type } : {}),
      },
      body: json ? JSON.stringify(json) : body,
    });
    for (const cookie of res.headers.getSetCookie()) {
      const [pair] = cookie.split(";");
      const at = pair.indexOf("=");
      jar.set(pair.slice(0, at), pair.slice(at + 1));
    }
    if (!res.ok)
      throw new Error(`${method} ${path}: ${res.status} ${await res.text()}`);
    return res;
  };
  return { call };
};

const signedIn = async (username, password) => {
  const a = actor();
  await a.call("/auth/signIn", { method: "POST", json: { username, password } });
  return a;
};

const createShare = async (a, n) => {
  const title = words(between(2, 3)).replace(/ /g, "-");
  const id = `demo-${String(n).padStart(3, "0")}-${pick(WORDS)}`;
  const security = {};
  if (n % 17 === 0) security.password = "demo";
  if (n % 11 === 0) security.maxViews = between(5, 50);

  await a.call("/shares", {
    method: "POST",
    json: {
      id,
      name: capitalize(words(between(2, 4))).slice(0, 30),
      description: rand() < 0.6 ? sentence().slice(0, 512) : undefined,
      expiration: rand() < 0.8 ? "never" : pick(["1-year", "6-months"]),
      recipients: [],
      security,
    },
  });

  for (let i = 0; i < between(1, 4); i++) {
    const file = pick(FILES)(i ? `${title}-${i + 1}` : title);
    await a.call(
      `/shares/${id}/files?name=${encodeURIComponent(file.name)}&chunkIndex=0&totalChunks=1`,
      { method: "POST", body: file.content, type: "application/octet-stream" },
    );
  }
  await a.call(`/shares/${id}/complete`, { method: "POST" });
  return { id, password: security.password };
};

// a few visits, so the access log of a share is not empty
const visit = async ({ id, password }) => {
  const a = actor();
  await a.call(`/shares/${id}/token`, {
    method: "POST",
    json: password ? { password } : {},
  });
  await a.call(`/shares/${id}`);
};

const main = async () => {
  if (!ADMIN_PASSWORD) throw new Error("ADMIN_PASSWORD is not set");
  const admin = await signedIn("admin", ADMIN_PASSWORD);

  const users = [
    { username: "demo", password: "demo1234" },
    ...["alice", "bob", "carol", "dave", "erin"].map((username) => ({
      username,
      password: crypto.randomUUID(),
    })),
  ];
  // a public admin, so visitors can look around the admin pages. Settings
  // are locked by the config file and the reset undoes everything else.
  const accounts = [...users, { username: "demoadmin", password: "demo1234" }];
  for (const user of accounts)
    await admin.call("/users", {
      method: "POST",
      json: {
        ...user,
        email: `${user.username}@example.com`,
        isAdmin: user.username === "demoadmin",
        isActivated: true,
      },
    });

  const owners = await Promise.all(
    users.map((u) => signedIn(u.username, u.password)),
  );
  const [demo, ...others] = owners;

  let created = 0;
  for (let n = 1; n <= SHARES; n++) {
    // a fifth belongs to the demo account, some have no owner at all
    const owner = n % 5 === 0 ? demo : n % 7 === 0 ? actor() : pick(others);
    const share = await createShare(owner, n);
    if (rand() < 0.3) await visit(share);
    created++;
  }
  console.log(`Seeded ${accounts.length} users and ${created} shares`);
};

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
