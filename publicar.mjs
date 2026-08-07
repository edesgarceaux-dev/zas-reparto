/* ============================================================
   PUBLICAR — copia lo que se edita en panel/ a la raíz (que es lo que
   sirve GitHub Pages) y verifica que quedaron idénticos.
   Uso:  npm run publicar   (o:  node publicar.mjs)
   Después:  git add -A && git commit -m "publicar" && git push
   ============================================================ */
import { copyFileSync, readFileSync, existsSync } from 'fs';

// origen en panel/  ->  destino en la raíz
const mapa = [
  ['panel/panel-zas.html',     'index.html'],
  ['panel/panel-maestro.html', 'panel-maestro.html'],
  ['panel/seguimiento.html',   'seguimiento.html'],
];

let error = false;
for (const [orig, dest] of mapa) {
  if (!existsSync(orig)) { console.log(`⚠️  falta ${orig}, lo salto`); continue; }
  copyFileSync(orig, dest);
  const igual = readFileSync(orig).equals(readFileSync(dest));
  console.log(`${igual ? '✅' : '❌'}  ${orig}  →  ${dest}`);
  if (!igual) error = true;
}
console.log(error
  ? '\n❌ Algo no quedó igual. Revisá antes de commitear.\n'
  : '\n✅ Publicado. Ahora: git add -A && git commit -m "publicar" && git push\n');
process.exit(error ? 1 : 0);
