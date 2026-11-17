// create-dmg fixes its artwork/layout internally. Use the same appdmg engine
// with the project's reviewed background, mounted-volume icon and positions.
import path from 'node:path';
import fs from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import appdmg from 'appdmg';

const root = fileURLToPath(new URL('../../', import.meta.url));
const [app, target, documentation] = process.argv.slice(2);
if (!app || !target || !documentation || process.platform !== 'darwin') {
  throw new Error('Usage on macOS: node scripts/dmg/create-installer.mjs APP OUTPUT DOCUMENTATION');
}
const assets = path.join(root, 'Resources/Installer');
// appdmg expects a new destination; the packaging command can be rerun.
await fs.rm(target, {force: true});
await new Promise((resolve, reject) => {
  const build = appdmg({
    target: path.resolve(target),
    basepath: root,
    specification: {
      title: 'Meeting Intelligence',
      icon: path.join(assets, 'volume-icon.icns'),
      background: path.join(assets, 'background.png'),
      'icon-size': 128,
      format: 'ULFO',
      filesystem: 'APFS',
      window: {size: {width: 720, height: 272}, position: {x: 180, y: 160}},
      contents: [
        {x: 145, y: 130, type: 'file', path: path.resolve(app)},
        {x: 560, y: 130, type: 'link', path: '/Applications'},
        {x: 0, y: 0, type: 'file', path: path.resolve(documentation), name: '.Documentation'},
      ],
    },
  });
  build.on('progress', event => {
    if (event.type === 'step-begin') process.stdout.write(`${event.title}\n`);
  });
  build.on('error', reject);
  build.on('finish', resolve);
});
