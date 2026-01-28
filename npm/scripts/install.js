#!/usr/bin/env node

const https = require("https");
const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const REPO = "soyukke/induct";
const VERSION = require("../package.json").version;

const PLATFORMS = {
  "darwin-arm64": "aarch64-macos",
};

async function install() {
  const platform = `${process.platform}-${process.arch}`;
  const target = PLATFORMS[platform];

  if (!target) {
    console.error(`Unsupported platform: ${platform}`);
    process.exit(1);
  }

  const isWindows = process.platform === "win32";
  const ext = isWindows ? "zip" : "tar.gz";
  const binName = isWindows ? "induct-bin.exe" : "induct-bin";

  const url = `https://github.com/${REPO}/releases/download/v${VERSION}/induct-${target}.${ext}`;
  const binDir = path.join(__dirname, "..", "bin");
  const binPath = path.join(binDir, binName);

  console.log(`Downloading induct for ${target}...`);

  try {
    const archivePath = path.join(binDir, `induct.${ext}`);
    await download(url, archivePath);

    const extractedName = isWindows ? "induct.exe" : "induct";
    const extractedPath = path.join(binDir, extractedName);

    if (isWindows) {
      execSync(`powershell -Command "Expand-Archive -Path '${archivePath}' -DestinationPath '${binDir}' -Force"`);
    } else {
      execSync(`tar -xzf "${archivePath}" -C "${binDir}"`);
    }

    // Rename to induct-bin
    fs.renameSync(extractedPath, binPath);
    if (!isWindows) {
      fs.chmodSync(binPath, 0o755);
    }

    fs.unlinkSync(archivePath);
    console.log("✓ induct installed successfully");
  } catch (err) {
    console.error("Failed to install induct:", err.message);
    process.exit(1);
  }
}

function download(url, dest) {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest);

    function request(url) {
      https.get(url, (res) => {
        if (res.statusCode === 302 || res.statusCode === 301) {
          request(res.headers.location);
          return;
        }
        if (res.statusCode !== 200) {
          reject(new Error(`HTTP ${res.statusCode}`));
          return;
        }
        res.pipe(file);
        file.on("finish", () => {
          file.close();
          resolve();
        });
      }).on("error", reject);
    }

    request(url);
  });
}

install();
