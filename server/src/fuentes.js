// Consulta a los catálogos sísmicos. El servidor es UN solo cliente para
// todos los usuarios: descarga una vez lo que antes bajaba cada teléfono.

const TIMEOUT = 20000;

async function pedir(url, opciones = {}) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT);
  try {
    const r = await fetch(url, { ...opciones, signal: ctrl.signal });
    if (!r.ok && r.status !== 204) throw new Error(`HTTP ${r.status}`);
    return r.status === 204 ? null : await r.json();
  } finally {
    clearTimeout(t);
  }
}

/** Catálogo oficial del Servicio Geológico Colombiano. */
export async function traerSgc(desdeMs) {
  // Su API ignora todo filtro y devuelve páginas fijas de 100 eventos; los
  // nuevos van al principio, así que una página basta para alertar.
  const j = await pedir("https://apicatalogador.sgc.gov.co/api/events/search/?page=1", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{}",
  });
  const lista = j?.results?.results ?? [];
  const out = [];
  for (const e of lista) {
    if (e.event_type !== "earthquake") continue;
    const t = Date.parse(`${e.utc_time}Z`);
    if (!t || t < desdeMs) continue;
    if (e.latitude == null || e.longitude == null || e.magnitude == null) continue;
    out.push({
      id: `sgc_${e.id}`,
      fuente: "SGC",
      mag: Number(e.magnitude),
      lat: Number(e.latitude),
      lon: Number(e.longitude),
      prof: Number(e.depth ?? 0),
      lugar: e.place ?? "Colombia",
      ocurrio: t,
    });
  }
  return out;
}

/** USGS — cobertura global, publica en ~18 min. */
export async function traerUsgs(desdeMs) {
  const url = "https://earthquake.usgs.gov/fdsnws/event/1/query?format=geojson" +
    "&latitude=4.6&longitude=-74.1&maxradiuskm=1200&minmagnitude=2.5&orderby=time&limit=100" +
    `&starttime=${new Date(desdeMs).toISOString()}`;
  const j = await pedir(url);
  return (j?.features ?? []).map((f) => ({
    id: `usgs_${f.id}`,
    fuente: "USGS",
    mag: Number(f.properties.mag ?? 0),
    lat: Number(f.geometry.coordinates[1]),
    lon: Number(f.geometry.coordinates[0]),
    prof: Number(f.geometry.coordinates[2] ?? 0),
    lugar: f.properties.place ?? "Ubicación desconocida",
    ocurrio: Number(f.properties.time),
  }));
}

/** EMSC — el más rápido (1-7 min). */
export async function traerEmsc(desdeMs) {
  const url = "https://www.seismicportal.eu/fdsnws/event/1/query?format=json" +
    "&latitude=4.6&longitude=-74.1&maxradius=11&minmagnitude=2.5&orderby=time&limit=100" +
    `&starttime=${new Date(desdeMs).toISOString()}`;
  const j = await pedir(url);
  return (j?.features ?? []).map((f) => {
    const p = f.properties;
    return {
      id: `emsc_${p.unid}`,
      fuente: "EMSC",
      mag: Number(p.mag ?? 0),
      lat: Number(p.lat),
      lon: Number(p.lon),
      prof: Math.abs(Number(p.depth ?? 0)),
      lugar: p.flynn_region ?? "Región desconocida",
      ocurrio: Date.parse(p.time),
    };
  });
}

export const FUENTES = {
  // minutos entre consultas, según el retraso real de publicación medido
  SGC: { cada: 10, traer: traerSgc },
  USGS: { cada: 2, traer: traerUsgs },
  // El EMSC publica en 1-7 min: es la fuente más rápida y pesa 8 KB. El
  // servidor la consulta cada minuto (una sola vez para todos los usuarios).
  EMSC: { cada: 1, traer: traerEmsc },
};

/**
 * Comprueba cada catálogo por separado y explica en qué punto se pierden los
 * eventos: cuántos llegaron, cuántos sobrevivieron a cada filtro y cuál es el
 * más reciente. En un sistema de alerta una fuente no puede fallar en
 * silencio; sin esto, "0 vistos" tanto significa "hoy no tembló" como "llevo
 * una semana sin poder leer el catálogo".
 */
export async function diagnosticar(desdeMs) {
  const salida = {};
  for (const [nombre, cfg] of Object.entries(FUENTES)) {
    const t0 = Date.now();
    try {
      const eventos = await cfg.traer(desdeMs);
      eventos.sort((a, b) => b.ocurrio - a.ocurrio);
      salida[nombre] = {
        ok: true,
        ms: Date.now() - t0,
        enVentana: eventos.length,
        masReciente: eventos[0]
          ? {
              cuando: new Date(eventos[0].ocurrio).toISOString(),
              mag: eventos[0].mag,
              lugar: eventos[0].lugar,
            }
          : null,
      };
    } catch (e) {
      salida[nombre] = { ok: false, ms: Date.now() - t0, error: String(e && e.message || e) };
    }
  }
  return salida;
}

/** Detalle crudo del SGC: lo que responde su API antes de filtrar nada. */
export async function diagnosticarSgc(desdeMs) {
  const url = "https://apicatalogador.sgc.gov.co/api/events/search/?page=1";
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT);
  const paso = { url };
  try {
    const r = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
      signal: ctrl.signal,
    });
    paso.http = r.status;
    paso.tipoContenido = r.headers.get("content-type");
    const texto = await r.text();
    paso.bytes = texto.length;
    let j = null;
    try {
      j = JSON.parse(texto);
    } catch (e) {
      paso.error = "la respuesta no es JSON";
      paso.muestra = texto.slice(0, 200);
      return paso;
    }
    const lista = j?.results?.results ?? [];
    paso.enPagina = Array.isArray(lista) ? lista.length : "no es lista";
    if (Array.isArray(lista) && lista.length) {
      const sismos = lista.filter((e) => e.event_type === "earthquake");
      paso.tipoSismo = sismos.length;
      const conDatos = sismos.filter(
        (e) => e.latitude != null && e.longitude != null && e.magnitude != null
      );
      paso.conCoordenadas = conDatos.length;
      const tiempos = conDatos
        .map((e) => Date.parse(`${e.utc_time}Z`))
        .filter((x) => !Number.isNaN(x));
      paso.fechasLegibles = tiempos.length;
      paso.enVentana = tiempos.filter((x) => x >= desdeMs).length;
      paso.masReciente = tiempos.length
        ? new Date(Math.max(...tiempos)).toISOString()
        : null;
      paso.utcTimeCrudo = lista[0]?.utc_time ?? null;
      paso.ventanaDesde = new Date(desdeMs).toISOString();
      paso.relojDelServidor = new Date().toISOString();
    }
    return paso;
  } catch (e) {
    paso.error = String(e && e.message || e);
    return paso;
  } finally {
    clearTimeout(t);
  }
}
