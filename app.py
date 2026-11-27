import json, os, time, math, random, threading, urllib.request, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from datetime import datetime, timezone

PORT = int(os.environ.get("PORT", "10000"))
HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(HERE, "state.json")
LOCK = threading.Lock()

DEFAULTS = {"risk": "equilibrado", "capital": 1000.0, "level0": True,
            "llm_key": os.environ.get("LLM_API_KEY", ""),
            "llm_model": os.environ.get("LLM_MODEL", "llama-3.3-70b")}
PROFILE = {"conservador": 0.6, "equilibrado": 1.0, "agresivo": 1.6}
EQUITIES = ["AAPL","MSFT","NVDA","AMZN","META","GOOGL","TSLA","AVGO","AMD","NFLX",
            "CRM","ORCL","ADBE","QCOM","INTC","MU","PLTR","SNOW","SHOP","COIN",
            "MSTR","SPY","QQQ","GLD","SLV","USO","EURUSD=X","GBPUSD=X","JPY=X"]
UA = {"User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"}
CACHE = {"ts": 0, "data": None}

def load():
    try:
        with open(STATE) as f: return json.load(f)
    except Exception:
        return {"settings": dict(DEFAULTS), "pf": {"cash": 1000.0, "positions": {}, "hist": []},
                "last": None, "arena": []}

def save(s):
    try:
        with open(STATE, "w") as f: json.dump(s, f)
    except Exception: pass

def fetch(url, headers=None, timeout=15):
    req = urllib.request.Request(url, headers=headers or UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())

def series(sym):
    try:
        if sym.startswith("CRYPTO:"):
            cid = sym.split(":", 1)[1]
            d = fetch(f"https://api.coingecko.com/api/v3/coins/{cid}/market_chart?vs_currency=usd&days=30",
                      {"User-Agent": "kairos"})
            p = [x[1] for x in d.get("prices", [])]
            v = [x[1] for x in d.get("total_volumes", [])]
            if len(p) < 60: return None
            return {"closes": p[-400:], "vols": v[-400:], "price": p[-1]}
        d = fetch(f"https://query1.finance.yahoo.com/v8/finance/chart/{urllib.parse.quote(sym)}?range=6mo&interval=1d")
        res = d["chart"]["result"][0]
        q = res["indicators"]["quote"][0]
        closes = [c for c in q["close"] if c]
        vols = [v or 0 for v in q["volume"]]
        if len(closes) < 60: return None
        return {"closes": closes[-400:], "vols": vols[-400:], "price": closes[-1]}
    except Exception:
        return None

def rsi(cl, n=14):
    if len(cl) < n + 1: return 50.0
    g = [max(0, cl[i] - cl[i-1]) for i in range(1, len(cl))]
    l = [max(0, cl[i-1] - cl[i]) for i in range(1, len(cl))]
    ag = sum(g[-n:]) / n or 1e-9
    al = sum(l[-n:]) / n or 1e-9
    return 100 - 100 / (1 + ag / al)

def ema(cl, n):
    k = 2 / (n + 1); e = cl[0]
    for x in cl[1:]: e = x * k + e * (1 - k)
    return e

def atr(cl, n=14):
    tr = [abs(cl[i] - cl[i-1]) for i in range(1, len(cl))]
    return sum(tr[-n:]) / n if tr else cl[-1] * 0.02

def universe():
    out = []
    try:
        d = fetch("https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&order=market_cap_desc&per_page=60&page=1&price_change_percentage=24h",
                  {"User-Agent": "kairos"})
        for c in d:
            if (c.get("total_volume") or 0) < 20_000_000: continue
            out.append(("CRYPTO:" + c["id"], "crypto", c["symbol"].upper(), c.get("price_change_percentage_24h") or 0))
    except Exception: pass
    for s in EQUITIES:
        m = "forex" if s.endswith("=X") else "equity"
        out.append((s, m, s, 0))
    return out

def scan():
    sigs, rejected = [], []
    for sym, market, label, chg in universe():
        d = series(sym)
        if not d: continue
        cl = d["closes"]; price = d["price"]
        a = atr(cl)
        if price <= 0 or a / price < 0.004: continue
        e20, e50 = ema(cl[-50:], 20), ema(cl[-120:], 50)
        r = rsi(cl)
        mom = (price / cl[-8] - 1) * 100 if len(cl) > 8 else 0
        vmean = sum(d["vols"][-30:]) / 30 or 1
        vz = d["vols"][-1] / vmean
        trend_up = price > e50
        score = 0.0
        if trend_up: score += 0.3
        if e20 > e50: score += 0.15
        if 45 < r < 70: score += 0.15
        if r > 75: score -= 0.1
        if mom > 0: score += min(0.2, mom / 40)
        if vz > 1.2: score += 0.1
        direction = "long" if score >= 0.45 else ("short" if score <= 0.15 and not trend_up else "flat")
        sigs.append({"symbol": label, "key": sym, "market": market, "direction": direction,
                     "confidence": round(min(0.95, max(0.05, score)), 2),
                     "price": price, "atr": a, "rsi": round(r, 1),
                     "mom": round(mom, 2), "trend": "alcista" if trend_up else "bajista",
                     "volz": round(vz, 2)})
    sigs.sort(key=lambda s: s["confidence"], reverse=True)
    return sigs[:30], rejected

THESIS = {
 "long": "Tendencia {t} con impulso de {m}% en la semana y volumen {v}x sobre su media.",
 "short": "Precio por debajo de su media de 50 velas, momentum {m}% y sin soporte cercano.",
 "flat": "Sin dirección clara: RSI {r} y volumen flojo. Se vigila.",
}
RED = {
 "long": "Puede agotarse: RSI en {r}. Si pierde {stop} se cierra sin discutir.",
 "short": "Un rebote de manual la tumba: el mercado lleva días subiendo.",
 "flat": "No hay señal, entrar aquí es apostar.",
}

def llm(system, user, s):
    if not s["settings"].get("llm_key"): return None
    try:
        body = json.dumps({"model": s["settings"]["llm_model"],
                           "messages": [{"role": "system", "content": system},
                                        {"role": "user", "content": user}],
                           "temperature": 0.3}).encode()
        req = urllib.request.Request("https://api.venice.ai/api/v1/chat/completions", data=body,
              headers={"Content-Type": "application/json",
                       "Authorization": "Bearer " + s["settings"]["llm_key"]})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode())["choices"][0]["message"]["content"]
    except Exception:
        return None

def red_team(sigs, s):
    live = [x for x in sigs if x["direction"] != "flat"][:8]
    txt = llm("Eres el abogado del diablo de un trader. Para cada señal da UNA razón corta en español de por qué puede fallar. Formato: SYMBOL: razón",
              json.dumps([{"s": x["symbol"], "d": x["direction"], "rsi": x["rsi"]} for x in live]), s)
    kills = {}
    if txt:
        for line in txt.splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                kills[k.strip().upper()] = v.strip()
    for x in sigs:
        x["redteam"] = kills.get(x["symbol"]) or RED[x["direction"]].format(r=x["rsi"], stop="el stop")
        x["thesis"] = THESIS[x["direction"]].format(t=x["trend"], m=x["mom"], v=x["volz"], r=x["rsi"])
        if x["direction"] != "flat" and ("agotad" in x["redteam"].lower() or "divergencia" in x["redteam"].lower()):
            x["survives"] = False
        else:
            x["survives"] = x["confidence"] > 0.5
    return sigs

def risk_gate(sigs, s):
    st = s["settings"]
    mult = PROFILE.get(st["risk"], 1.0)
    budget = float(st["capital"]) * 0.01 * mult
    ok, no = [], []
    for x in [y for y in sigs if y.get("survives")]:
        if len(ok) >= 6: no.append({**x, "why": "límite de 6 posiciones"}); continue
        dist = x["atr"] * 1.5
        if dist / x["price"] > 0.07: no.append({**x, "why": "stop demasiado ancho"}); continue
        size = min(budget / dist, float(st["capital"]) * 0.25 / x["price"])
        if size * x["price"] < 5: no.append({**x, "why": "posición menor a 5 USD"}); continue
        sgn = 1 if x["direction"] == "long" else -1
        x["size"] = round(size, 6)
        x["stop"] = round(x["price"] - sgn * dist, 6)
        x["target"] = round(x["price"] + sgn * dist * 2, 6)
        ok.append(x)
    return ok, no

def manage(s, approved):
    pf = s["pf"]; fills = []
    for sym in list(pf["positions"].keys()):
        p = pf["positions"][sym]
        cur = next((x["price"] for x in approved + s.get("_all", []) if x["symbol"] == sym), p["entry"])
        hit = (p["dir"] == "long" and (cur <= p["stop"] or cur >= p["target"])) or \
              (p["dir"] == "short" and (cur >= p["stop"] or cur <= p["target"]))
        if hit:
            pnl = (cur - p["entry"]) * p["size"] * (1 if p["dir"] == "long" else -1)
            pf["cash"] += p["size"] * cur
            pf["hist"].append({"symbol": sym, "pnl": round(pnl, 2), "at": datetime.now(timezone.utc).isoformat()})
            del pf["positions"][sym]
            fills.append({"symbol": sym, "accion": "cierre", "pnl": round(pnl, 2)})
    for x in approved:
        if x["symbol"] in pf["positions"]: continue
        cost = x["size"] * x["price"] * 1.0006
        if cost > pf["cash"]: continue
        pf["cash"] -= cost
        pf["positions"][x["symbol"]] = {"entry": x["price"], "size": x["size"],
                                        "stop": x["stop"], "target": x["target"], "dir": x["direction"]}
        fills.append({"symbol": x["symbol"], "accion": "apertura " + x["direction"]})
    return fills

def equity(pf, marks):
    return pf["cash"] + sum(p["size"] * marks.get(k, p["entry"]) for k, p in pf["positions"].items())

def run():
    with LOCK:
        s = load()
        sigs, _ = scan()
        sigs = red_team(sigs, s)
        approved, rejected = risk_gate(sigs, s)
        s["_all"] = sigs
        fills = manage(s, approved)
        marks = {x["symbol"]: x["price"] for x in sigs}
        eq = equity(s["pf"], marks)
        top = approved[:3]
        base = f"Hoy el radar revisó {len(sigs)} mercados y aprobó {len(approved)} ideas. "
        if top:
            base += "Destacan " + ", ".join(x["symbol"] for x in top) + ". "
        else:
            base += "Casi todo quedó fuera por falta de condiciones. "
        base += f"Tu capital ficticio vale {eq:.2f} dólares. "
        base += "Recuerda: esto es papel, no dinero real."
        narr = llm("Eres un coach de finanzas para principiantes absolutos. Reescribe en 5 frases cortas, español neutro, sin jerga, qué pasó hoy y qué mirar mañana.", base, s) or base
        scenes = [{"title": "RADAR DEL DÍA", "text": f"Revisamos {len(sigs)} mercados."}]
        for x in top:
            scenes.append({"title": x["symbol"] + " · " + x["direction"].upper(),
                           "text": f"{x['symbol']} en {x['direction']}. {x['thesis']} Riesgo: {x['redteam']}"})
        scenes.append({"title": "CIERRE", "text": "Capital simulado " + f"{eq:.0f} dólares. Esto no es consejo financiero."})
        s["last"] = {"at": datetime.now(timezone.utc).isoformat(), "signals": sigs,
                     "approved": approved, "rejected": rejected, "fills": fills,
                     "equity": round(eq, 2), "cash": round(s["pf"]["cash"], 2),
                     "narrative": narr, "scenes": scenes}
        s.pop("_all", None)
        save(s)
        return s["last"]

def arena(s):
    syms = ["SPY", "QQQ", "AAPL", "NVDA", "MSFT"]
    data = {k: series(k) for k in syms}
    data = {k: v for k, v in data.items() if v}
    if not data: return []
    board = []
    for i in range(12):
        fast = random.randint(4, 20); slow = random.randint(25, 70)
        rets = []
        for v in data.values():
            cl = v["closes"]; pos = 0; eq = 1.0; peak = 1.0; dd = 0
            for j in range(slow, len(cl)):
                f = ema(cl[:j], fast); sl = ema(cl[:j], slow)
                pos = 1 if f > sl else 0
                eq *= 1 + pos * (cl[j] / cl[j-1] - 1)
                peak = max(peak, eq); dd = min(dd, eq / peak - 1)
            rets.append((eq - 1, dd))
        avg = sum(r[0] for r in rets) / len(rets)
        mdd = min(r[1] for r in rets)
        board.append({"genoma": i + 1, "fast": fast, "slow": slow,
                      "rendimiento": round(avg * 100, 2), "drawdown": round(mdd * 100, 2),
                      "puntos": round(avg * 100 + mdd * 100, 2)})
    board.sort(key=lambda x: x["puntos"], reverse=True)
    s["arena"] = board
    save(s)
    return board

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send_json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path in ("/", "/index.html"):
            b = HTML.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers(); self.wfile.write(b); return
        if self.path == "/manifest.json":
            m = {"name": "KAIROS", "short_name": "KAIROS", "start_url": "/",
                 "display": "standalone", "background_color": "#07101a",
                 "theme_color": "#07101a", "icons": []}
            return self.send_json(m)
        s = load()
        if self.path == "/api/settings":
            st = dict(s["settings"]); st["llm_key"] = "***" if st["llm_key"] else ""
            return self.send_json(st)
        if self.path == "/api/last":
            return self.send_json(s.get("last") or {})
        if self.path == "/api/radar":
            if CACHE["data"] and time.time() - CACHE["ts"] < 600:
                return self.send_json(CACHE["data"])
            d = run(); CACHE.update(ts=time.time(), data=d); return self.send_json(d)
        if self.path == "/api/arena":
            return self.send_json({"board": arena(s), "hist": s.get("arena", [])})
        self.send_json({"error": "no existe"}, 404)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        s = load()
        if self.path == "/api/settings":
            for k in ("risk", "capital", "level0", "llm_key", "llm_model"):
                if k in body:
                    s["settings"][k] = body[k]
            if "capital" in body: s["pf"]["cash"] = float(body["capital"])
            save(s); return self.send_json({"ok": True})
        if self.path == "/api/reset":
            s["pf"] = {"cash": float(s["settings"]["capital"]), "positions": {}, "hist": []}
            save(s); return self.send_json({"ok": True})
        if self.path == "/api/run":
            d = run(); CACHE.update(ts=time.time(), data=d); return self.send_json(d)
        self.send_json({"error": "no existe"}, 404)

HTML = r"""<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<link rel="manifest" href="/manifest.json"><title>KAIROS</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent}
body{background:#07101a;color:#e6eef6;font:16px/1.5 -apple-system,system-ui,sans-serif;padding-bottom:88px}
header{padding:18px 16px 10px;border-bottom:1px solid #14283a;position:sticky;top:0;background:#07101a;z-index:9}
h1{font-size:20px;letter-spacing:2px}h1 span{color:#3ddc97}
.sub{font-size:12px;color:#7a8fa3;margin-top:2px}
main{padding:14px}
.card{background:#0c1a28;border:1px solid #14283a;border-radius:14px;padding:14px;margin-bottom:10px}
.row{display:flex;justify-content:space-between;align-items:center;gap:8px}
.sym{font-weight:700;font-size:17px}
.tag{font-size:11px;padding:2px 8px;border-radius:99px;font-weight:600}
.long{background:#0d3b28;color:#3ddc97}.short{background:#3b1414;color:#ff7b72}.flat{background:#1b2836;color:#7a8fa3}
.bar{height:5px;background:#14283a;border-radius:9px;margin:9px 0;overflow:hidden}
.bar i{display:block;height:100%;background:linear-gradient(90deg,#3ddc97,#3d9bdc)}
.txt{font-size:14px;color:#b9c9d8;margin-top:6px}
.warn{font-size:13px;color:#ffb86b;margin-top:8px;padding-left:10px;border-left:2px solid #ffb86b}
.num{display:flex;gap:14px;margin-top:9px;font-size:12px;color:#7a8fa3;flex-wrap:wrap}
.btn{background:#14283a;border:none;color:#cfe2f2;padding:9px 13px;border-radius:10px;font-size:13px;font-weight:600}
.btn.pri{background:#3ddc97;color:#04120c}
.btn.wide{width:100%;padding:14px;font-size:15px}
nav{position:fixed;bottom:0;left:0;right:0;display:flex;background:#0a1622;border-top:1px solid #14283a;padding-bottom:env(safe-area-inset-bottom)}
nav button{flex:1;background:none;border:none;padding:11px 2px 13px;font-size:10px;color:#5d7387}
nav button.on{color:#3ddc97}
nav b{display:block;font-size:19px;font-weight:400}
h2{font-size:15px;margin:4px 0 10px;color:#9fb4c7;letter-spacing:1px;text-transform:uppercase}
select,input{width:100%;background:#0c1a28;border:1px solid #14283a;color:#e6eef6;padding:12px;border-radius:10px;font-size:15px;margin-top:6px}
label{font-size:13px;color:#8fa4b8;display:block;margin-top:14px}
.pill{display:inline-block;font-size:11px;color:#3ddc97;border:1px solid #1d4a36;padding:2px 8px;border-radius:99px;margin-left:6px}
.stage{background:#0c1a28;border:1px solid #14283a;border-radius:16px;min-height:330px;padding:26px;display:flex;flex-direction:column;justify-content:center;text-align:center}
.stage h3{font-size:24px;margin-bottom:14px;letter-spacing:1px}
.stage p{font-size:17px;color:#cfe2f2;line-height:1.6}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{padding:8px 4px;text-align:left;border-bottom:1px solid #14283a}
th{color:#7a8fa3;font-weight:600;font-size:11px;text-transform:uppercase}
.hide{display:none}
.note{font-size:12px;color:#6b8296;margin-top:10px;line-height:1.5}
</style></head><body>
<header><h1>KAI<span>ROS</span><span class="pill" id="mode">PAPEL</span></h1>
<div class="sub" id="clock">cargando…</div></header>
<main>
<section id="p-radar"><h2>Radar</h2><div id="radar"><p class="note">Analizando mercados… puede tardar 40 s si el servidor estaba dormido.</p></div></section>
<section id="p-arena" class="hide"><h2>Arena de estrategias</h2>
<p class="note">Doce variantes compiten con datos reales del último año. Gana la de mejor rendimiento con menos caída.</p>
<button class="btn wide pri" style="margin-top:12px" onclick="arena()">Lanzar competición</button><div id="board" style="margin-top:14px"></div></section>
<section id="p-pf" class="hide"><h2>Portafolio de papel</h2><div id="pf"></div></section>
<section id="p-video" class="hide"><h2>Video del día</h2>
<div class="stage" id="stage"><h3>PULSA PLAY</h3><p>Se genera el resumen hablado con las tendencias detectadas.</p></div>
<button class="btn wide pri" style="margin-top:12px" onclick="play()">▶︎ Reproducir</button>
<p class="note">Para guardarlo: Centro de control → grabación de pantalla → play.</p></section>
<section id="p-set" class="hide"><h2>Ajustes</h2>
<label>Perfil de riesgo</label>
<select id="risk"><option value="conservador">Conservador</option><option value="equilibrado">Equilibrado</option><option value="agresivo">Agresivo</option></select>
<label>Capital simulado (USD)</label><input id="capital" type="number" inputmode="decimal">
<label>Llave de IA (opcional)</label><input id="key" type="password" placeholder="venice_...">
<label>Modelo</label><input id="model" placeholder="llama-3.3-70b">
<button class="btn wide pri" style="margin-top:18px" onclick="saveS()">Guardar</button>
<button class="btn wide" style="margin-top:8px" onclick="reset()">Reiniciar portafolio</button>
<p class="note">KAIROS opera en papel. No mueve dinero real. Nada de esto es consejo financiero.</p></section>
</main>
<nav>
<button class="on" onclick="go('radar',this)"><b>◎</b>Radar</button>
<button onclick="go('arena',this)"><b>⚔</b>Arena</button>
<button onclick="go('pf',this)"><b>▤</b>Cartera</button>
<button onclick="go('video',this)"><b>▶</b>Video</button>
<button onclick="go('set',this)"><b>⚙</b>Ajustes</button>
</nav>
<script>
let LAST=null, LEVEL=true;
function go(id,el){document.querySelectorAll('main section').forEach(s=>s.classList.add('hide'));
document.getElementById('p-'+id).classList.remove('hide');
document.querySelectorAll('nav button').forEach(b=>b.classList.remove('on'));el.classList.add('on');}
function esc(t){return (t||'').replace(/</g,'&lt;')}
function card(x){
 let h=`<div class="card"><div class="row"><span class="sym">${esc(x.symbol)}</span>
 <span class="tag ${x.direction}">${x.direction.toUpperCase()}</span></div>
 <div class="bar"><i style="width:${Math.round(x.confidence*100)}%"></i></div>
 <div class="txt">${esc(x.thesis)}</div>
 <div class="warn">Qué puede salir mal: ${esc(x.redteam)}</div>
 <div class="num"><span>Entrada ${x.price}</span><span>Stop ${x.stop||'—'}</span><span>Objetivo ${x.target||'—'}</span><span>Tamaño ${x.size||'—'}</span></div></div>`;
 return h;
}
async function radar(){
 const r=await fetch('/api/radar');const d=await r.json();
 if(!d.signals){document.getElementById('radar').innerHTML='<p class="note">Sin datos. Reintenta.</p>';return}
 LAST=d;
 document.getElementById('clock').textContent=new Date().toLocaleString('es-MX');
 document.getElementById('pf').innerHTML=`<div class="card"><div class="row"><span>Capital simulado</span><b>$${d.equity}</b></div>
 <div class="num"><span>Efectivo $${d.cash}</span><span>Abiertas ${Object.keys(d.approved).length}</span></div></div>
 <div class="txt" style="margin:12px 0">${esc(d.narrative)}</div>`+
 d.approved.map(card).join('')+
 (d.rejected.length?`<h2 style="margin-top:18px">Vetadas</h2>`+d.rejected.map(x=>`<div class="card"><div class="row"><span class="sym">${esc(x.symbol)}</span><span class="tag flat">${esc(x.why)}</span></div></div>`).join(''):'');
 document.getElementById('radar').innerHTML=d.approved.length?d.approved.map(card).join(''):'<p class="note">Hoy no hay condiciones claras. Eso también es una respuesta.</p>';
}
async function arena(){
 document.getElementById('board').innerHTML='<p class="note">Simulando…</p>';
 const r=await fetch('/api/arena');const d=await r.json();
 document.getElementById('board').innerHTML='<table><tr><th>#</th><th>Rápida</th><th>Lenta</th><th>Rend.</th><th>Caída</th></tr>'+
 d.board.map(b=>`<tr><td>${b.genoma}</td><td>${b.fast}</td><td>${b.slow}</td><td>${b.rendimiento}%</td><td>${b.drawdown}%</td></tr>`).join('')+'</table>';
}
let voices=[];
speechSynthesis.onvoiceschanged=()=>{voices=speechSynthesis.getVoices()};
function play(){
 if(!LAST){document.getElementById('stage').innerHTML='<h3>ESPERA</h3><p>Abre primero Radar.</p>';return}
 const v=voices.find(v=>v.lang.startsWith('es'))||null;let i=0;
 const st=document.getElementById('stage');
 const step=()=>{
  if(i>=LAST.scenes.length){st.innerHTML='<h3>FIN</h3><p>Vuelve mañana.</p>';return}
  const s=LAST.scenes[i];st.innerHTML=`<h3>${esc(s.title)}</h3><p>${esc(s.text)}</p>`;
  const u=new SpeechSynthesisUtterance(s.text);u.lang='es-MX';u.rate=1.02;if(v)u.voice=v;
  u.onend=()=>{i++;setTimeout(step,600)};speechSynthesis.speak(u);
 };
 step();
}
async function saveS(){
 await fetch('/api/settings',{method:'POST',headers:{'Content-Type':'application/json'},
 body:JSON.stringify({risk:document.getElementById('risk').value,
 capital:parseFloat(document.getElementById('capital').value)||1000,
 llm_key:document.getElementById('key').value||undefined,
 llm_model:document.getElementById('model').value||undefined})});
 alert('Guardado');go('radar',document.querySelector('nav button'));
}
async function reset(){await fetch('/api/reset',{method:'POST'});alert('Portafolio reiniciado');}
(async()=>{
 const s=await (await fetch('/api/settings')).json();
 document.getElementById('risk').value=s.risk;document.getElementById('capital').value=s.capital;
 document.getElementById('model').value=s.llm_model;
 if(s.llm_key)document.getElementById('key').placeholder='llave guardada';
 radar();
})();
</script></body></html>"""

if __name__ == "__main__":
    print("KAIROS en puerto", PORT)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
