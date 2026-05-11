#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const repoRoot = path.resolve(__dirname, "..");

function globInstallDevSh() {
  const dir = path.join(repoRoot, "linux");
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((f) => /^install-.+-dev\.sh$/.test(f))
    .map((f) => path.join(dir, f));
}

function globInstallDevPs1() {
  const dir = path.join(repoRoot, "windows");
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((f) => /^install-.+-dev\.ps1$/.test(f))
    .map((f) => path.join(dir, f));
}

function destNameFromDev(devPath) {
  const base = path.basename(devPath);
  const m = base.match(/^(.+)-dev(\.[A-Za-z0-9]+)$/i);
  if (!m || !m[1].startsWith("install-")) {
    throw new Error(`Unexpected dev script name: ${base}`);
  }
  return `${m[1]}${m[2]}`;
}

/** Bash: strip whole-line comments; keep shebang on line 1; keep lines starting with #! anywhere; respect heredocs. */
function stripShellWholeLineComments(src) {
  const normalized = src.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  const lines = normalized.split("\n");
  const out = [];
  let i = 0;
  let heredocDelim = null;
  let stripTabs = false;

  while (i < lines.length) {
    const line = lines[i];
    if (heredocDelim !== null) {
      out.push(line);
      let cmp = line;
      if (stripTabs) cmp = cmp.replace(/^\t+/, "");
      if (cmp === heredocDelim) {
        heredocDelim = null;
        stripTabs = false;
      }
      i++;
      continue;
    }

    const hd = parseHeredocStart(line);
    if (hd) {
      out.push(line);
      heredocDelim = hd.delim;
      stripTabs = hd.stripTabs;
      i++;
      continue;
    }

    if (i === 0 && line.startsWith("#!")) {
      out.push(line);
    } else if (/^\s*#/.test(line) && !/^\s*#!/.test(line)) {
      /* drop whole-line comment */
    } else {
      out.push(line);
    }
    i++;
  }
  return out.join("\n");
}

function parseHeredocStart(line) {
  let idx = line.indexOf("<<");
  while (idx !== -1) {
    const rest = line.slice(idx + 2);
    const m = rest.match(/^(-)?\s*(?:'([^']*)'|"([^"]*)"|([a-zA-Z_]\w*))/);
    if (m) {
      const delim = m[2] ?? m[3] ?? m[4];
      return { delim, stripTabs: !!m[1] };
    }
    idx = line.indexOf("<<", idx + 2);
  }
  return null;
}

function compressBlankLines(text) {
  const lines = text.replace(/\r\n/g, "\n").replace(/\r/g, "\n").split("\n");
  const out = [];
  let i = 0;
  while (i < lines.length) {
    if (lines[i].trim() === "") {
      let j = i;
      while (j < lines.length && lines[j].trim() === "") j++;
      const runLen = j - i;
      if (runLen >= 3) out.push("");
      else {
        for (let k = i; k < j; k++) out.push(lines[k]);
      }
      i = j;
    } else {
      out.push(lines[i]);
      i++;
    }
  }
  while (out.length && out[0].trim() === "") out.shift();
  while (out.length && out[out.length - 1].trim() === "") out.pop();
  return out.join("\n");
}

function ensureLfOnly(text) {
  return text.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
}

function writeDistRel(relPath, body) {
  const dest = path.join(repoRoot, "dist", relPath);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, body, "utf8");
}

function tryShfmt(filePath) {
  const r = spawnSync("shfmt", ["-w", "-i", "4", "-bn", "-ci", filePath], {
    encoding: "utf8",
    stdio: "pipe",
  });
  if (r.status !== 0 && r.status !== null) {
    process.stderr.write(
      `warn: shfmt failed (${r.status}); leaving unformatted: ${filePath}\n${r.stderr || ""}`
    );
  }
}

function main() {
  const shFiles = globInstallDevSh();
  const psFiles = globInstallDevPs1();
  if (shFiles.length === 0 && psFiles.length === 0) {
    process.stderr.write("No install-*-dev scripts found under linux/ or windows/.\n");
    process.exit(1);
  }

  const distDir = path.join(repoRoot, "dist");
  fs.mkdirSync(distDir, { recursive: true });

  for (const src of shFiles) {
    const raw = fs.readFileSync(src, "utf8");
    let body = stripShellWholeLineComments(raw);
    body = ensureLfOnly(body);
    body = compressBlankLines(body);
    if (!body.endsWith("\n")) body += "\n";
    const name = destNameFromDev(src);
    writeDistRel(name, body);
    tryShfmt(path.join(distDir, name));
  }

  for (const src of psFiles) {
    const name = destNameFromDev(src);
    const destAbs = path.join(distDir, name);
    const stripScript = path.join(repoRoot, "scripts", "strip-ps1-for-release.ps1");
    const r = spawnSync(
      "pwsh",
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", stripScript, "-SourcePath", src, "-DestPath", destAbs],
      { encoding: "utf8", stdio: "inherit" }
    );
    if (r.status !== 0) {
      process.exit(r.status ?? 1);
    }
  }

  console.log("dist/:");
  for (const f of fs.readdirSync(distDir).sort()) {
    console.log(`  ${f}`);
  }
}

main();
