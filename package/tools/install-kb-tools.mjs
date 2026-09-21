#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const KB_PLUGIN_ID = "kb";
const KB_TOOLS = ["kb_ingest", "kb_search", "kb_manage"];

function fail(message) {
  console.error(`[kb-tools] ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const options = {
    stateDir: process.env.OPENCLAW_STATE_DIR || "",
    pkgRoot: "",
    configPath: "",
    verifyOnly: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--state-dir") options.stateDir = argv[++i] || "";
    else if (arg === "--pkg-root") options.pkgRoot = argv[++i] || "";
    else if (arg === "--config") options.configPath = argv[++i] || "";
    else if (arg === "--verify-only") options.verifyOnly = true;
    else fail(`Unknown argument: ${arg}`);
  }

  if (!options.pkgRoot) fail("Missing --pkg-root.");
  if (!options.configPath) {
    if (!options.stateDir) fail("Missing --state-dir or --config.");
    options.configPath = path.join(options.stateDir, "openclaw.json");
  }

  return options;
}

function readJson(filePath, label) {
  if (!fs.existsSync(filePath)) fail(`${label} is missing: ${filePath}`);
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    fail(`${label} is invalid JSON: ${filePath}. ${error.message}`);
  }
}

function assertBundledPlugin(pkgRoot) {
  const pluginRoot = path.join(pkgRoot, "dist", "extensions", KB_PLUGIN_ID);
  const manifestPath = path.join(pluginRoot, "openclaw.plugin.json");
  const entryPath = path.join(pluginRoot, "index.js");
  const nativeModulePath = path.join(
    pluginRoot,
    "node_modules",
    "@lancedb",
    "lancedb-win32-x64-msvc",
    "lancedb.win32-x64-msvc.node",
  );

  const manifest = readJson(manifestPath, "Bundled KB plugin manifest");
  if (manifest.id !== KB_PLUGIN_ID) {
    fail(`Unexpected KB plugin id in ${manifestPath}: ${manifest.id}`);
  }
  for (const requiredPath of [entryPath, nativeModulePath]) {
    if (!fs.existsSync(requiredPath)) fail(`Bundled KB runtime file is missing: ${requiredPath}`);
  }
}

function uniqueStrings(value) {
  if (!Array.isArray(value)) return [];
  return [...new Set(value.filter((item) => typeof item === "string" && item.length > 0))];
}

function getMainAgent(config, create) {
  if (!config.agents || typeof config.agents !== "object") {
    if (!create) return null;
    config.agents = {};
  }
  if (!Array.isArray(config.agents.list)) {
    if (!create) return null;
    config.agents.list = [];
  }

  let main = config.agents.list.find((agent) => agent && agent.id === "main");
  if (!main && create) {
    main = { id: "main" };
    config.agents.list.push(main);
  }
  return main || null;
}

function applyKbConfiguration(config) {
  const plugins = (config.plugins ??= {});
  const entries = (plugins.entries ??= {});
  const kbEntry = (entries[KB_PLUGIN_ID] ??= {});
  kbEntry.enabled = true;
  plugins.allow = uniqueStrings([...(plugins.allow || []), KB_PLUGIN_ID]);

  const main = getMainAgent(config, true);
  const tools = (main.tools ??= {});
  tools.profile ??= "coding";
  tools.alsoAllow = uniqueStrings([...(tools.alsoAllow || []), ...KB_TOOLS]);

  const kbToolSet = new Set(KB_TOOLS);
  const deny = uniqueStrings(tools.deny).filter((tool) => !kbToolSet.has(tool));
  if (deny.length > 0) tools.deny = deny;
  else delete tools.deny;
}

function verifyKbConfiguration(config) {
  const errors = [];
  const main = getMainAgent(config, false);
  const alsoAllow = new Set(uniqueStrings(main?.tools?.alsoAllow));
  const deny = new Set(uniqueStrings(main?.tools?.deny));
  const pluginAllow = new Set(uniqueStrings(config.plugins?.allow));

  if (config.plugins?.entries?.[KB_PLUGIN_ID]?.enabled !== true) {
    errors.push("plugins.entries.kb.enabled is not true");
  }
  if (!pluginAllow.has(KB_PLUGIN_ID)) errors.push("plugins.allow does not contain kb");
  for (const tool of KB_TOOLS) {
    if (!alsoAllow.has(tool)) errors.push(`main.tools.alsoAllow does not contain ${tool}`);
    if (deny.has(tool)) errors.push(`main.tools.deny still contains ${tool}`);
  }

  if (errors.length > 0) fail(`KB tool configuration verification failed: ${errors.join("; ")}`);
}

function writeJson(filePath, value) {
  const tempPath = `${filePath}.${process.pid}.tmp`;
  fs.writeFileSync(tempPath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  try {
    fs.copyFileSync(tempPath, filePath);
  } finally {
    fs.rmSync(tempPath, { force: true });
  }
}

const options = parseArgs(process.argv.slice(2));
assertBundledPlugin(path.resolve(options.pkgRoot));

const configPath = path.resolve(options.configPath);
const config = readJson(configPath, "OpenClaw configuration");
if (!options.verifyOnly) {
  applyKbConfiguration(config);
  verifyKbConfiguration(config);
  writeJson(configPath, config);
}

verifyKbConfiguration(options.verifyOnly ? config : readJson(configPath, "OpenClaw configuration"));
console.log(
  JSON.stringify({
    phase: options.verifyOnly ? "verify" : "install",
    status: "done",
    plugin: KB_PLUGIN_ID,
    tools: KB_TOOLS,
    configPath,
  }),
);
