// Load license keys from LICENSE_KEYS.txt into the Supabase `licenses` table.
//
// Idempotent: existing keys are ignored (so already-sold/activated rows are NOT
// reset). Run from the repo root after creating the schema, and again after
// `python gen_licenses.py --add N`:
//
//   SUPABASE_URL=https://<project>.supabase.co \
//   SUPABASE_SERVICE_ROLE_KEY=<service_role secret> \
//   node landing/seed_supabase.mjs
//
// Get the service_role key from Supabase -> Project Settings -> API.

import fs from "node:fs";

const URL_ = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const FILE = process.argv[2] || "LICENSE_KEYS.txt";

if (!URL_ || !KEY) {
    console.error("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY env vars first.");
    process.exit(1);
}

const text = fs.readFileSync(FILE, "utf8");
const keys = [...text.matchAll(/HT-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}/g)].map((m) => m[0]);
if (keys.length === 0) { console.error(`No keys found in ${FILE}`); process.exit(1); }

const rows = keys.map((key) => ({ key }));
const base = URL_.replace(/\/$/, "");

const r = await fetch(`${base}/rest/v1/licenses?on_conflict=key`, {
    method: "POST",
    headers: {
        apikey: KEY,
        Authorization: `Bearer ${KEY}`,
        "Content-Type": "application/json",
        Prefer: "resolution=ignore-duplicates,return=representation",
    },
    body: JSON.stringify(rows),
});

if (!r.ok) { console.error(`Seed failed: ${r.status} ${await r.text()}`); process.exit(1); }
const inserted = await r.json();
console.log(`Sent ${keys.length} key(s) from ${FILE}; ${inserted.length} newly inserted (duplicates ignored).`);
