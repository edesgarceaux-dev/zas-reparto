/* ============================================================
   Corre TODAS las suites de test (test-*.mjs) y da un resumen.
   Uso:  npm test        (o:  node run-tests.mjs)
   Requiere Playwright:  npm install  &&  npx playwright install chromium
   Si tu Chromium está en otro lado:  CHROMIUM_PATH=/ruta node run-tests.mjs
   ============================================================ */
import { readdirSync } from 'fs';
import { spawn } from 'child_process';

const suites = readdirSync('.')
  .filter(f => /^test-.*\.mjs$/.test(f))
  .sort();

if (!suites.length) { console.log('No encontré ninguna suite test-*.mjs'); process.exit(1); }

const correr = (f) => new Promise((res) => {
  const p = spawn(process.execPath, [f], { stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  p.stdout.on('data', d => out += d);
  p.stderr.on('data', d => out += d);
  p.on('close', code => {
    const linea = (out.trim().split('\n').pop() || '').trim();
    res({ f, code, linea, out });
  });
});

let fallidas = 0;
console.log(`\nCorriendo ${suites.length} suites…\n`);
for (const f of suites) {
  const r = await correr(f);
  const ok = r.code === 0;
  if (!ok) fallidas++;
  console.log(`${ok ? '✅' : '❌'}  ${f.padEnd(22)} ${r.linea}`);
  if (!ok) {                          // en fallo, mostrar las líneas ❌ para diagnosticar
    r.out.split('\n').filter(l => l.includes('❌')).forEach(l => console.log('      ' + l.trim()));
  }
}
console.log(`\n${suites.length - fallidas}/${suites.length} suites OK` +
            (fallidas ? `  —  ${fallidas} con fallos` : '  —  todo verde ✨') + '\n');
process.exit(fallidas ? 1 : 0);
