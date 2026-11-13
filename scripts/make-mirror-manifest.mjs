// Rewrite a Tauri manifest (latest.json) so every artifact URL points at a
// domestic mirror instead of GitHub Releases. The mirror must serve
// <base>/releases/download/<tag>/<asset> paths copied from this repository's
// public releases.
//
// Usage:
//   # 1) 跟随 latest：改写本地 latest.json（默认行为，向后兼容）
//   node scripts/make-mirror-manifest.mjs <path/to/latest.json> <mirror-base-url>
//
//   # 2) 钉版 feed（P1-5）：从 GitHub release 抓指定 tag 的 manifest 生成
//      企业内网 feed——钉版不跟随 latest，tag 升级必须显式重跑
//   node scripts/make-mirror-manifest.mjs --pin-tag vX.Y.Z <mirror-base-url>
//      等价环境变量：WORKPAW_PIN_TAG=vX.Y.Z
//      离线变体（manifest 已提前下载到本地）：--pin-tag vX.Y.Z --input <file>
//      beta 频道源（抓该 tag 的 beta.json 而非 latest.json）：--channel beta
//
// 输出：
//   默认模式 → latest.mirror.json（与输入同目录）
//   钉版模式 → <tag>.mirror.json（文件名自带 tag，避免被误当 latest 频道用）
//
// 钉版一致性校验：manifest 的 version 字段必须与 --pin-tag 完全一致
//（v 前缀剥离后），不一致即失败——防止把别的版本的 manifest 钉成企业 feed。

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const GITHUB_RELEASE_DOWNLOAD_BASE =
  "https://github.com/rising-biz/workpaw-releases/releases/download";
const TAG_PATTERN = /^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$/;

const HELP = `make-mirror-manifest.mjs — 把 Tauri manifest 的制品 URL 改写为企业内网镜像地址

用法:
  node scripts/make-mirror-manifest.mjs <latest.json> <mirror-base-url>
      跟随 latest 模式：改写本地 manifest，输出 latest.mirror.json

  node scripts/make-mirror-manifest.mjs --pin-tag <tag> [options] <mirror-base-url>
      钉版模式：从 GitHub release 抓指定 tag 的 manifest 生成钉版 feed
      （不跟随 latest；tag 升级必须显式重跑）。输出 <tag>.mirror.json

选项:
  --pin-tag <tag>     钉住的企业 feed 版本 tag（形如 v0.0.25）；也可用环境变量
                      WORKPAW_PIN_TAG 提供
  --input <file>      钉版模式下的本地 manifest 来源（离线场景：先从
                      https://github.com/rising-biz/workpaw-releases/releases/download/<tag>/<latest|beta>.json
                      下载到本地再喂给本脚本）；缺省时从 GitHub 抓取
  --channel <name>    stable（默认，读 latest.json）或 beta（读 beta.json，
                      prerelease 频道）；仅钉版模式有效
  -h, --help          显示本帮助

环境变量:
  WORKPAW_PIN_TAG     等价于 --pin-tag

示例:
  node scripts/make-mirror-manifest.mjs latest.json https://mirror.example.com/workpaw
  node scripts/make-mirror-manifest.mjs --pin-tag v0.0.25 https://mirror.example.com/workpaw
  node scripts/make-mirror-manifest.mjs --pin-tag v0.0.26-beta.1 --channel beta --input beta.json https://mirror.example.com/workpaw
`;

function fail(message) {
  console.error(`错误：${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const parsed = {
    pinTag: process.env.WORKPAW_PIN_TAG ?? "",
    input: "",
    channel: "stable",
    positional: [],
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case "-h":
      case "--help":
        console.log(HELP);
        process.exit(0);
        break;
      case "--pin-tag":
        parsed.pinTag = argv[++i];
        if (parsed.pinTag === undefined) fail("--pin-tag 需要一个 <tag> 参数");
        break;
      case "--input":
        parsed.input = argv[++i];
        if (parsed.input === undefined) fail("--input 需要一个 <file> 参数");
        break;
      case "--channel":
        parsed.channel = argv[++i];
        if (parsed.channel === undefined) fail("--channel 需要一个 <stable|beta> 参数");
        break;
      default:
        if (arg.startsWith("-") && arg !== "-") fail(`无法识别的参数：${arg}（--help 查看用法）`);
        parsed.positional.push(arg);
    }
  }
  return parsed;
}

function parseBase(baseArg) {
  if (!baseArg) fail("缺少 <mirror-base-url> 参数（--help 查看用法）");
  let base;
  try {
    base = new URL(baseArg);
  } catch {
    fail(`mirror base 不是合法 URL：${baseArg}`);
  }
  if (base.protocol !== "https:") fail(`mirror base 必须使用 https：${baseArg}`);
  return base.href.replace(/\/$/u, "");
}

async function fetchManifestFromRelease(tag, channel) {
  const file = channel === "beta" ? "beta.json" : "latest.json";
  const url = `${GITHUB_RELEASE_DOWNLOAD_BASE}/${tag}/${file}`;
  let response;
  try {
    response = await fetch(url, { redirect: "follow" });
  } catch (error) {
    fail(`抓取 ${url} 失败（${error.message}）。` +
      "网络不可达时可用离线变体：先把该 manifest 下载到本地，再以 --input <file> 传入。");
  }
  if (!response.ok) {
    fail(`抓取 ${url} 得到 HTTP ${response.status}。` +
      `确认该 release 已发布且资产里有 ${file}；404 多半是 tag 写错或该版本未产出 ${file}（stable 版本不产出 beta.json）。`);
  }
  const text = await response.text();
  try {
    return JSON.parse(text);
  } catch (error) {
    fail(`${url} 不是合法 JSON：${error.message}`);
  }
}

function loadManifestFile(path) {
  try {
    return JSON.parse(readFileSync(resolve(path), "utf8"));
  } catch (error) {
    fail(`读取/解析 ${path} 失败：${error.message}`);
  }
}

function rewriteManifest(manifest, baseHref) {
  const platforms = manifest.platforms ?? {};
  const rewritten = {};
  for (const [platform, entry] of Object.entries(platforms)) {
    const url = typeof entry?.url === "string" ? entry.url : "";
    if (!url.startsWith(`${GITHUB_RELEASE_DOWNLOAD_BASE}/`)) {
      fail(`platform ${platform} 的 url 不是本仓 release 的静态下载地址：${url || "<missing>"}`);
    }
    rewritten[platform] = {
      ...entry,
      url: `${baseHref}/releases/download${url.slice(GITHUB_RELEASE_DOWNLOAD_BASE.length)}`,
    };
  }
  return { ...manifest, platforms: rewritten };
}

const args = parseArgs(process.argv.slice(2));
const pinMode = args.pinTag !== "";

if (args.channel !== "stable" && args.channel !== "beta") {
  fail(`--channel 只支持 stable | beta（当前：${args.channel}）`);
}
if (args.channel === "beta" && !pinMode) {
  fail("--channel beta 仅在 --pin-tag 钉版模式下有效（本地文件模式请直接喂 beta.json 路径）");
}
// 位置参数：<mirror-base-url> 恒为最后一个；默认模式下还有第 1 个位置参数
// <latest.json>。钉版模式若给了 --input，manifest 走选项，不允许再给位置参数。
let manifestPathArg = "";
if (!pinMode) {
  if (args.positional.length < 2) {
    fail("本地文件模式需要两个位置参数：<latest.json> <mirror-base-url>（--help 查看用法）");
  }
  if (args.positional.length > 2) {
    fail(`无法识别的参数：${args.positional.slice(2).join(" ")}`);
  }
  manifestPathArg = args.positional[0];
} else if (args.positional.length !== 1) {
  fail(args.positional.length === 0
    ? "缺少 <mirror-base-url> 参数（--help 查看用法）"
    : `钉版模式只接受一个位置参数 <mirror-base-url>，多出：${args.positional.slice(1).join(" ")}`);
}
const baseHref = parseBase(args.positional[args.positional.length - 1]);

let manifest;
let outputPath;

if (pinMode) {
  const tag = args.pinTag;
  if (!TAG_PATTERN.test(tag)) {
    fail(`--pin-tag 须形如 vX.Y.Z[-prerelease]（当前：${tag}）`);
  }
  const version = tag.slice(1);
  if (args.input) {
    manifest = loadManifestFile(args.input);
    console.log(`钉版模式（离线）：源 manifest 读自 ${resolve(args.input)}`);
  } else {
    console.log(`钉版模式：抓取 ${GITHUB_RELEASE_DOWNLOAD_BASE}/${tag}/${args.channel === "beta" ? "beta.json" : "latest.json"} …`);
    manifest = await fetchManifestFromRelease(tag, args.channel);
  }
  // 钉版一致性：manifest 版本必须与 tag 一致，防止把别的版本钉成企业 feed
  if (manifest.version !== version) {
    fail(`钉版一致性校验失败：manifest.version=${manifest.version} 与 --pin-tag=${tag} 不一致。` +
      "确认下载/抓取的是该 tag 自己的 manifest。");
  }
  outputPath = join(process.cwd(), `${tag}.mirror.json`);
} else {
  manifest = loadManifestFile(manifestPathArg);
  outputPath = join(dirname(resolve(manifestPathArg)), "latest.mirror.json");
}

const output = rewriteManifest(manifest, baseHref);
writeFileSync(outputPath, `${JSON.stringify(output, null, 2)}\n`);
console.log(`Wrote ${outputPath}`);
console.log(
  `All ${Object.keys(output.platforms).length} platform URLs point at ${baseHref}/releases/download/...`,
);
if (pinMode) {
  console.log(
    `Pinned feed: ${args.pinTag}（channel=${args.channel}）。企业端 WORKPAW_UPDATE_ENDPOINT 指向本文件即可；` +
    "升级钉版必须显式重跑本脚本，不跟随 latest。",
  );
}
