#!/usr/bin/env node
// WorkPaw 发版仪式编排器（P1-4）：把「四步手工发版仪式」收敛成一条带校验的
// 命令，每步有明确的成功判据与失败补救提示，杜绝「Keygate 登记漏步静默成功」。
//
// 步骤（顺序固定，失败即停）：
//   1. local-version  校验本地 WORKPAW_VERSION / --tag 一致（离线）
//   2. keygate        提示并校验 Keygate 登记可达：GET 更新端点 manifest，
//                     version 必须等于本版本；404/不匹配即停，提示先完成
//                     「注册 Keygate」仪式步（网络）
//   3. mirror         调用 official-site/scripts/mirror-installers.sh（复用其
//                     stdout 末行 MIRRORED=<tag> 协议判定成功）（网络+上传）
//   4. cos-assets     校验 COS 安装包就位：HEAD downloads.json 工单里的全部
//                     资产 + manifest.tsv（网络）
//   5. dispatch-hints 输出 gh workflow dispatch 命令清单（deploy-official-site /
//                     build-server-images）——只打印给操作员，绝不自动触发
//
// 选项：
//   --tag vX.Y.Z       本次要发布的 tag（或用环境变量 WORKPAW_TAG）
//   --dry-run          干跑：联网步骤（2/3/4）只打印将执行的动作，不外呼；
//                      离线步骤（1/5）正常执行
//   --skip=<list>      跳过步骤，逗号分隔，可用序号（1-5）或名称
//                      （local-version,keygate,mirror,cos-assets,dispatch-hints）；
//                      跳过会在 stdout 打印显式警告，风险自担
//   -h, --help         帮助
//
// 环境变量：
//   WORKPAW_VERSION    期望版本号（不含 v 前缀）；与 --tag 互相校验
//   WORKPAW_TAG        等价 --tag
//   KEYGATE_UPDATE_URL Keygate 更新端点完整 URL（如
//                      https://keygate.example.com/api/v1/releases/workpaw-desktop/upgrade.json）；
//                      缺失时第 2 步失败并给出补救提示
//   COS_PUBLIC_BASE    COS 公开基址（默认官网桶广州地域）
//   RCLONE_CONFIG_COS_ACCESS_KEY_ID / RCLONE_CONFIG_COS_SECRET_ACCESS_KEY
//                      第 3 步 mirror-installers.sh 必需（与 deploy-official-site
//                      工作流同款变量名）；缺失时提前失败，不进入长搬运
//
// 位置：仓库 scripts/（与 make-mirror-manifest.mjs 同级）。运行机：国内
// 仪式机（需 bash 5+/curl/rclone/python3 与国内网络）。无第三方依赖。

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const MIRROR_SCRIPT = join(REPO_ROOT, "official-site", "scripts", "mirror-installers.sh");
const DOWNLOADS_JSON = join(REPO_ROOT, "official-site", "data", "downloads.json");
const COS_PUBLIC_BASE = (process.env.COS_PUBLIC_BASE ?? "https://workpaw-1253566621.cos.ap-guangzhou.myqcloud.com").replace(/\/$/, "");
const TAG_PATTERN = /^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$/;

const STEPS = [
  { no: 1, name: "local-version", offline: true },
  { no: 2, name: "keygate", offline: false },
  { no: 3, name: "mirror", offline: false },
  { no: 4, name: "cos-assets", offline: false },
  { no: 5, name: "dispatch-hints", offline: true },
];

const HELP = `release-orchestrate.mjs — WorkPaw 发版仪式编排器

用法:
  node scripts/release-orchestrate.mjs --tag v0.0.26 [options]

选项:
  --tag <tag>      本次要发布的 tag（形如 v0.0.26）；也可用环境变量 WORKPAW_TAG
  --dry-run        干跑：联网步骤（2 keygate / 3 mirror / 4 cos-assets）只打印
                   将执行的动作，不外呼；离线步骤（1/5）正常执行
  --skip=<list>    跳过步骤（逗号分隔序号或名称，如 --skip=2 或
                   --skip=keygate,cos-assets）；显式警告后跳过，漏步风险自担
  -h, --help       帮助

步骤:
  1. local-version  校验 WORKPAW_VERSION / --tag 一致（离线）
  2. keygate        校验 Keygate 更新端点登记的 version == 本版本（网络）
  3. mirror         运行 mirror-installers.sh 镜像 10 件安装包到 COS（网络+上传）
  4. cos-assets     HEAD 复点 COS 关键资产（网络）
  5. dispatch-hints 打印 gh workflow dispatch 命令清单（不自动触发）
`;

function fail(stepLabel, message, remediation = "") {
  console.error(`\n✗ [${stepLabel}] ${message}`);
  if (remediation) console.error(`  补救：${remediation}`);
  process.exit(1);
}

function parseArgs(argv) {
  const parsed = { tag: process.env.WORKPAW_TAG ?? "", dryRun: false, skip: new Set() };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "-h" || arg === "--help") {
      console.log(HELP);
      process.exit(0);
    } else if (arg === "--dry-run") {
      parsed.dryRun = true;
    } else if (arg === "--tag") {
      parsed.tag = argv[++i];
      if (parsed.tag === undefined) fail("参数", "--tag 需要一个 <tag> 参数");
    } else if (arg.startsWith("--skip=")) {
      const raw = arg.slice("--skip=".length);
      if (!raw) fail("参数", "--skip= 需要步骤列表，如 --skip=2 或 --skip=keygate,cos-assets");
      for (const item of raw.split(",")) {
        const key = item.trim();
        const byNo = STEPS.find((s) => String(s.no) === key);
        const byName = STEPS.find((s) => s.name === key);
        if (!byNo && !byName) {
          fail("参数", `--skip 里的「${key}」不是有效步骤（可用：${STEPS.map((s) => `${s.no}=${s.name}`).join(", ")}）`);
        }
        parsed.skip.add((byNo ?? byName).name);
      }
    } else {
      fail("参数", `无法识别的参数：${arg}（--help 查看用法）`);
    }
  }
  return parsed;
}

async function fetchJson(url, timeoutMs = 30000) {
  const response = await fetch(url, { signal: AbortSignal.timeout(timeoutMs), redirect: "follow" });
  if (!response.ok) {
    const error = new Error(`HTTP ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return response.json();
}

function checkKeygate(tag, version) {
  const url = process.env.KEYGATE_UPDATE_URL ?? "";
  if (!url) {
    fail("2 keygate", "未配置 KEYGATE_UPDATE_URL（Keygate 更新端点完整 URL）。",
      "先完成「注册 Keygate」仪式步：在 Keygate 登记本 Release 的 Tauri manifest（upgrade.json），" +
      "然后以 KEYGATE_UPDATE_URL=https://<keygate>/api/v1/releases/<product>/upgrade.json 重跑；" +
      "若确要跳过，用 --skip=2 显式承担漏步风险。");
  }
  console.log(`==> GET ${url}`);
  return fetchJson(url)
    .then((manifest) => {
      const remote = typeof manifest?.version === "string" ? manifest.version : "";
      if (remote !== version) {
        fail("2 keygate", `Keygate 更新端点登记的 version=${remote || "<missing>"} 与本版本 ${version}（${tag}）不一致。`,
          "先完成「注册 Keygate」仪式步：在 Keygate 登记本 Release 的 manifest 与更新包后再重跑；" +
          "若确要跳过，用 --skip=2 显式承担漏步风险。");
      }
      console.log(`    Keygate 登记可达且版本一致（${remote}）。`);
    })
    .catch((error) => {
      if (error?.status === 404) {
        fail("2 keygate", "Keygate 更新端点 404：本版本尚未登记。",
          "先完成「注册 Keygate」仪式步（登记 latest/upgrade manifest 与更新包）后再重跑；" +
          "若确要跳过，用 --skip=2 显式承担漏步风险。");
      }
      fail("2 keygate", `Keygate 更新端点不可达：${error.message}`,
        "检查 KEYGATE_UPDATE_URL 与仪式机网络；确认 Keygate 登记步已完成。");
    });
}

function runMirror(tag) {
  if (!existsSync(MIRROR_SCRIPT)) {
    fail("3 mirror", `找不到 ${MIRROR_SCRIPT}`);
  }
  for (const name of ["RCLONE_CONFIG_COS_ACCESS_KEY_ID", "RCLONE_CONFIG_COS_SECRET_ACCESS_KEY"]) {
    if (!process.env[name]) {
      fail("3 mirror", `环境缺少 ${name}（与 deploy-official-site 工作流同款变量名）。`,
        "在国内仪式机导出 RCLONE_CONFIG_COS_* 后重跑；不要把密钥写进任何文件。");
    }
  }
  console.log(`==> bash ${MIRROR_SCRIPT} ${tag}（stderr 直通，stdout 末行应为 MIRRORED=${tag}）`);
  const result = spawnSync("bash", [MIRROR_SCRIPT, tag], {
    stdio: ["inherit", "pipe", "inherit"],
    env: process.env,
  });
  if (result.error) {
    fail("3 mirror", `无法启动 mirror-installers.sh：${result.error.message}`);
  }
  if (result.status !== 0) {
    fail("3 mirror", `mirror-installers.sh 退出码 ${result.status}（见上方 stderr）。`,
      "按 stderr 指示处理后重跑；断点续传可直接重跑本脚本。");
  }
  const stdout = (result.stdout ?? "").toString();
  const lines = stdout.split("\n").map((line) => line.trim()).filter(Boolean);
  const last = lines.at(-1) ?? "";
  if (!last.startsWith("MIRRORED=")) {
    fail("3 mirror", `mirror-installers.sh stdout 末行不是 MIRRORED=<tag>，得到：「${last || "<empty>"}」。`,
      "确认运行的是本仓官方脚本（stdout 末行协议未被改动）。");
  }
  const mirroredTag = last.slice("MIRRORED=".length);
  if (mirroredTag !== tag) {
    fail("3 mirror", `MIRRORED=${mirroredTag} 与本次发布 ${tag} 不一致。`,
      "用 --tag 显式指定与镜像一致的本版本，或排查是否有并发发版。");
  }
  console.log(`    安装包镜像完成：MIRRORED=${mirroredTag}（10 件安装包 + manifest.tsv 已就位 COS）。`);
}

function loadWorkOrder(tag) {
  if (!existsSync(DOWNLOADS_JSON)) {
    fail("4 cos-assets", `找不到 ${DOWNLOADS_JSON}（工单事实源）。`,
      "先跑第 3 步（mirror-installers.sh 会刷新该工单），或手动跑 official-site/scripts/build-data.sh。");
  }
  let data;
  try {
    data = JSON.parse(readFileSync(DOWNLOADS_JSON, "utf8"));
  } catch (error) {
    fail("4 cos-assets", `工单 ${DOWNLOADS_JSON} 不是合法 JSON：${error.message}`);
  }
  if (data.tag !== tag) {
    console.error(`警告：工单 ${DOWNLOADS_JSON} 的 tag=${data.tag} 与本次发布 ${tag} 不一致——` +
      "以本次 --tag 为准逐件 HEAD 复点；若第 3 步已跑，工单应已被刷新，不一致属异常。");
  }
  const assets = [];
  for (const platform of data.platforms ?? []) {
    for (const file of platform.files ?? []) {
      if (file?.name) assets.push(file.name);
    }
  }
  assets.push("manifest.tsv");
  return assets;
}

async function head(url) {
  try {
    const response = await fetch(url, { method: "HEAD", signal: AbortSignal.timeout(30000), redirect: "follow" });
    return { ok: response.ok, status: response.status };
  } catch (error) {
    return { ok: false, status: error.message };
  }
}

async function checkCosAssets(tag) {
  const assets = loadWorkOrder(tag);
  console.log(`==> HEAD 复点 ${COS_PUBLIC_BASE}/download/${tag}/（${assets.length} 个关键对象）…`);
  const missing = [];
  for (const name of assets) {
    const url = `${COS_PUBLIC_BASE}/download/${encodeURIComponent(tag)}/${name}`;
    const result = await head(url);
    if (result.ok) {
      console.log(`    200 ${name}`);
    } else {
      console.error(`    ✗ ${name} → ${result.status}`);
      missing.push(name);
    }
  }
  if (missing.length > 0) {
    fail("4 cos-assets", `COS 关键资产缺失/不可达（${missing.length} 件）：${missing.join("、")}`,
      "重跑第 3 步（mirror-installers.sh 幂等、可断点续传）后再复点。");
  }
  console.log(`    COS 关键资产齐备（${assets.length} 件，含 manifest.tsv）。`);
}

function printDispatchHints(tag, version, dryRun) {
  const repo = "rising-biz/workpaw-releases";
  console.log("==> 发版收尾（本脚本不自动触发任何工作流，以下命令由操作员审阅后手动执行）：");
  console.log("");
  console.log("  # 1) 发布官网页面（安装包已在 COS 就位，页面为元数据渲染，秒级）");
  console.log(`  gh workflow run deploy-official-site -R ${repo} --ref main`);
  console.log("");
  console.log("  # 2) 服务器镜像（admin/admin-console/web/operator，amd64+arm64）；");
  console.log("  #    镜像推送目标与凭据见 desktop-releases Environment，命名空间迁移清单见 README");
  console.log(`  gh workflow run build-server-images.yml -R ${repo} --ref main -f version=${version}`);
  console.log("");
  if (tag.includes("-")) {
    console.log(`  # 本版本 ${tag} 为 prerelease：桌面端已额外产出 beta.json（beta 频道），`);
    console.log("  # GitHub releases/latest 仍指向最新正式版，stable 频道不受影响。");
    console.log("");
  }
  if (dryRun) {
    console.log("  （dry-run：以上命令仅打印，未触发。）");
  }
}

const args = parseArgs(process.argv.slice(2));
const tag = args.tag;
if (!tag) {
  fail("参数", "缺少 --tag vX.Y.Z（或环境变量 WORKPAW_TAG）。");
}
if (!TAG_PATTERN.test(tag)) {
  fail("参数", `--tag 须形如 vX.Y.Z[-prerelease]（当前：${tag}）。`);
}
const version = tag.slice(1);

console.log("WorkPaw 发版仪式编排器");
console.log(`  tag: ${tag} · version: ${version} · mode: ${args.dryRun ? "DRY-RUN" : "LIVE"}` +
  (args.skip.size ? ` · skip: ${[...args.skip].join(",")}` : ""));
console.log("");

for (const step of STEPS) {
  if (args.skip.has(step.name)) {
    console.log(`── [${step.no}/5] ${step.name}：已显式跳过（--skip），漏步风险自担。`);
    continue;
  }
  console.log(`── [${step.no}/5] ${step.name}${step.offline ? "（离线）" : args.dryRun ? "（dry-run：不外呼）" : ""}`);
  if (step.offline) {
    if (step.no === 1) {
      const expected = process.env.WORKPAW_VERSION ?? "";
      if (!expected) {
        console.log(`    环境未设 WORKPAW_VERSION，按 --tag 派生为 ${version}（建议显式 export WORKPAW_VERSION=${version} 后重跑以完成双向校验）。`);
      } else if (expected !== version) {
        fail("1 local-version", `WORKPAW_VERSION=${expected} 与 --tag ${tag} 不一致（应为 ${version}）。`,
          `export WORKPAW_VERSION=${version} 后重跑；本地 shell 变量与发布 tag 必须同源。`);
      } else {
        console.log(`    WORKPAW_VERSION=${expected} 与 ${tag} 一致。`);
      }
      if (existsSync(DOWNLOADS_JSON)) {
        try {
          const local = JSON.parse(readFileSync(DOWNLOADS_JSON, "utf8"));
          if (local.tag !== tag) {
            console.error(`    警告：本地工单 ${DOWNLOADS_JSON} 的 tag=${local.tag} 落后于 ${tag}（第 3 步会刷新）。`);
          } else {
            console.log(`    本地工单已指向 ${tag}。`);
          }
        } catch {
          console.error(`    警告：本地工单 ${DOWNLOADS_JSON} 暂不可解析（第 3 步会刷新）。`);
        }
      } else {
        console.error(`    警告：本地工单 ${DOWNLOADS_JSON} 不存在（第 3 步会生成）。`);
      }
    } else if (step.no === 5) {
      printDispatchHints(tag, version, args.dryRun);
    }
  } else if (args.dryRun) {
    if (step.no === 2) {
      console.log(`    [dry-run] 将 GET ${process.env.KEYGATE_UPDATE_URL ?? "<未配置 KEYGATE_UPDATE_URL>"} 并要求 version == ${version}；404/不一致即停。`);
    } else if (step.no === 3) {
      console.log(`    [dry-run] 将执行 bash ${MIRROR_SCRIPT} ${tag}，并以 stdout 末行 MIRRORED=${tag} 判定成功。`);
    } else if (step.no === 4) {
      const count = existsSync(DOWNLOADS_JSON)
        ? (JSON.parse(readFileSync(DOWNLOADS_JSON, "utf8")).platforms ?? []).reduce((sum, p) => sum + (p.files?.length ?? 0), 0) + 1
        : null;
      console.log(`    [dry-run] 将 HEAD ${COS_PUBLIC_BASE}/download/${tag}/ 下 ${count ?? "<工单缺失，跑第 3 步后生成>"} 个关键对象（工单资产 + manifest.tsv）。`);
    }
  } else if (step.no === 2) {
    await checkKeygate(tag, version);
  } else if (step.no === 3) {
    runMirror(tag);
  } else if (step.no === 4) {
    await checkCosAssets(tag);
  }
  console.log("");
}

const skipped = STEPS.filter((s) => args.skip.has(s.name)).map((s) => s.name);
console.log(`✓ 编排完成（${args.dryRun ? "DRY-RUN" : "LIVE"}）：tag=${tag}` +
  (skipped.length ? ` · 跳过：${skipped.join(",")}` : " · 全部步骤通过"));
console.log("  收尾动作见上方第 5 步的 gh workflow dispatch 命令清单。");
