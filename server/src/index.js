// Alerta Sísmica CO — servidor de recolección, consenso y alertas.
//
// Un solo cliente consulta los catálogos para todos los usuarios (antes cada
// teléfono bajaba ~13 MB/día), guarda los eventos y despacha el aviso por FCM
// a las zonas afectadas. También recibe las detecciones de los sismógrafos de
// los teléfonos y declara "consenso comunitario" cuando varios coinciden.

import { FUENTES, diagnosticar, diagnosticarSgc } from "./fuentes.js";
import { enviarAZonas, enviarADispositivos } from "./fcm.js";
import {
  celdaDe, zonaDe, zonasEnRadio, haversineKm, intensidad, centroDeCelda,
  dedupSismos,
} from "./geo.js";

const JSON_H = { "Content-Type": "application/json; charset=utf-8" };
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
};

const ok = (datos) =>
  new Response(JSON.stringify(datos), { headers: { ...JSON_H, ...CORS } });
const malo = (msg, code = 400) =>
  new Response(JSON.stringify({ error: msg }), {
    status: code,
    headers: { ...JSON_H, ...CORS },
  });

const num = (v, def = null) =>
  v === undefined || v === null || v === "" ? def : Number(v);

export default {
  async fetch(peticion, env) {
    const url = new URL(peticion.url);
    const ruta = url.pathname.replace(/\/+$/, "") || "/";

    if (peticion.method === "OPTIONS") return new Response(null, { headers: CORS });

    try {
      switch (peticion.method + " " + ruta) {
        case "GET /":
        case "GET /v1":
        case "GET /v1/salud":
          return ok({
            servicio: "alerta-sismica",
            version: "0.1.0",
            hora: new Date().toISOString(),
            fcm: env.FCM_PROJECT_ID ? "configurado" : "modo prueba",
          });

        case "POST /v1/dispositivos":
          return await registrarDispositivo(peticion, env);

        case "POST /v1/detecciones":
          return await recibirDeteccion(peticion, env);

        case "GET /v1/sismos":
          return await listarSismos(url, env);

        case "GET /v1/panel":
          return await datosPanel(url, env, peticion);

        case "POST /v1/simulacro":
          return await lanzarSimulacro(peticion, env);

        case "POST /v1/sondear": // ejecución manual del sondeo (pruebas/admin)
          return await sondeoManual(peticion, env);

        case "GET /v1/diagnostico": // estado real de cada catálogo
          return await diagnosticoFuentes(peticion, env);

        default:
          return malo("Ruta no encontrada", 404);
      }
    } catch (e) {
      return malo("Error interno: " + e.message, 500);
    }
  },

  async scheduled(evento, env, ctx) {
    ctx.waitUntil(sondear(env, false));
  },
};

/* ---------------- Dispositivos ---------------- */
// Se guarda la CELDA, nunca la coordenada exacta (Ley 1581 de 2012).
async function registrarDispositivo(peticion, env) {
  const b = await peticion.json();
  if (!b.id) return malo("Falta el id anónimo del dispositivo");
  const lat = num(b.lat), lon = num(b.lon);
  if (lat === null || lon === null) return malo("Faltan lat/lon");

  const celda = celdaDe(lat, lon);
  const zona = zonaDe(lat, lon);
  await env.DB.prepare(
    "INSERT INTO dispositivos (id, token, celda, radio_km, min_mag, municipio, actualizado)" +
    " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)" +
    " ON CONFLICT(id) DO UPDATE SET" +
    "   token=excluded.token, celda=excluded.celda, radio_km=excluded.radio_km," +
    "   min_mag=excluded.min_mag, municipio=excluded.municipio," +
    "   actualizado=excluded.actualizado"
  ).bind(
    b.id, b.token ?? null, celda, num(b.radioKm, 500), num(b.minMag, 2.5),
    b.municipio ?? null, Date.now()
  ).run();

  // La app se suscribe a este tema en FCM para recibir las alertas de su zona.
  return ok({ celda, zona, tema: zona });
}

/* ---------------- Detecciones ciudadanas ---------------- */
async function recibirDeteccion(peticion, env) {
  const b = await peticion.json();
  if (!b.id) return malo("Falta el id anónimo del dispositivo");
  const lat = num(b.lat), lon = num(b.lon);
  if (lat === null || lon === null) return malo("Faltan lat/lon");

  const celda = celdaDe(lat, lon);
  const ocurrio = num(b.ocurrio, Date.now());
  await env.DB.prepare(
    "INSERT INTO detecciones (disp, celda, intensidad, ocurrio, registrado)" +
    " VALUES (?1, ?2, ?3, ?4, ?5)"
  ).bind(b.id, celda, num(b.intensidad, null), ocurrio, Date.now()).run();

  const consenso = await revisarConsenso(env, celda, ocurrio);
  return ok({ recibido: true, celda, consenso });
}

/**
 * Un golpe afecta a un teléfono; un sismo afecta a muchos a la vez.
 * Si varios dispositivos distintos y cercanos entre sí detectan dentro de una
 * ventana de 20 s, se declara consenso comunitario y se avisa a la región.
 */
async function revisarConsenso(env, celda, ocurrio) {
  const minimo = Number(env.CONSENSO_MINIMO ?? 4);
  const centro = centroDeCelda(celda);

  const { results } = await env.DB.prepare(
    "SELECT disp, celda FROM detecciones WHERE ocurrio BETWEEN ?1 AND ?2"
  ).bind(ocurrio - 20000, ocurrio + 20000).all();

  const cercanos = new Set();
  for (const r of results ?? []) {
    const c = centroDeCelda(r.celda);
    if (haversineKm(centro.lat, centro.lon, c.lat, c.lon) <= 120) cercanos.add(r.disp);
  }
  if (cercanos.size < minimo) {
    return { declarado: false, dispositivos: cercanos.size, minimo };
  }

  // Evitar declarar dos veces el mismo evento comunitario.
  const id = "com_" + Math.round(ocurrio / 60000) + "_" + celda;
  const previo = await env.DB.prepare("SELECT id FROM sismos WHERE id = ?1")
    .bind(id).first();
  if (previo) {
    return { declarado: false, yaRegistrado: true, dispositivos: cercanos.size };
  }

  await env.DB.prepare(
    "INSERT INTO sismos (id, fuente, mag, lat, lon, prof, lugar, ocurrio, registrado, notificado)" +
    " VALUES (?1, 'COMUNIDAD', 0, ?2, ?3, 0, ?4, ?5, ?6, 1)"
  ).bind(
    id, centro.lat, centro.lon,
    "Movimiento detectado por " + cercanos.size + " teléfonos",
    ocurrio, Date.now()
  ).run();

  const zonas = zonasEnRadio(centro.lat, centro.lon, 150);
  const envio = await enviarAZonas(env, zonas, {
    datos: {
      tipo: "consenso", id, lat: centro.lat, lon: centro.lon,
      dispositivos: cercanos.size, ocurrio,
    },
    notificacion: {
      title: "⚠️ Movimiento detectado cerca de ti",
      body: cercanos.size + " teléfonos registraron una sacudida simultánea. " +
            "Si lo sentiste, protégete.",
    },
    urgente: true,
  });
  await bitacora(env, id, "consenso", zonas.length, envio);
  return { declarado: true, dispositivos: cercanos.size, envio };
}

/* ---------------- Sondeo de catálogos ---------------- */
async function leerEstado(env, clave) {
  const r = await env.DB.prepare("SELECT valor FROM estado WHERE clave = ?1")
    .bind(clave).first();
  return r ? Number(r.valor) : 0;
}

async function guardarEstado(env, clave, valor) {
  await env.DB.prepare(
    "INSERT INTO estado (clave, valor) VALUES (?1, ?2)" +
    " ON CONFLICT(clave) DO UPDATE SET valor = excluded.valor"
  ).bind(clave, String(valor)).run();
}

export async function sondear(env, forzar) {
  const ahora = Date.now();
  const resumen = { fuentes: {}, nuevos: 0, alertas: [] };

  for (const [nombre, cfg] of Object.entries(FUENTES)) {
    const ultimo = await leerEstado(env, "ultimo_" + nombre);
    if (!forzar && ahora - ultimo < cfg.cada * 60000) {
      resumen.fuentes[nombre] = "en espera";
      continue;
    }
    try {
      const eventos = await cfg.traer(ahora - 3 * 3600 * 1000); // últimas 3 h
      let nuevos = 0;
      for (const e of eventos) {
        const ins = await env.DB.prepare(
          "INSERT OR IGNORE INTO sismos" +
          " (id, fuente, mag, lat, lon, prof, lugar, ocurrio, registrado, notificado)" +
          " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 0)"
        ).bind(e.id, e.fuente, e.mag, e.lat, e.lon, e.prof, e.lugar, e.ocurrio, ahora).run();
        if (ins.meta.changes > 0) nuevos++;
      }
      resumen.fuentes[nombre] = eventos.length + " vistos, " + nuevos + " nuevos";
      resumen.nuevos += nuevos;
      await guardarEstado(env, "ultimo_" + nombre, ahora);
    } catch (e) {
      resumen.fuentes[nombre] = "error: " + e.message;
    }
  }

  resumen.alertas = await despacharPendientes(env);
  return resumen;
}

/** Envía el aviso de los sismos aún no notificados (y descarta duplicados). */
async function despacharPendientes(env) {
  const limite = Date.now() - 90 * 60000; // solo eventos realmente frescos
  const { results } = await env.DB.prepare(
    "SELECT * FROM sismos WHERE notificado = 0 AND ocurrio > ?1" +
    " ORDER BY ocurrio ASC LIMIT 5"
  ).bind(limite).all();

  const salida = [];
  for (const s of results ?? []) {
    // El mismo sismo suele aparecer en varios catálogos: si ya se avisó uno
    // equivalente (±120 s y <60 km), no se repite el aviso.
    const { results: previos } = await env.DB.prepare(
      "SELECT lat, lon FROM sismos" +
      " WHERE notificado = 1 AND id <> ?1 AND ABS(ocurrio - ?2) < 120000"
    ).bind(s.id, s.ocurrio).all();
    const duplicado = (previos ?? []).some(
      (p) => haversineKm(p.lat, p.lon, s.lat, s.lon) < 60
    );

    await env.DB.prepare("UPDATE sismos SET notificado = 1 WHERE id = ?1")
      .bind(s.id).run();
    if (duplicado) {
      salida.push({ id: s.id, omitido: "duplicado" });
      continue;
    }

    const radio = Number(env.RADIO_ALERTA_KM ?? 300);
    const zonas = zonasEnRadio(s.lat, s.lon, radio);
    const fuerte = s.mag >= 5;

    const datos = {
      tipo: "sismo", id: s.id, fuente: s.fuente, mag: s.mag, lat: s.lat,
      lon: s.lon, prof: s.prof, lugar: s.lugar, ocurrio: s.ocurrio,
      emergencia: fuerte ? "1" : "0",
    };

    // EL ORDEN ES LO QUE SALVA SEGUNDOS. Primero el envío DIRECTO a los
    // teléfonos más cercanos —medido: llega en ~1 s— y solo después el envío
    // por zonas, que sirve de cobertura amplia pero tarda más de un minuto.
    // Al revés, la gente que está encima del epicentro esperaría a que
    // terminara la difusión general.
    let directo = null;
    if (fuerte) {
      const cercanos = await dispositivosCercanos(env, s.lat, s.lon, radio, s.mag);
      directo = await enviarADispositivos(env, cercanos.map((d) => d.token), {
        datos,
        urgente: true,
      });
    }

    // Umbral de prioridad de esta zona: de el depende si el aviso despierta
    // los telefonos o espera a que lo hagan solos.
    const umbral = await umbralDeLaZona(env, s.lat, s.lon, radio);

    // SOLO DATOS, NUNCA CARGA DE "NOTIFICACIÓN".
    //
    // Si el mensaje trae carga de notificación, la dibuja Android antes de que
    // la app se entere: no puede ser de pantalla completa y —lo que rompía el
    // ajuste— TAMPOCO puede filtrarse. Una zona mide ~111 km y dentro de ella
    // conviven usuarios con magnitudes mínimas distintas, así que el servidor
    // no puede decidir por ellos: quien puso el umbral en M3.5 recibía igual
    // todos los sismos. Mandando solo datos, el filtro lo aplica el teléfono
    // (ver sismoPasaElFiltro en app_flutter/lib/core.dart).
    //
    // A cambio se pierde el aviso si el usuario forzó la detención de la app
    // desde los ajustes de Android: ahí el sistema no deja que se ejecute nada
    // nuestro. Es el precio de que el ajuste signifique algo.
    const envio = await enviarAZonas(env, zonas, {
      datos,
      notificacion: null,
      // Prioridad alta si el sismo supera el umbral MÁS BAJO que haya pedido
      // algún teléfono de la zona.
      //
      // La prioridad alta atraviesa el reposo profundo (Doze) y despierta el
      // teléfono. Con prioridad normal Android retiene el mensaje y lo suelta
      // al desbloquear: los avisos llegaban todos juntos, en cola, horas
      // después. Para un sismo eso no sirve.
      //
      // Pero ponerla siempre tampoco: medido sobre el catálogo real llegan
      // 35,5 sismos al día dentro del radio y casi todos los descarta el
      // propio teléfono, así que eran despertares para nada —lo contrario del
      // motivo por el que existe este servidor— y Google degrada a las apps
      // que abusan de la prioridad alta sin mostrar nada.
      //
      // El equilibrio correcto no es un número fijo: es el umbral real de los
      // usuarios. Si alguien pidió avisos desde M3, un M3 lo despierta.
      urgente: s.mag >= umbral,
    });

    // La limpieza de tokens muertos va al final: no debe retrasar el aviso.
    if (directo) await purgarTokens(env, directo.invalidos ?? []);

    await bitacora(env, s.id, "catalogo", zonas.length, envio, directo);
    salida.push({
      id: s.id, mag: s.mag, lugar: s.lugar, zonas: zonas.length, envio, directo,
      // Visible a proposito: de este umbral depende que el aviso despierte o
      // no el telefono, y sin verlo no hay forma de diagnosticar un retraso.
      umbral, urgente: s.mag >= umbral,
    });
  }
  return salida;
}

/**
 * El umbral de magnitud MAS BAJO que haya pedido algun telefono cuyo radio
 * cubra este sismo. De el depende si el aviso viaja con prioridad alta.
 *
 * Nunca devuelve algo por encima del valor por omision de la app: puede
 * haber telefonos suscritos al tema de su zona que no llegaron a registrarse
 * aqui —la app se suscribe sola aunque el servidor no responda— y a esos hay
 * que tratarlos como si tuvieran los ajustes de fabrica. Vale mas gastar
 * algun despertar de sobra que dejar a alguien sin su aviso.
 */
async function umbralDeLaZona(env, lat, lon, radioKm) {
  const porOmision = Number(env.MAG_PRIORIDAD_ALTA ?? 2.5);
  try {
    const { results } = await env.DB.prepare(
      "SELECT celda, radio_km, min_mag FROM dispositivos" +
      " WHERE token IS NOT NULL"
    ).all();
    let minimo = null;
    for (const d of results ?? []) {
      const c = centroDeCelda(d.celda);
      if (haversineKm(lat, lon, c.lat, c.lon) > (d.radio_km ?? radioKm)) continue;
      const m = Number(d.min_mag ?? 0);
      if (minimo === null || m < minimo) minimo = m;
    }
    return minimo === null ? porOmision : Math.min(porOmision, minimo);
  } catch (_) {
    // Ante un fallo de la base, el criterio prudente es el de fabrica.
    return porOmision;
  }
}

/**
 * Teléfonos registrados dentro del radio, ORDENADOS por cercanía al epicentro.
 *
 * El orden importa: si hay más dispositivos de los que se pueden avisar en una
 * sola ejecución, los primeros en enterarse deben ser los que están encima del
 * sismo. La distancia se calcula desde el centro de su celda —nunca se guarda
 * la ubicación exacta—, así que es aproximada a unos 28 km.
 */
async function dispositivosCercanos(env, lat, lon, radioKm, mag = null) {
  const tope = Number(env.MAX_ENVIO_DIRECTO ?? 40);
  const { results } = await env.DB.prepare(
    "SELECT id, token, celda, radio_km, min_mag FROM dispositivos" +
    " WHERE token IS NOT NULL"
  ).all();

  return (results ?? [])
    .map((d) => {
      const c = centroDeCelda(d.celda);
      return { ...d, dist: haversineKm(lat, lon, c.lat, c.lon) };
    })
    .filter((d) => d.dist <= radioKm)
    // Cada teléfono dejó registrados SUS ajustes al darse de alta: respetarlos
    // aquí es gratis y evita gastar los envíos directos —que son pocos y van
    // primero— en gente que de todos modos iba a descartar el aviso.
    .filter((d) => d.dist <= (d.radio_km ?? radioKm))
    .filter((d) => mag === null || mag >= (d.min_mag ?? 0))
    .sort((a, b) => a.dist - b.dist)
    .slice(0, tope);
}

/// Da de baja los tokens que Firebase reporta como muertos (app desinstalada).
async function purgarTokens(env, tokens) {
  for (const t of tokens) {
    await env.DB.prepare(
      "UPDATE dispositivos SET token = NULL WHERE token = ?1"
    ).bind(t).run();
  }
}

async function bitacora(env, sismoId, motivo, celdas, envio, directo = null) {
  await env.DB.prepare(
    "INSERT INTO alertas (sismo_id, motivo, celdas, enviada, detalle)" +
    " VALUES (?1, ?2, ?3, ?4, ?5)"
  ).bind(
    sismoId, motivo, celdas, Date.now(),
    JSON.stringify({
      enviados: envio.enviados,
      simulado: envio.simulado,
      errores: (envio.errores ?? []).slice(0, 3),
      directo: directo
        ? { enviados: directo.enviados, fallidos: directo.fallidos }
        : null,
    })
  ).run();
}

/* ---------------- Consulta de sismos (app y panel) ---------------- */
async function listarSismos(url, env) {
  const lat = num(url.searchParams.get("lat"));
  const lon = num(url.searchParams.get("lon"));
  const radio = num(url.searchParams.get("radio"), 500);
  // La magnitud mínima que eligió el usuario. Se filtra en SQL y no después,
  // para que el LIMIT no se gaste en micro-sismos que la app va a descartar:
  // con el umbral en M3.5 el límite de 500 se llenaba de eventos M1.x y los
  // sismos que sí importan quedaban fuera de la lista.
  const magMin = num(url.searchParams.get("mag"), 0);
  const dias = Math.min(num(url.searchParams.get("dias"), 7), 30);
  const desde = Date.now() - dias * 86400000;

  const { results } = await env.DB.prepare(
    "SELECT id, fuente, mag, lat, lon, prof, lugar, ocurrio FROM sismos" +
    " WHERE ocurrio > ?1 AND fuente <> 'COMUNIDAD' AND mag >= ?2" +
    " ORDER BY ocurrio DESC LIMIT 500"
  ).bind(desde, magMin).all();

  // Fusionar ANTES de filtrar por radio: si se hiciera al revés y la solución
  // del SGC quedara justo fuera del radio mientras la del EMSC entra, el
  // evento reaparecería con la magnitud de la fuente menos prioritaria.
  let lista = dedupSismos(results ?? []);
  if (lat !== null && lon !== null) {
    lista = lista
      .map((s) => ({ ...s, dist: Math.round(haversineKm(lat, lon, s.lat, s.lon)) }))
      .filter((s) => s.dist <= radio);
  }
  return ok({ total: lista.length, sismos: lista });
}

/* ---------------- Panel de la alcaldía ---------------- */
async function datosPanel(url, env, peticion) {
  const lat = num(url.searchParams.get("lat"), 4.142);
  const lon = num(url.searchParams.get("lon"), -73.627);
  const radio = num(url.searchParams.get("radio"), 350);
  const ahora = Date.now();
  const desde = ahora - 30 * 86400000;
  const desdeAnterior = ahora - 60 * 86400000;

  // Caja geográfica para que el filtro pese en SQL y no en memoria. Antes se
  // traían 2000 filas y se descartaban aquí: con el catálogo lleno eso
  // truncaba el extremo viejo de la ventana y los totales salían cortos.
  const gLat = radio / 111;
  const gLon = radio / (111 * Math.max(0.1, Math.cos((lat * Math.PI) / 180)));
  const caja = [lat - gLat, lat + gLat, lon - gLon, lon + gLon];

  const { results } = await env.DB.prepare(
    "SELECT id, fuente, mag, lat, lon, prof, lugar, ocurrio FROM sismos" +
    " WHERE ocurrio > ?1 AND fuente <> 'COMUNIDAD'" +
    " AND lat BETWEEN ?2 AND ?3 AND lon BETWEEN ?4 AND ?5" +
    " ORDER BY ocurrio DESC"
  ).bind(desde, ...caja).all();

  // Fusionar antes de contar: un mismo temblor lo publican SGC, USGS y EMSC,
  // y sin fusionarlos el panel declaraba hasta el triple de sismos de los que
  // realmente ocurrieron.
  const cerca = dedupSismos(results ?? [])
    .map((s) => ({ ...s, dist: Math.round(haversineKm(lat, lon, s.lat, s.lon)) }))
    .filter((s) => s.dist <= radio);

  // Mismo recuento para los 30 días anteriores: da la variación del periodo.
  //
  // Se traen las filas en vez de un COUNT porque hay que fusionarlas con el
  // mismo criterio. Con un COUNT crudo el periodo anterior quedaría inflado
  // frente al actual ya fusionado, y el panel anunciaría un desplome de la
  // actividad sísmica que solo existe en la aritmética.
  const { results: filasPrev } = await env.DB.prepare(
    "SELECT id, fuente, mag, lat, lon, prof, lugar, ocurrio FROM sismos" +
    " WHERE ocurrio > ?1 AND ocurrio <= ?2 AND fuente <> 'COMUNIDAD'" +
    " AND lat BETWEEN ?3 AND ?4 AND lon BETWEEN ?5 AND ?6"
  ).bind(desdeAnterior, desde, ...caja).all();

  const prev = {
    n: dedupSismos(filasPrev ?? []).filter(
      (s) => haversineKm(lat, lon, s.lat, s.lon) <= radio
    ).length,
  };

  const porDia = {};
  for (const s of cerca) {
    // Colombia es UTC-5 todo el año: restar el desfase da el día local.
    const k = new Date(s.ocurrio - 5 * 3600000).toISOString().slice(0, 10);
    porDia[k] = (porDia[k] ?? 0) + 1;
  }

  const total = cerca.length;
  const pct = (n) => (total ? Math.round((n / total) * 1000) / 10 : 0);
  const reparto = (pares) =>
    pares.map(([clave, n]) => ({ clave, n, pct: pct(n) }));

  const cuenta = (fn) => cerca.filter(fn).length;
  const sentidos = cuenta((s) => intensidad(s.mag, s.dist) >= 3);
  const anterior = prev?.n ?? 0;

  const fuentes = {};
  for (const s of cerca) fuentes[s.fuente] = (fuentes[s.fuente] ?? 0) + 1;

  const proporciones = {
    porFuente: reparto(
      Object.entries(fuentes).sort((a, b) => b[1] - a[1])
    ),
    porMagnitud: reparto([
      ["M < 2,0", cuenta((s) => s.mag < 2)],
      ["M 2,0–2,9", cuenta((s) => s.mag >= 2 && s.mag < 3)],
      ["M 3,0–3,9", cuenta((s) => s.mag >= 3 && s.mag < 4)],
      ["M 4,0–4,9", cuenta((s) => s.mag >= 4 && s.mag < 5)],
      ["M ≥ 5,0", cuenta((s) => s.mag >= 5)],
    ]),
    porDistancia: reparto([
      ["0–50 km", cuenta((s) => s.dist <= 50)],
      ["50–100 km", cuenta((s) => s.dist > 50 && s.dist <= 100)],
      ["100–200 km", cuenta((s) => s.dist > 100 && s.dist <= 200)],
      ["más de 200 km", cuenta((s) => s.dist > 200)],
    ]),
    sentidos: { n: sentidos, pct: pct(sentidos) },
    // Variación contra los 30 días anteriores. Sin periodo previo con datos
    // no se inventa un porcentaje: se devuelve null y el panel lo omite.
    variacion: anterior > 0
      ? { anterior, pct: Math.round(((total - anterior) / anterior) * 1000) / 10 }
      : { anterior, pct: null },
  };

  // El bloque de plataforma NO es público: revela el tamaño real del
  // despliegue. Se entrega solo con la clave del panel.
  const clave = url.searchParams.get("clave") ?? "";
  const cabecera = peticion?.headers.get("Authorization") ?? "";
  const admin = Boolean(env.PANEL_TOKEN) &&
    (clave === env.PANEL_TOKEN || cabecera === "Bearer " + env.PANEL_TOKEN);

  let plataforma = null;
  if (admin) {
    const disp = await env.DB.prepare("SELECT COUNT(*) AS n FROM dispositivos").first();
    const activos = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM dispositivos WHERE actualizado > ?1"
    ).bind(ahora - 7 * 86400000).first();
    const det = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM detecciones WHERE ocurrio > ?1"
    ).bind(desde).first();
    const ale = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM alertas WHERE enviada > ?1"
    ).bind(desde).first();
    const com = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM sismos WHERE fuente = 'COMUNIDAD' AND ocurrio > ?1"
    ).bind(desde).first();
    const nDisp = disp?.n ?? 0;
    const nAct = activos?.n ?? 0;
    plataforma = {
      dispositivos: nDisp,
      activos7d: nAct,
      activosPct: nDisp ? Math.round((nAct / nDisp) * 1000) / 10 : 0,
      detecciones: det?.n ?? 0,
      alertas: ale?.n ?? 0,
      eventosComunitarios: com?.n ?? 0,
    };
  }

  return ok({
    generado: ahora,
    municipio: { lat, lon, radio },
    admin,
    sismos: {
      total,
      masCercano: cerca.reduce((a, s) => (!a || s.dist < a.dist ? s : a), null),
      mayor: cerca.reduce((a, s) => (!a || s.mag > a.mag ? s : a), null),
      sentidos,
      porDia,
    },
    proporciones,
    plataforma,
    lista: cerca.slice(0, 500),
  });
}

/* ---------------- Simulacro municipal ---------------- */
async function lanzarSimulacro(peticion, env) {
  const auth = peticion.headers.get("Authorization") ?? "";
  if (!env.ADMIN_TOKEN || auth !== "Bearer " + env.ADMIN_TOKEN) {
    return malo("No autorizado", 401);
  }
  const b = await peticion.json();
  const lat = num(b.lat), lon = num(b.lon), radio = num(b.radioKm, 60);
  if (lat === null || lon === null) return malo("Faltan lat/lon del municipio");

  const zonas = zonasEnRadio(lat, lon, radio);
  const id = "sim_" + Date.now();
  const envio = await enviarAZonas(env, zonas, {
    datos: {
      tipo: "simulacro", id, municipio: b.municipio ?? "", ocurrio: Date.now(),
    },
    notificacion: {
      title: "🎓 SIMULACRO — esto es una práctica",
      body: b.mensaje ??
        "Agáchate, cúbrete y sujétate. Mediremos tu tiempo de reacción.",
    },
    urgente: true,
  });
  await bitacora(env, id, "simulacro", zonas.length, envio);
  return ok({ simulacro: id, zonas: zonas.length, envio });
}

/**
 * Estado de cada catálogo. Responde a la pregunta que importa cuando el
 * panel aparece vacío: ¿no ha temblado, o llevamos horas sin poder leer una
 * fuente? Va protegido porque obliga al servidor a salir a las tres APIs.
 */
async function diagnosticoFuentes(peticion, env) {
  const auth = peticion.headers.get("Authorization") ?? "";
  if (!env.ADMIN_TOKEN || auth !== "Bearer " + env.ADMIN_TOKEN) {
    return malo("No autorizado", 401);
  }
  const desde = Date.now() - 3 * 3600 * 1000;
  const [fuentes, sgc] = await Promise.all([
    diagnosticar(desde),
    diagnosticarSgc(desde),
  ]);
  return ok({ ventana: "3 h", fuentes, detalleSgc: sgc });
}

/**
 * Sondeo a petición. Va con credencial: sin ella, cualquiera podría obligar
 * al servidor a golpear los tres catálogos en bucle, agotar el plan gratuito
 * y conseguir que el SGC nos bloquee por abuso. La tarea programada sigue
 * corriendo sola cada minuto; esto es solo para pruebas y mantenimiento.
 */
async function sondeoManual(peticion, env) {
  const auth = peticion.headers.get("Authorization") ?? "";
  if (!env.ADMIN_TOKEN || auth !== "Bearer " + env.ADMIN_TOKEN) {
    return malo("No autorizado", 401);
  }
  return ok(await sondear(env, true));
}
