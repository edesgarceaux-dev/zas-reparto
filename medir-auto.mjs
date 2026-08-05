/* ============================================================
   ¿QUÉ TAN BUENO ES EL REPARTO AUTOMÁTICO?

   No alcanza con que "no falle": lo que importa es cuántos kilómetros
   termina manejando cada repartidor. Este script mide eso con pedidos
   parecidos a un día real y lo compara contra dos alternativas:

     · al azar     — repartir sin mirar el mapa (el peor caso)
     · por comuna  — agrupar por comuna, que es lo que se haría a mano

   Además mide el SOLAPAMIENTO: cuántos kilómetros se pisan los sectores
   entre sí. Un reparto sectorizado de verdad tiene sectores que no se
   cruzan.
   ============================================================ */
import { chromium } from 'playwright';
import path from 'path';

const url = 'file://' + path.resolve('panel/panel-zas.html');
const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
const page = await browser.newPage();
await page.goto(url, { waitUntil: 'domcontentloaded' });

const r = await page.evaluate(async () => {
  eval(`
    window.__sectores = repartirEnSectores;
    window.__orden    = ordenarGrupoPorCercania;
    window.__dist     = distKm;
    clientes = [{id:1, nombre:'Bodega', lat:-33.4489, lng:-70.6693}];
  `);
  const BODEGA = { lat: -33.4489, lng: -70.6693 };

  // 20 comunas de la RM con su centro aproximado y cuánto peso tiene cada
  // una en un día típico (más pedidos donde más se vende)
  const COMUNAS = [
    ['Maipú',-33.5110,-70.7580, 12], ['Puente Alto',-33.6110,-70.5760, 13],
    ['La Florida',-33.5520,-70.5810, 10], ['Santiago',-33.4450,-70.6540, 9],
    ['Ñuñoa',-33.4560,-70.5970, 6], ['Providencia',-33.4270,-70.6100, 5],
    ['Las Condes',-33.4090,-70.5480, 5], ['San Bernardo',-33.5920,-70.6990, 6],
    ['La Pintana',-33.5830,-70.6320, 5], ['Recoleta',-33.4100,-70.6400, 4],
    ['Peñalolén',-33.4820,-70.5390, 4], ['Quilicura',-33.3670,-70.7290, 4],
    ['Renca',-33.4030,-70.7280, 3], ['La Granja',-33.5390,-70.6260, 3],
    ['El Bosque',-33.5620,-70.6750, 3], ['Macul',-33.4890,-70.5980, 2],
    ['Independencia',-33.4160,-70.6640, 2], ['Cerrillos',-33.4950,-70.7180, 2],
    ['Colina',-33.2010,-70.6750, 1], ['Lampa',-33.2860,-70.8790, 1],
  ];

  // secuencia fija: la medición da siempre lo mismo
  let s = 12345;
  const rnd = () => (s = (s * 1103515245 + 12345) % 2147483648) / 2147483648;

  const hacerDia = (n) => {
    const bolsa = [];
    COMUNAS.forEach((c, i) => { for (let k = 0; k < c[3]; k++) bolsa.push(i); });
    const lista = [];
    for (let i = 0; i < n; i++) {
      const c = COMUNAS[bolsa[Math.floor(rnd() * bolsa.length)]];
      lista.push({
        id: i + 1, comuna: c[0],
        lat: c[1] + (rnd() - .5) * .045,
        lng: c[2] + (rnd() - .5) * .055,
        estado: 'pendiente',
      });
    }
    return lista;
  };

  const D = window.__dist;
  // km de una ruta: bodega → paradas en orden → (no se cuenta la vuelta)
  const kmRuta = (ruta) => {
    if (!ruta.length) return 0;
    let km = D(BODEGA, ruta[0]);
    for (let i = 1; i < ruta.length; i++) km += D(ruta[i - 1], ruta[i]);
    return km;
  };
  // radio del sector: qué tan desparramado quedó
  const radio = (g) => {
    if (!g.length) return 0;
    const cx = g.reduce((a, p) => a + p.lat, 0) / g.length;
    const cy = g.reduce((a, p) => a + p.lng, 0) / g.length;
    return Math.max(...g.map(p => D({ lat: cx, lng: cy }, p)));
  };
  // solapamiento: pares de sectores cuyos círculos se pisan
  const solape = (grupos) => {
    let pisados = 0, pares = 0;
    for (let i = 0; i < grupos.length; i++)
      for (let j = i + 1; j < grupos.length; j++) {
        if (!grupos[i].length || !grupos[j].length) continue;
        pares++;
        const ci = { lat: grupos[i].reduce((a,p)=>a+p.lat,0)/grupos[i].length,
                     lng: grupos[i].reduce((a,p)=>a+p.lng,0)/grupos[i].length };
        const cj = { lat: grupos[j].reduce((a,p)=>a+p.lat,0)/grupos[j].length,
                     lng: grupos[j].reduce((a,p)=>a+p.lng,0)/grupos[j].length };
        if (D(ci, cj) < radio(grupos[i]) + radio(grupos[j])) pisados++;
      }
    return pares ? Math.round(pisados * 100 / pares) : 0;
  };

  /* La medida honesta de "¿está sectorizado?": cuántos pedidos quedaron
     más cerca del centro de OTRO sector que del suyo. Si es 0%, los
     sectores no se pisan; si es alto, las rutas se cruzan en la calle. */
  const invadidos = (grupos) => {
    const vivos = grupos.filter(g=>g.length);
    const centros = vivos.map(g => ({
      lat: g.reduce((a,p)=>a+p.lat,0)/g.length,
      lng: g.reduce((a,p)=>a+p.lng,0)/g.length }));
    let mal = 0, total = 0;
    vivos.forEach((g, i) => g.forEach(p => {
      if (p.lat == null) return;
      total++;
      const mio = D(centros[i], p);
      if (centros.some((c, j) => j !== i && D(c, p) < mio - 0.001)) mal++;
    }));
    return total ? Math.round(mal * 100 / total) : 0;
  };

  const medir = (grupos) => {
    const vivos = grupos.filter(g => g.length);
    const kms = vivos.map(g => kmRuta(window.__orden(g)));
    return {
      kmTotal: Math.round(kms.reduce((a, b) => a + b, 0)),
      kmPorRuta: kms.map(k => Math.round(k)),
      radios: vivos.map(g => +radio(g).toFixed(1)),
      solapePct: solape(grupos),
      invadidoPct: invadidos(grupos),
      tamanos: vivos.map(g => g.length),
    };
  };

  // --- las tres formas de repartir ---
  const alAzar = (lista, n) => {
    const g = Array.from({ length: n }, () => []);
    lista.forEach((p, i) => g[i % n].push(p));
    return g;
  };
  const porComuna = (lista, n) => {
    // se ordenan las comunas por cantidad y se van repartiendo enteras
    const porC = {};
    lista.forEach(p => (porC[p.comuna] = porC[p.comuna] || []).push(p));
    const bloques = Object.values(porC).sort((a, b) => b.length - a.length);
    const g = Array.from({ length: n }, () => []);
    for (const b of bloques) {
      g.sort((x, y) => x.length - y.length);   // al que menos tiene
      g[0].push(...b);
    }
    return g;
  };

  /* ---------- CANDIDATO: k-medias con cupo ----------
     En vez de hacer crecer los sectores de a un pedido (que va arrastrando
     el centro), esto pone K centros, asigna cada pedido a su centro más
     cercano respetando el cupo, recalcula los centros y repite. Es lo que
     se usa para armar zonas de reparto de verdad. */
  const kmedias = (lista, cupos, prefsTxt) => {
    const n = cupos.length;
    const con = lista.filter(p => p.lat != null && p.lng != null);
    const sin = lista.filter(p => p.lat == null || p.lng == null);
    if (!con.length) return Array.from({length:n}, () => []);

    const norm = t => (t||'').toString().toLowerCase().trim();
    const prefs = (prefsTxt||Array(n).fill(null))
      .map(t => norm(t).split(',').map(x=>x.trim()).filter(Boolean));

    // centros iniciales: la comuna preferida si la hay; si no, los puntos
    // más separados entre sí (k-means++ simplificado y determinista)
    const centros = [];
    for (let i = 0; i < n; i++) {
      let semilla = null;
      for (const c of prefs[i]) {
        const cand = con.filter(p => norm(p.comuna).includes(c) || c.includes(norm(p.comuna)));
        if (cand.length) {
          semilla = { lat: cand.reduce((a,p)=>a+p.lat,0)/cand.length,
                      lng: cand.reduce((a,p)=>a+p.lng,0)/cand.length };
          break;
        }
      }
      if (!semilla) {
        if (!centros.length) {
          semilla = { lat: con[0].lat, lng: con[0].lng };
        } else {
          let mejor = con[0], mejorD = -1;
          for (const p of con) {
            const d = Math.min(...centros.map(c => D(c, p)));
            if (d > mejorD) { mejorD = d; mejor = p; }
          }
          semilla = { lat: mejor.lat, lng: mejor.lng };
        }
      }
      centros.push(semilla);
    }

    let grupos = Array.from({length:n}, () => []);
    for (let vuelta = 0; vuelta < 12; vuelta++) {
      grupos = Array.from({length:n}, () => []);
      // el que más "sufre" si no va a su centro elige primero
      const orden = con.map(p => {
        const ds = centros.map(c => D(c, p)).sort((a,b)=>a-b);
        return { p, pena: (ds[1] ?? ds[0]) - ds[0] };
      }).sort((a,b) => b.pena - a.pena);

      for (const { p } of orden) {
        let mejor = -1, mejorD = Infinity;
        for (let i = 0; i < n; i++) {
          if (grupos[i].length >= cupos[i]) continue;
          const d = D(centros[i], p);
          if (d < mejorD) { mejorD = d; mejor = i; }
        }
        if (mejor >= 0) grupos[mejor].push(p);
      }
      // centros nuevos
      let movio = 0;
      for (let i = 0; i < n; i++) {
        if (!grupos[i].length) continue;
        const nc = { lat: grupos[i].reduce((a,p)=>a+p.lat,0)/grupos[i].length,
                     lng: grupos[i].reduce((a,p)=>a+p.lng,0)/grupos[i].length };
        movio += D(centros[i], nc);
        centros[i] = nc;
      }
      if (movio < 0.05) break;      // ya no se mueven: listo
    }
    // los sin coordenadas, a los que tengan lugar
    for (const p of sin) {
      const libre = grupos.map((g,i)=>({i, libre: cupos[i]-g.length}))
                          .filter(x=>x.libre>0)
                          .sort((a,b)=>b.libre-a.libre)[0];
      if (libre) grupos[libre.i].push(p);
    }
    return grupos;
  };

  const salida = [];
  for (const [pedidos, reps] of [[120, 3], [258, 4], [500, 6]]) {
    const lista = hacerDia(pedidos);
    const base = Math.floor(pedidos / reps);
    const cupos = Array.from({ length: reps },
      (_, i) => base + (i < pedidos % reps ? 1 : 0));

    const zas   = medir(window.__sectores(lista, cupos, Array(reps).fill(null)).grupos);
    const azar  = medir(alAzar(lista, reps));
    const comu  = medir(porComuna(lista, reps));

    // y con comunas de preferencia, como lo usaría de verdad
    const prefs = Array(reps).fill(null);
    prefs[0] = 'Maipú, Cerrillos';
    prefs[1] = 'Puente Alto, La Pintana';
    const pref = medir(window.__sectores(lista, cupos, prefs).grupos);

    const km   = medir(kmedias(lista, cupos, Array(reps).fill(null)));
    const kmP  = medir(kmedias(lista, cupos, prefs));
    // ¿respeta las comunas preferidas? cuántos de «Maipú, Cerrillos» se
    // llevó el repartidor 0, sobre el total que había
    const gPref = window.__sectores(lista, cupos, prefs).grupos;
    const objetivo = ['Maipú','Cerrillos'];
    const hay   = lista.filter(p=>objetivo.includes(p.comuna)).length;
    const tomo  = (gPref[0]||[]).filter(p=>objetivo.includes(p.comuna)).length;
    const suRuta = (gPref[0]||[]).length;
    salida.push({ pedidos, reps, zas, azar, comu, pref, km, kmP,
                  prefHay: hay, prefTomo: tomo, prefRuta: suRuta,
                  prefCupo: cupos[0] });
  }
  return salida;
});

await browser.close();

const pct = (a, b) => Math.round((b - a) * 100 / b);
console.log('\n╔══════════════════════════════════════════════════════════════════╗');
console.log('║  ¿CUÁNTO MANEJA CADA REPARTIDOR SEGÚN CÓMO SE REPARTA?           ║');
console.log('╚══════════════════════════════════════════════════════════════════╝');

for (const c of r) {
  console.log(`\n── ${c.pedidos} pedidos entre ${c.reps} repartidores ──────────────────────`);
  const fila = (n, m) => console.log(
    `  ${n.padEnd(26)} ${String(m.kmTotal).padStart(5)} km` +
    `   sectores de ${Math.min(...m.radios).toFixed(0)}–${Math.max(...m.radios).toFixed(0)} km de radio` +
    `   ${String(m.invadidoPct).padStart(3)}% de los pedidos le tocan a otro sector`);
  fila('Al azar (sin mirar mapa)', c.azar);
  fila('Por comuna (a mano)', c.comu);
  fila('🤖 Repartir auto', c.zas);
  fila('🤖 con comunas preferidas', c.pref);
  fila('🆕 k-medias con cupo', c.km);
  fila('🆕 k-medias + preferidas', c.kmP);
  console.log(`  → contra el azar ahorra ${pct(c.zas.kmTotal, c.azar.kmTotal)}%` +
              `, contra repartir por comuna ${pct(c.zas.kmTotal, c.comu.kmTotal)}%`);
  console.log(`  → k-medias contra el actual: ${pct(c.km.kmTotal, c.zas.kmTotal)}% menos km`);
  console.log(`  → rutas de ${c.zas.kmPorRuta.join(', ')} km  ·  ` +
              `${c.zas.tamanos.join(' / ')} pedidos cada una`);
  console.log(`  → comunas preferidas: hay ${c.prefHay} de «Maipú+Cerrillos», ` +
              `el repartidor con esa preferencia se llevó ${c.prefTomo} ` +
              `(su ruta es de ${c.prefRuta}, cupo ${c.prefCupo})`);
}
console.log('');
