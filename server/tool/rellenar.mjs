// Carga única de historia: trae los últimos N días de los tres catálogos y
// genera un archivo SQL para meterlos en D1.
//
//     node tool/rellenar.mjs 30 > tool/relleno.sql
//     npx wrangler d1 execute alerta_sismica --remote --file=tool/relleno.sql
//
// Se marcan como notificado=1 a propósito: son sismos viejos, nadie debe
// recibir una alerta por ellos.

const DIAS = Number(process.argv[2] ?? 30);
const desde = Date.now() - DIAS * 24 * 3600 * 1000;
const LAT = 4.6, LON = -74.1;          // centro de consulta (Bogotá)
const log = (...a) => console.error(...a);   // avisos por stderr: el SQL va por stdout

async function json(url, opts) {
  const r = await fetch(url, opts);
  if (!r.ok) throw new Error(`HTTP ${r.status} en ${url.slice(0, 60)}`);
  return r.json();
}

async function usgs() {
  const u = "https://earthquake.usgs.gov/fdsnws/event/1/query?format=geojson" +
    `&latitude=${LAT}&longitude=${LON}&maxradiuskm=1200&orderby=time&limit=2000` +
    `&starttime=${new Date(desde).toISOString()}`;
  const j = await json(u);
  return (j.features ?? []).map((f) => ({
    id: `usgs_${f.id}`, fuente: "USGS",
    mag: Number(f.properties.mag ?? 0),
    lat: Number(f.geometry.coordinates[1]), lon: Number(f.geometry.coordinates[0]),
    prof: Number(f.geometry.coordinates[2] ?? 0),
    lugar: f.properties.place ?? "Ubicación desconocida",
    ocurrio: Number(f.properties.time),
  }));
}

async function emsc() {
  const u = "https://www.seismicportal.eu/fdsnws/event/1/query?format=json" +
    `&latitude=${LAT}&longitude=${LON}&maxradius=11&orderby=time&limit=2000` +
    `&starttime=${new Date(desde).toISOString()}`;
  const j = await json(u);
  return (j.features ?? []).map((f) => {
    const p = f.properties;
    return {
      id: `emsc_${p.unid}`, fuente: "EMSC",
      mag: Number(p.mag ?? 0), lat: Number(p.lat), lon: Number(p.lon),
      prof: Math.abs(Number(p.depth ?? 0)),
      lugar: p.flynn_region ?? "Región desconocida",
      ocurrio: Date.parse(p.time),
    };
  });
}

// El SGC ignora los filtros: hay que paginar hacia atrás hasta salir del rango.
async function sgc() {
  const out = [];
  for (let pagina = 1; pagina <= 60; pagina++) {
    const j = await json(
      `https://apicatalogador.sgc.gov.co/api/events/search/?page=${pagina}`,
      { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" }
    );
    const lista = j?.results?.results ?? [];
    if (!lista.length) break;
    let masViejo = Infinity;
    for (const e of lista) {
      const t = Date.parse(`${e.utc_time}Z`);
      if (!t) continue;
      masViejo = Math.min(masViejo, t);
      if (t < desde) continue;
      if (e.event_type !== "earthquake") continue;
      if (e.latitude == null || e.longitude == null || e.magnitude == null) continue;
      out.push({
        id: `sgc_${e.id}`, fuente: "SGC",
        mag: Number(e.magnitude), lat: Number(e.latitude), lon: Number(e.longitude),
        prof: Number(e.depth ?? 0), lugar: e.place ?? "Colombia", ocurrio: t,
      });
    }
    log(`  SGC página ${pagina}: ${out.length} acumulados` +
        ` (el más viejo de la página: ${new Date(masViejo).toISOString().slice(0, 10)})`);
    if (masViejo < desde) break;      // ya nos pasamos hacia atrás
    await new Promise((r) => setTimeout(r, 300));   // no atropellar su API
  }
  return out;
}

const esc = (s) => String(s).split("'").join("''");

const todo = [];
for (const [nombre, fn] of [["USGS", usgs], ["EMSC", emsc], ["SGC", sgc]]) {
  try {
    const r = await fn();
    log(`${nombre}: ${r.length} eventos`);
    todo.push(...r);
  } catch (e) {
    log(`${nombre}: ERROR ${e.message}`);
  }
}

const vistos = new Set();
const unicos = todo.filter((e) => !vistos.has(e.id) && vistos.add(e.id));
unicos.sort((a, b) => a.ocurrio - b.ocurrio);
log(`TOTAL: ${unicos.length} eventos únicos desde ${new Date(desde).toISOString().slice(0, 10)}`);

const ahora = Date.now();
for (const e of unicos) {
  console.log(
    "INSERT OR IGNORE INTO sismos (id,fuente,mag,lat,lon,prof,lugar,ocurrio,registrado,notificado) VALUES (" +
    `'${esc(e.id)}','${esc(e.fuente)}',${e.mag},${e.lat},${e.lon},${e.prof},` +
    `'${esc(e.lugar)}',${e.ocurrio},${ahora},1);`
  );
}
