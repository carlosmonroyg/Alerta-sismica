-- Esquema de Alerta Sísmica CO.
-- Diseñado para que el costo no crezca con el número de usuarios: no se
-- guardan datos crudos del acelerómetro, solo eventos y disparos puntuales.

CREATE TABLE IF NOT EXISTS sismos (
  id          TEXT PRIMARY KEY,      -- 'sgc_...', 'usgs_...', 'emsc_...'
  fuente      TEXT NOT NULL,         -- SGC | USGS | EMSC | COMUNIDAD
  mag         REAL NOT NULL,
  lat         REAL NOT NULL,
  lon         REAL NOT NULL,
  prof        REAL,
  lugar       TEXT,
  ocurrio     INTEGER NOT NULL,      -- epoch ms del sismo
  registrado  INTEGER NOT NULL,      -- epoch ms en que lo vimos (mide el retraso)
  notificado  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS ix_sismos_ocurrio ON sismos (ocurrio DESC);
CREATE INDEX IF NOT EXISTS ix_sismos_pend    ON sismos (notificado, ocurrio DESC);

-- Un registro por teléfono. La ubicación se guarda en cuadrícula difusa
-- (celda de ~55 km), nunca coordenadas exactas: Ley 1581 de 2012.
CREATE TABLE IF NOT EXISTS dispositivos (
  id          TEXT PRIMARY KEY,      -- id anónimo generado en el teléfono
  token       TEXT,                  -- token FCM
  celda       TEXT NOT NULL,
  radio_km    REAL NOT NULL DEFAULT 500,
  min_mag     REAL NOT NULL DEFAULT 2.5,
  municipio   TEXT,
  actualizado INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_disp_celda ON dispositivos (celda);

-- Disparos del sismógrafo de cada teléfono (~200 bytes por evento, no continuo).
CREATE TABLE IF NOT EXISTS detecciones (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  disp       TEXT NOT NULL,
  celda      TEXT NOT NULL,
  intensidad REAL,
  ocurrio    INTEGER NOT NULL,
  registrado INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_det_ocurrio ON detecciones (ocurrio DESC);
CREATE INDEX IF NOT EXISTS ix_det_celda   ON detecciones (celda, ocurrio DESC);

-- Bitácora de envíos: es la evidencia que la alcaldía necesita reportar.
CREATE TABLE IF NOT EXISTS alertas (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  sismo_id  TEXT NOT NULL,
  motivo    TEXT NOT NULL,           -- catalogo | consenso | simulacro
  celdas    INTEGER NOT NULL,
  enviada   INTEGER NOT NULL,
  detalle   TEXT
);
CREATE INDEX IF NOT EXISTS ix_alertas_env ON alertas (enviada DESC);

-- Marcas de tiempo del último sondeo por fuente (para escalonar el ritmo).
CREATE TABLE IF NOT EXISTS estado (
  clave TEXT PRIMARY KEY,
  valor TEXT NOT NULL
);
