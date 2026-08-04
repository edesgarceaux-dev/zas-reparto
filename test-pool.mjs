import { chromium } from 'playwright';
import path from 'path';

const url = 'file://' + path.resolve('panel/panel-zas.html');
const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
const page = await browser.newPage();
const errors = [];
page.on('pageerror', e => errors.push('pageerror: ' + e.message));
page.on('console', m => { if (m.type()==='error' && !/ERR_CONNECTION_RESET|ERR_FILE_NOT_FOUND|ERR_NAME_NOT_RESOLVED|Failed to load resource/.test(m.text())) errors.push('console: '+m.text()); });
await page.goto(url, { waitUntil: 'domcontentloaded' });

const r = await page.evaluate(async () => {
  const out = [];
  const ok = (n, cond, extra='') => out.push({ n, ok: !!cond, extra });

  // ---------- datos de mentira ----------
  const mkPool = (id, comuna) => ({ id, codigo:'ZAS-'+String(id).padStart(5,'0'), cliente_nombre:'Cliente '+id,
    direccion:'Calle '+id, comuna, cliente_id:1, estado:'pendiente', empresa_reparto_id:null,
    creado_en:'2026-08-03T1'+(id%9)+':00:00Z', fecha_pedido:'2026-08-03', origen:'jumpseller' });

  eval(`
    HAY_POOL = true; soySuper = true; miEmpresa = 1;
    empresas = [{id:1,nombre:'Envíos ZAS',activo:true},{id:2,nombre:'Rápido Ltda',activo:true}];
    clientes = [{id:1,nombre:'Distribuidora Pepitos',activo:true}];
    habilitaciones = [{cliente_id:1,empresa_reparto_id:1,activo:true},{cliente_id:1,empresa_reparto_id:2,activo:true}];
    perfiles = [{id:'u1',nombre:'Etienne',rol:'admin',activo:true,empresa_reparto_id:1,superadmin:true}];
    poolPedidos = ${JSON.stringify([1,2,3].map(i=>mkPool(i,'Maipú')).concat([4,5,6].map(i=>mkPool(i,'Ñuñoa'))))};
    pedidos = [{id:99,codigo:'ZAS-00099',cliente_nombre:'Ya mío',direccion:'Mi calle',comuna:'Maipú',
                cliente_id:1,estado:'pendiente',empresa_reparto_id:1,tomado_en:'2026-08-03T10:00:00Z',
                fecha_pedido:'2026-08-03',creado_en:'2026-08-03T09:00:00Z'}];
    poolSel = new Set();
  `);
  document.getElementById('navPool').style.display = '';
  window.__recargas = 0;
  eval("cargarTodo = async () => { window.__recargas++; pintarPool(); }");

  // ---------- 1. la lista del pool ----------
  pintarPool();
  const filas = () => document.querySelectorAll('#tbodyPool tr').length;
  ok('1. muestra los 6 pedidos del pool', filas()===6, 'filas='+filas());
  ok('1b. el globito del menú dice 6', document.getElementById('poolN').textContent==='6');
  ok('1c. NO se mezclan con la pestaña Pedidos', !document.getElementById('tbodyPool').innerHTML.includes('ZAS-00099'));

  // ---------- 2. filtro por comuna ----------
  window.poolFiltrarComuna('Maipú');
  ok('2. filtrar por Maipú deja 3', filas()===3, 'filas='+filas());
  const opciones = [...document.querySelectorAll('#poolComuna option')].map(o=>o.textContent);
  ok('2b. el selector lista las comunas con su cuenta', opciones.some(o=>o.includes('Maipú (3)')) && opciones.some(o=>o.includes('Ñuñoa (3)')), opciones.join(', '));

  // ---------- 3. selección múltiple ----------
  window.poolSeleccionarTodos(true);
  ok('3. "todos" marca solo los 3 visibles de Maipú', document.getElementById('poolSelN').textContent==='3 pedidos marcados',
      document.getElementById('poolSelN').textContent);
  ok('3b. el botón ofrece llevarse los de la comuna', document.getElementById('poolTomar').textContent.includes('de Maipú'),
      document.getElementById('poolTomar').textContent);
  ok('3c. la barra de acción aparece', document.getElementById('poolBarra').style.display==='flex');

  // ---------- 4. tomar OK ----------
  let ultimaLlamada = null;
  eval("sb.rpc = async (n, a) => { window.__ult = {n, a}; return { data:{tomados:a.p_ids.length, ids:a.p_ids, no_pudo:[]}, error:null }; }");
  await window.tomarSeleccionados();
  ultimaLlamada = window.__ult;
  ok('4. llama a tomar_pedidos con los 3 ids', ultimaLlamada.n==='tomar_pedidos' && ultimaLlamada.a.p_ids.length===3,
      JSON.stringify(ultimaLlamada));
  const av = document.getElementById('poolAviso');
  ok('4b. avisa en verde que los tomó', av.style.display==='block' && av.innerHTML.includes('Tomaste 3') && av.style.color.includes('0, 99, 0'),
      av.textContent);
  ok('4c. recarga los datos después de tomar', window.__recargas===1, 'recargas='+window.__recargas);
  ok('4d. limpia lo que ya tomó', (()=>{ let n; eval('n = poolSel.size'); return n===0; })());

  // ---------- 5. otra empresa se adelantó ----------
  eval("sb.rpc = async (n, a) => ({ data:{tomados:0, ids:[], no_pudo:[{id:4, motivo:'se adelantó Rápido Ltda'}]}, error:null })");
  await window.tomarDelPool([4]);
  ok('5. explica que se adelantó la otra empresa', av.innerHTML.includes('se adelantó Rápido Ltda'), av.textContent);
  ok('5b. lo muestra como error, no como éxito', !av.innerHTML.includes('Tomaste'), av.textContent);

  // ---------- 6. tomó unos sí y otros no ----------
  eval("sb.rpc = async (n, a) => ({ data:{tomados:2, ids:[1,2], no_pudo:[{id:3, motivo:'se adelantó Rápido Ltda'}]}, error:null })");
  await window.tomarDelPool([1,2,3]);
  ok('6. avisa los que sí y los que no', av.innerHTML.includes('Tomaste 2') && av.innerHTML.includes('1 no se pudo'), av.textContent);

  // ---------- 7. falta la migración ----------
  eval("sb.rpc = async () => ({ data:null, error:{message:'Could not find the function public.tomar_pedidos(p_ids) in the schema cache'} })");
  await window.tomarDelPool([1]);
  ok('7. si falta el SQL, lo dice claro', av.innerHTML.includes('migracion-red-empresas.sql'), av.textContent);

  // ---------- 8. devolver al pool ----------
  eval(`sb.from = (t) => ({ select: () => ({ eq: () => ({ order: () => Promise.resolve({data:[]}) }) }) })`);
  await window.verDetalle(99);
  const det = document.getElementById('mDetBody').innerHTML;
  ok('8. el pedido propio ofrece "Devolver al pool"', det.includes('Devolver al pool'));
  ok('8b. muestra de qué empresa es', det.includes('Envíos ZAS'), '');

  eval("pedidos[0].estado = 'en_camino'; soySuper = false;");
  await window.verDetalle(99);
  const det2 = document.getElementById('mDetBody').innerHTML;
  ok('9. una empresa NO puede devolver algo que va en camino',
      !det2.includes('Devolver al pool') && det2.includes('no se puede devolver'));

  eval("soySuper = true");
  await window.verDetalle(99);
  const det3 = document.getElementById('mDetBody').innerHTML;
  ok('9b. el super-admin sí puede forzarlo aunque vaya en camino',
      det3.includes('Devolver al pool (forzar)') && det3.includes('solo tú puedes forzar'));
  eval("pedidos[0].estado = 'pendiente'");

  eval("sb.rpc = async (n,a) => { window.__ult={n,a}; return { data:{devueltos:1, ids:a.p_ids, no_pudo:[]}, error:null }; }");
  window.confirm = () => true;
  await window.devolverAlPool(99);
  ok('10. devolver llama a devolver_pedidos', window.__ult.n==='devolver_pedidos' && window.__ult.a.p_ids[0]===99, JSON.stringify(window.__ult));

  eval("sb.rpc = async () => ({ data:{devueltos:0, no_pudo:[{id:99, motivo:'ya va en ruta (en_camino), no se puede soltar'}]}, error:null })");
  window.__toasts = []; window.toast = m => window.__toasts.push(m);
  await window.devolverAlPool(99);
  ok('11. si no se puede devolver, explica por qué', (window.__toasts.join(' ')).includes('ya va en ruta'), window.__toasts.join(' | '));

  // ---------- 12. administración de empresas ----------
  pintarEmpresas();
  const tEmp = document.getElementById('tbodyEmp').innerHTML;
  ok('12. lista las 2 empresas de reparto', tEmp.includes('Envíos ZAS') && tEmp.includes('Rápido Ltda'));
  ok('12b. marca cuál es la tuya', tEmp.includes('la tuya'));

  // ---------- 13. habilitaciones dentro del cliente ----------
  eval("clienteEditando = 1");
  pintarEmpresasDelCliente();
  const cajaEmp = document.getElementById('cEmpresasBox');
  ok('13. la ficha del cliente muestra las empresas', cajaEmp.style.display==='block' &&
      document.querySelectorAll('#cEmpresasLista input:checked').length===2);
  ok('13b. avisa que con 2 empresas los pedidos van al pool',
      document.getElementById('cEmpresasEstado').textContent.includes('pool'),
      document.getElementById('cEmpresasEstado').textContent);

  eval("habilitaciones = [{cliente_id:1,empresa_reparto_id:1,activo:true}]");
  pintarEmpresasDelCliente();
  ok('13c. con una sola, dice que le llegan directo',
      document.getElementById('cEmpresasEstado').textContent.includes('directo'),
      document.getElementById('cEmpresasEstado').textContent);

  // ---------- 14. sin la migración corrida, todo sigue igual ----------
  eval(`HAY_POOL = false;
        poolPedidos = [];
        pedidos = [{id:5,codigo:'ZAS-00005',cliente_nombre:'Viejo',direccion:'x',comuna:'Maipú',
                    estado:'pendiente',fecha_pedido:'2026-08-03',creado_en:'2026-08-03T09:00:00Z'}];`);
  eval("repartirPedidos([{id:7, codigo:'ZAS-7', estado:'pendiente'}])");
  const sigueTodo = eval("pedidos.length===1 && poolPedidos.length===0");
  ok('14. sin migración, ningún pedido se va al pool por error', sigueTodo);

  return out;
});

await browser.close();
let malos = 0;
for (const t of r) { if (!t.ok) malos++; console.log((t.ok?'✅':'❌') + ' ' + t.n + (t.extra?('  ← '+t.extra):'')); }
if (errors.length) { console.log('\nERRORES DE LA PÁGINA:'); errors.forEach(e=>console.log('  '+e)); }
console.log(`\n${r.length - malos}/${r.length} pruebas OK` + (errors.length?` · ${errors.length} errores de página`:''));
process.exit(malos || errors.length ? 1 : 0);
