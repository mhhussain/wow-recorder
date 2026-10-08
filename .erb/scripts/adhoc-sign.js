/**
 * electron-builder afterPack hook: ad-hoc sign the macOS app.
 *
 * This personal fork has no signing certificate (mac.identity is null), but
 * Apple Silicon refuses to run code whose signature was invalidated when
 * electron-builder rewrote the bundle. Sign inside-out: the loose Mach-O
 * binaries in Resources (capture helper, ffmpeg, native .node modules),
 * then the whole bundle (--deep covers frameworks and helper apps).
 *
 * TCC (Screen Recording, Microphone) identifies an ad-hoc signed app by its
 * code hash, so every new build may need permissions granted again. See
 * docs/macos-port/MANUAL_TEST.md.
 */
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const isMachO = (file) => {
  const fd = fs.openSync(file, 'r');
  const magic = Buffer.alloc(4);
  fs.readSync(fd, magic, 0, 4, 0);
  fs.closeSync(fd);
  const value = magic.readUInt32BE(0);
  // 64-bit Mach-O (either endianness) and universal binaries.
  return [0xfeedfacf, 0xcffaedfe, 0xcafebabe].includes(value);
};

const walk = (dir) =>
  fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isSymbolicLink()) return [];
    if (entry.isDirectory()) return walk(full);
    return [full];
  });

const sign = (target) =>
  execFileSync('codesign', ['--force', '--sign', '-', target], {
    stdio: 'inherit',
  });

exports.default = async function adhocSign(context) {
  if (context.electronPlatformName !== 'darwin') return;

  const appName = context.packager.appInfo.productFilename;
  const app = path.join(context.appOutDir, `${appName}.app`);
  const resources = path.join(app, 'Contents', 'Resources');

  walk(resources)
    .filter((file) => isMachO(file))
    .forEach((file) => {
      console.log('  • ad-hoc signing', path.relative(app, file));
      sign(file);
    });

  console.log('  • ad-hoc signing', app);
  execFileSync('codesign', ['--force', '--deep', '--sign', '-', app], {
    stdio: 'inherit',
  });

  execFileSync('codesign', ['--verify', '--deep', '--strict', app], {
    stdio: 'inherit',
  });
};
