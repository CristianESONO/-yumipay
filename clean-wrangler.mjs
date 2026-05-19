import fs from 'node:fs';
import path from 'node:path';

const basePath = process.cwd();

const targets = [
  path.join(basePath, '.wrangler'),
  path.join(basePath, 'dist', 'client', 'wrangler.json'),
  path.join(basePath, 'dist', 'server', 'wrangler.json')
];

for (const target of targets) {
  try {
    if (fs.existsSync(target)) {
      console.log(`🧹 Borrando artefacto de Cloudflare: ${target}`);
      fs.rmSync(target, { recursive: true, force: true });
    }
  } catch(e) {
    console.error(`❌ Error borrando ${target}:`, e.message);
  }
}

