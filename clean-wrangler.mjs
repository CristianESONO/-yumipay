import fs from 'node:fs';
try { fs.rmSync('.wrangler', { recursive: true, force: true }); } catch(e) {}
try { fs.rmSync('dist/client/wrangler.json', { force: true }); } catch(e) {}
try { fs.rmSync('dist/server/wrangler.json', { force: true }); } catch(e) {}
