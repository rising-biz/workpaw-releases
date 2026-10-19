// Rewrite a Tauri latest.json so every artifact URL points at a domestic
// mirror instead of GitHub Releases. The mirror must serve
// <base>/releases/download/<tag>/<asset> paths copied from this repository's
// public releases.
//
// Usage:
//   node scripts/make-mirror-manifest.mjs <path/to/latest.json> <mirror-base-url>
//
// Writes latest.mirror.json next to the input file.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const GITHUB_PREFIX = "https://github.com/rising-biz/workpaw-releases/releases/download";

const [manifestPath, baseArg] = process.argv.slice(2);
if (!manifestPath || !baseArg) {
  console.error("usage: node scripts/make-mirror-manifest.mjs <latest.json> <mirror-base-url>");
  process.exit(1);
}

let base;
try {
  base = new URL(baseArg);
} catch {
  console.error(`mirror base is not a valid URL: ${baseArg}`);
  process.exit(1);
}
if (base.protocol !== "https:") {
  console.error("mirror base must use https");
  process.exit(1);
}
const baseHref = base.href.replace(/\/$/u, "");

const manifest = JSON.parse(readFileSync(resolve(manifestPath), "utf8"));
const platforms = manifest.platforms ?? {};
const rewritten = {};

for (const [platform, entry] of Object.entries(platforms)) {
  const url = typeof entry?.url === "string" ? entry.url : "";
  if (!url.startsWith(`${GITHUB_PREFIX}/`)) {
    console.error(`platform ${platform} url is not a static release download URL: ${url || "<missing>"}`);
    process.exit(1);
  }
  rewritten[platform] = {
    ...entry,
    url: `${baseHref}/releases/download${url.slice(GITHUB_PREFIX.length)}`,
  };
}

const output = { ...manifest, platforms: rewritten };
const outputPath = join(dirname(resolve(manifestPath)), "latest.mirror.json");
writeFileSync(outputPath, `${JSON.stringify(output, null, 2)}\n`);
console.log(`Wrote ${outputPath}`);
console.log(`All ${Object.keys(rewritten).length} platform URLs point at ${baseHref}/releases/download/...`);
