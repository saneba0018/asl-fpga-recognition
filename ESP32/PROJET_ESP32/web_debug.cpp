#include "web_debug.h"

#include <WiFi.h>
#include <WebServer.h>

#include "camera_preprocess.h"
#include "spi_comm.h"

static WebServer server(80);

// Dernier etat publie par la boucle principale
static uint8_t rawFrame[WEB_RAW_CAPACITY];
static int rawWidth = 0;
static int rawHeight = 0;

static uint8_t procFrame[OUT_W * OUT_H];
static bool procValid = false;

static uint8_t procMin = 0;
static uint8_t procMax = 0;
static uint8_t procMean = 0;

static int8_t lastLogits[FPGA_NUM_CLASS];
static int lastIdx = 0;
static int lastMargin = 0;
static bool lastValid = false;

static uint32_t frameCount = 0;

//-----------------------------------------------------------------------------
// Page
//-----------------------------------------------------------------------------
static const char INDEX_HTML[] PROGMEM = R"rawliteral(
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ASL FPGA - debug camera</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; padding:20px; background:#14161a; color:#e6e8ec;
         font:14px/1.5 ui-sans-serif,system-ui,-apple-system,sans-serif; }
  h1 { font-size:18px; margin:0 0 4px; }
  .sub { color:#8b929e; margin-bottom:20px; }
  .row { display:flex; flex-wrap:wrap; gap:24px; align-items:flex-start; }
  .card { background:#1b1e24; border:1px solid #2a2f38; border-radius:10px;
          padding:14px; }
  .card h2 { font-size:13px; text-transform:uppercase; letter-spacing:.06em;
             color:#8b929e; margin:0 0 10px; font-weight:600; }
  canvas { image-rendering:pixelated; background:#000; border-radius:4px;
           display:block; max-width:100%; }
  .meta { color:#8b929e; font-size:12px; margin-top:8px; }
  .controls { display:flex; flex-wrap:wrap; gap:16px; align-items:center;
              margin-bottom:20px; }
  label { display:flex; align-items:center; gap:6px; }
  select, button { background:#242932; color:#e6e8ec; border:1px solid #363d49;
                   border-radius:6px; padding:6px 10px; font:inherit; }
  button { cursor:pointer; }
  button:hover { background:#2c323d; }
  .letter { font-size:56px; font-weight:700; line-height:1; }
  .margin-lo { color:#f0a35e; }
  .bars { display:grid; grid-template-columns:repeat(24,1fr); gap:2px;
          align-items:end; height:90px; margin-top:6px; }
  .bar { background:#3d6fd4; border-radius:2px 2px 0 0; min-height:1px; }
  .bar.best { background:#4ec98a; }
  .barlabels { display:grid; grid-template-columns:repeat(24,1fr); gap:2px;
               font-size:9px; color:#8b929e; text-align:center; margin-top:3px; }
  .err { color:#e0685f; }
</style>
</head>
<body>

<h1>ASL FPGA &mdash; diagnostic du pretraitement</h1>
<div class="sub">A gauche ce que voit la camera, a droite ce que recoit
  reellement le FPGA. Le cadre vert marque la zone retenue en mode crop.
  Orientation : l'ASL est chirale &mdash; verifier avec un L de la main droite
  que le pouce pointe vers la gauche de l'image et l'index vers le haut.</div>

<div class="controls">
  <label>Reduction
    <select id="mode">
      <option value="0">Plein cadre (deforme)</option>
      <option value="1">Crop carre centre</option>
    </select>
  </label>
  <label><input type="checkbox" id="hmirror"> Miroir horizontal</label>
  <label><input type="checkbox" id="vflip"> Flip vertical</label>
  <label><input type="checkbox" id="auto" checked> Rafraichissement auto</label>
  <button id="once">Rafraichir</button>
  <span class="meta" id="status">&nbsp;</span>
</div>

<div class="row">
  <div class="card">
    <h2>Trame camera</h2>
    <canvas id="raw"></canvas>
    <div class="meta" id="rawmeta">&mdash;</div>
  </div>

  <div class="card">
    <h2>Envoye au FPGA &mdash; 28 x 28</h2>
    <canvas id="proc"></canvas>
    <div class="meta" id="procmeta">&mdash;</div>
  </div>

  <div class="card" style="min-width:320px">
    <h2>Inference</h2>
    <div class="letter" id="letter">&mdash;</div>
    <div class="meta" id="infmeta">aucun resultat</div>
    <div class="bars" id="bars"></div>
    <div class="barlabels" id="barlabels"></div>
  </div>
</div>

<script>
const LETTERS = "ABCDEFGHIKLMNOPQRSTUVWXY";

function paint(cv, bytes, w, h, scale) {
  cv.width = w; cv.height = h;
  cv.style.width = (w * scale) + "px";
  cv.style.height = (h * scale) + "px";
  const ctx = cv.getContext("2d");
  const im = ctx.createImageData(w, h);
  for (let i = 0; i < w * h; i++) {
    const v = bytes[i];
    im.data[i*4] = v; im.data[i*4+1] = v; im.data[i*4+2] = v; im.data[i*4+3] = 255;
  }
  ctx.putImageData(im, 0, 0);
  return ctx;
}

function cropBox(w, h) {
  const s = Math.min(w, h);
  return { x: (w - s) / 2, y: (h - s) / 2, s: s };
}

async function refresh() {
  const st = document.getElementById("status");
  try {
    const info = await (await fetch("/info", {cache:"no-store"})).json();

    if (info.rawW > 0) {
      const raw = new Uint8Array(
        await (await fetch("/raw", {cache:"no-store"})).arrayBuffer());
      const ctx = paint(document.getElementById("raw"),
                        raw, info.rawW, info.rawH, 3);
      const b = cropBox(info.rawW, info.rawH);
      ctx.strokeStyle = "#4ec98a";
      ctx.lineWidth = 1;
      ctx.strokeRect(b.x + 0.5, b.y + 0.5, b.s - 1, b.s - 1);
      document.getElementById("rawmeta").textContent =
        info.rawW + " x " + info.rawH + " niveaux de gris  |  crop " +
        b.s + " x " + b.s;
    } else {
      document.getElementById("rawmeta").textContent =
        "trame trop grande pour le tampon";
    }

    if (info.procValid) {
      const proc = new Uint8Array(
        await (await fetch("/proc", {cache:"no-store"})).arrayBuffer());
      paint(document.getElementById("proc"), proc, 28, 28, 8);
      document.getElementById("procmeta").textContent =
        "min " + info.min + "  max " + info.max + "  moyenne " + info.mean;
    }

    document.getElementById("mode").value = info.crop ? "1" : "0";
    document.getElementById("hmirror").checked = info.hmirror;
    document.getElementById("vflip").checked = info.vflip;

    const letter = document.getElementById("letter");
    const infmeta = document.getElementById("infmeta");

    if (info.valid) {
      letter.textContent = LETTERS[info.idx] || "?";
      infmeta.innerHTML = "marge " + info.margin +
        (info.margin < 10 ? " <span class='margin-lo'>(faible)</span>" : "");
      const bars = document.getElementById("bars");
      const labels = document.getElementById("barlabels");
      const lo = Math.min(...info.logits), hi = Math.max(...info.logits);
      const span = Math.max(1, hi - lo);
      bars.innerHTML = ""; labels.innerHTML = "";
      info.logits.forEach((v, i) => {
        const d = document.createElement("div");
        d.className = "bar" + (i === info.idx ? " best" : "");
        d.style.height = Math.max(1, Math.round((v - lo) / span * 88)) + "px";
        d.title = LETTERS[i] + " : " + v;
        bars.appendChild(d);
        const l = document.createElement("div");
        l.textContent = LETTERS[i];
        labels.appendChild(l);
      });
    } else {
      letter.textContent = "—";
      infmeta.textContent = "aucun resultat";
    }

    st.textContent = "trame #" + info.frame;
    st.className = "meta";
  } catch (e) {
    st.textContent = "ESP injoignable";
    st.className = "meta err";
  }
}

document.getElementById("mode").addEventListener("change", async (e) => {
  await fetch("/mode?crop=" + e.target.value, {cache:"no-store"});
  refresh();
});
document.getElementById("hmirror").addEventListener("change", async (e) => {
  await fetch("/mode?hmirror=" + (e.target.checked ? "1" : "0"), {cache:"no-store"});
  refresh();
});
document.getElementById("vflip").addEventListener("change", async (e) => {
  await fetch("/mode?vflip=" + (e.target.checked ? "1" : "0"), {cache:"no-store"});
  refresh();
});
document.getElementById("once").addEventListener("click", refresh);

let timer = null;
function schedule() {
  if (timer) clearInterval(timer);
  if (document.getElementById("auto").checked) timer = setInterval(refresh, 1200);
}
document.getElementById("auto").addEventListener("change", schedule);

schedule();
refresh();
</script>
</body>
</html>
)rawliteral";

//-----------------------------------------------------------------------------
// Handlers
//-----------------------------------------------------------------------------
static void handleRoot() {
  server.send_P(200, "text/html; charset=utf-8", INDEX_HTML);
}

static void handleRaw() {
  if (rawWidth <= 0 || rawHeight <= 0) {
    server.send(503, "text/plain", "pas de trame");
    return;
  }

  server.setContentLength(rawWidth * rawHeight);
  server.send(200, "application/octet-stream", "");
  server.sendContent((const char *)rawFrame, rawWidth * rawHeight);
}

static void handleProc() {
  if (!procValid) {
    server.send(503, "text/plain", "pas de trame");
    return;
  }

  server.setContentLength(OUT_W * OUT_H);
  server.send(200, "application/octet-stream", "");
  server.sendContent((const char *)procFrame, OUT_W * OUT_H);
}

static void handleInfo() {
  // Tampon statique + snprintf : la concatenation String allouait et
  // liberait le tas a chaque rafraichissement (toutes les ~1,2 s), le
  // fragmentait, et l'ESP32 finissait par se figer apres quelques minutes.
  static char j[512];

  size_t n = snprintf(j, sizeof(j),
                      "{\"rawW\":%d,\"rawH\":%d,\"procValid\":%s,"
                      "\"min\":%u,\"max\":%u,\"mean\":%u,"
                      "\"crop\":%s,\"hmirror\":%s,\"vflip\":%s,"
                      "\"frame\":%lu,\"valid\":%s,\"idx\":%d,\"margin\":%d,"
                      "\"logits\":[",
                      rawWidth, rawHeight, procValid ? "true" : "false",
                      procMin, procMax, procMean,
                      getPreprocessCrop() ? "true" : "false",
                      getSensorHMirror() ? "true" : "false",
                      getSensorVFlip() ? "true" : "false",
                      (unsigned long)frameCount, lastValid ? "true" : "false",
                      lastIdx, lastMargin);

  for (int i = 0; i < FPGA_NUM_CLASS && n < sizeof(j) - 8; i++) {
    n += snprintf(j + n, sizeof(j) - n, "%s%d",
                  (i > 0) ? "," : "", (int)lastLogits[i]);
  }

  snprintf(j + n, sizeof(j) - n, "]}");

  server.send(200, "application/json", j);
}

static void handleMode() {
  if (server.hasArg("crop")) {
    setPreprocessCrop(server.arg("crop") == "1");
  }

  if (server.hasArg("hmirror")) {
    setSensorOrientation(server.arg("hmirror") == "1", getSensorVFlip());
  }

  if (server.hasArg("vflip")) {
    setSensorOrientation(getSensorHMirror(), server.arg("vflip") == "1");
  }

  server.send(200, "text/plain", "ok");
}

//-----------------------------------------------------------------------------
// API
//-----------------------------------------------------------------------------
void webDebugBegin() {
#if WEB_DEBUG_AP_MODE
  WiFi.mode(WIFI_AP);

  // Economie d'energie du modem desactivee : elle endort la radio entre
  // les balises et chaque echange TCP se fige quelques centaines de ms,
  // ce qui donne une page (et une boucle) qui "gele un peu".
  WiFi.setSleep(false);

  WiFi.softAP(WEB_DEBUG_AP_SSID, WEB_DEBUG_AP_PASS);

  Serial.print("Point d'acces ");
  Serial.print(WEB_DEBUG_AP_SSID);
  Serial.print(" -> http://");
  Serial.println(WiFi.softAPIP());
#else
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);  // meme raison que cote AP
  WiFi.begin(WIFI_SSID, WIFI_PASS);

  Serial.print("Connexion WiFi");

  unsigned long start = millis();

  while (WiFi.status() != WL_CONNECTED && millis() - start < 15000) {
    delay(300);
    Serial.print(".");
  }

  Serial.println();

  if (WiFi.status() == WL_CONNECTED) {
    Serial.print("Page de debug -> http://");
    Serial.println(WiFi.localIP());
  } else {
    Serial.println("Echec WiFi, page de debug indisponible");
    return;
  }
#endif

  server.on("/", handleRoot);
  server.on("/raw", handleRaw);
  server.on("/proc", handleProc);
  server.on("/info", handleInfo);
  server.on("/mode", handleMode);
  server.begin();
}

void webDebugHandle() {
  server.handleClient();
}

void webDebugSetFrames(const uint8_t *raw, int rawW, int rawH,
                       const uint8_t *proc) {
  if (raw != NULL && rawW > 0 && rawH > 0 &&
      (size_t)(rawW * rawH) <= sizeof(rawFrame)) {
    memcpy(rawFrame, raw, rawW * rawH);
    rawWidth = rawW;
    rawHeight = rawH;
  } else {
    rawWidth = 0;
    rawHeight = 0;
  }

  if (proc != NULL) {
    memcpy(procFrame, proc, OUT_W * OUT_H);
    procValid = true;

    uint8_t lo = 255;
    uint8_t hi = 0;
    uint32_t sum = 0;

    for (int i = 0; i < OUT_W * OUT_H; i++) {
      uint8_t v = procFrame[i];

      if (v < lo) {
        lo = v;
      }

      if (v > hi) {
        hi = v;
      }

      sum += v;
    }

    procMin = lo;
    procMax = hi;
    procMean = (uint8_t)(sum / (OUT_W * OUT_H));
  }

  frameCount++;
}

void webDebugSetResult(const int8_t *logits, int idx, int margin, bool valid) {
  if (logits != NULL) {
    memcpy(lastLogits, logits, FPGA_NUM_CLASS);
  }

  lastIdx = idx;
  lastMargin = margin;
  lastValid = valid;
}
