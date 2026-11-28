FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg fonts-dejavu-core curl && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir edge-tts
WORKDIR /app
RUN cat > app.py <<'PYEOF'
import json, os, time, math, random, threading, subprocess, tempfile, urllib.request, urllib.parse, urllib.error, secrets
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from datetime import datetime, timezone, timedelta

PORT = int(os.environ.get("PORT", "10000"))
HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(HERE, "state.json")
VID = os.path.join(HERE, "videos")
LOCK = threading.Lock()
os.makedirs(VID, exist_ok=True)

EQUITIES = ["AAPL","MSFT","NVDA","AMZN","META","GOOGL","TSLA","AVGO","AMD","NFLX",
            "CRM","ORCL","ADBE","QCOM","INTC","MU","PLTR","SNOW","SHOP","COIN",
            "MSTR","UBER","ABNB","DIS","JPM","BAC","XOM","CVX","PFE","KO",
            "PEP","WMT","COST","SPY","QQQ","IWM","GLD","SLV","USO","TLT"]
UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}
DEFAULTS = {"mode": "paper", "risk": "equilibrado", "paused": True,
            "ap_paper_key": "", "ap_paper_secret": "", "ap_live_key": "", "ap_live_secret": "",
            "yt_client_id": "", "yt_client_secret": "", "yt_refresh": "", "yt_privacy": "public",
            "llm_key": "", "llm_model": "llama-3.3-70b", "max_daily_loss": 0.03}
PROFILE = {"conservador": 0.5, "equilibrado": 1.0, "agresivo": 1.8}

def load():
    try:
        with open(STATE) as f:
            s = json.load(f)
            for k, v in DEFAULTS.items(): s["settings"].setdefault(k, v)
            return s
    except Exception:
        return {"settings": dict(DEFAULTS), "log": [], "videos": [], "day": ""}

def save(s):
    try:
        with open(STATE, "w") as f: json.dump(s, f)
    except Exception: pass

def fetch(url, headers=None, data=None, method=None, timeout=20):
    req = urllib.request.Request(url, headers=headers or UA, data=data, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
        try: return json.loads(raw.decode())
        except Exception: return raw

class Alpaca:
    def __init__(self, s):
        live = s["settings"]["mode"] == "live"
        self.base = "https://api.alpaca.markets" if live else "https://paper-api.alpaca.markets"
        k = s["settings"]["ap_live_key" if live else "ap_paper_key"]
        sec = s["settings"]["ap_live_secret" if live else "ap_paper_secret"]
        self.h = {"APCA-API-KEY-ID": k, "APCA-API-SECRET-KEY": sec,
                  "Content-Type": "application/json", "accept": "application/json"}
        self.ok = bool(k and sec)
    def get(self, path):
        return fetch(self.base + path, self.h)
    def post(self, path, body):
        return fetch(self.base + path, self.h, json.dumps(body).encode(), "POST")
    def delete(self, path):
        return fetch(self.base + path, self.h, method="DELETE")
    def clock(self):
        try: return self.get("/v2/clock")
        except Exception: return {"is_open": False}
    def account(self):
        try: return self.get("/v2/account")
        except Exception: return {}
    def positions(self):
        try: return self.get("/v2/positions")
        except Exception: return []
    def close(self, sym):
        try: return self.delete(f"/v2/positions/{urllib.parse.quote(sym)}?cancel_orders=true")
        except Exception: return {}
    def close_all(self):
        try: return self.delete("/v2/positions?cancel_orders=true")
        except Exception: return {}
    def order(self, sym, qty, side, typ="market", stop=None, limit=None):
        b = {"symbol": sym, "qty": str(qty), "side": side, "type": typ,
             "time_in_force": "day" if typ == "market" else "gtc"}
        if stop: b["stop_price"] = round(stop, 2)
        if limit: b["limit_price"] = round(limit, 2)
        return self.post("/v2/orders", b)

def bars(sym):
    try:
        d = fetch(f"https://query1.finance.yahoo.com/v8/finance/chart/{urllib.parse.quote(sym)}?range=1y&interval=1d")
        q = d["chart"]["result"][0]["indicators"]["quote"][0]
        c = [x for x in q["close"] if x]
        v = [x or 0 for x in q["volume"]]
        if len(c) < 60: return None
        return {"c": c, "v": v, "p": c[-1]}
    except Exception:
        return None

def rsi(c, n=14):
    if len(c) < n + 1: return 50.0
    g = [max(0, c[i]-c[i-1]) for i in range(1, len(c))]
    l = [max(0, c[i-1]-c[i]) for i in range(1, len(c))]
    ag = sum(g[-n:])/n or 1e-9; al = sum(l[-n:])/n or 1e-9
    return 100 - 100/(1+ag/al)

def ema(c, n):
    k = 2/(n+1); e = c[0]
    for x in c[1:]: e = x*k + e*(1-k)
    return e

def atr(c, n=14):
    tr = [abs(c[i]-c[i-1]) for i in range(1, len(c))]
    return sum(tr[-n:])/n if tr else c[-1]*0.02

def scan():
    out = []
    for sym in EQUITIES:
        d = bars(sym)
        if not d: continue
        c = d["c"]; p = d["p"]; a = atr(c)
        if p <= 0 or a/p < 0.008: continue
        r = rsi(c); m = (p/c[-10]-1)*100
        up = p > ema(c[-150:], 50)
        vm = sum(d["v"][-30:])/30 or 1; vz = d["v"][-1]/vm
        sc = 0.0
        if up: sc += 0.30
        if ema(c[-50:], 20) > ema(c[-150:], 50): sc += 0.15
        if 45 < r < 72: sc += 0.15
        if r > 78: sc -= 0.10
        if m > 0: sc += min(0.20, m/40)
        if vz > 1.2: sc += 0.10
        if sc < 0.45: continue
        out.append({"symbol": sym, "price": p, "atr": a, "rsi": round(r, 1),
                    "mom": round(m, 2), "vol": round(vz, 2), "conf": round(min(0.95, sc), 2),
                    "up": up})
    out.sort(key=lambda x: x["conf"], reverse=True)
    return out[:12]

def size_for(equity, risk_frac, entry, stop):
    dist = abs(entry - stop)
    if dist <= 0: return 0
    qty = (equity * risk_frac) / dist
    cap = (equity * 0.22) / entry
    return round(min(qty, cap), 4)

def enter(a, s, sig, equity):
    mult = PROFILE.get(s["settings"]["risk"], 1.0)
    risk_frac = 0.01 * mult
    stop = sig["price"] - sig["atr"] * 1.6
    target = sig["price"] + sig["atr"] * 3.2
    qty = size_for(equity, risk_frac, sig["price"], stop)
    if qty * sig["price"] < 2: return None
    try:
        o = a.order(sig["symbol"], qty, "buy")
        a.order(sig["symbol"], qty, "sell", "stop", stop=stop)
        a.order(sig["symbol"], qty, "sell", "limit", limit=target)
        return {"symbol": sig["symbol"], "qty": qty, "stop": round(stop, 2), "target": round(target, 2)}
    except Exception as e:
        return {"symbol": sig["symbol"], "error": str(e)[:120]}

def cycle():
    with LOCK:
        s = load()
        st = s["settings"]
        if st["paused"]: return
        a = Alpaca(s)
        if not a.ok: return
        acc = a.account()
        try: eq = float(acc.get("equity", 0))
        except Exception: eq = 0
        if eq <= 0: return
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        if s.get("day") != today:
            s["day"] = today; s["day_start"] = eq; save(s)
        if eq < s.get("day_start", eq) * (1 - st["max_daily_loss"]):
            a.close_all()
            st["paused"] = True
            s["log"].append(f"{today} corte por pérdida diaria, bot pausado")
            save(s); return
        clk = a.clock()
        if not clk.get("is_open"): return
        pos = a.positions()
        if len(pos) >= 6: return
        have = {p["symbol"] for p in pos}
        for sig in scan():
            if len(pos) >= 6: break
            if sig["symbol"] in have: continue
            r = enter(a, s, sig, eq)
            if r and "error" not in r:
                s["log"].append(f"{today} compra {r['symbol']} {r['qty']} stop {r['stop']}")
                have.add(sig["symbol"]); pos.append({"symbol": sig["symbol"]})
        save(s)

def llm(sys_p, usr, s):
    if not s["settings"].get("llm_key"): return None
    try:
        b = json.dumps({"model": s["settings"]["llm_model"], "temperature": 0.4,
                        "messages": [{"role": "system", "content": sys_p},
                                     {"role": "user", "content": usr}]}).encode()
        r = fetch("https://api.venice.ai/api/v1/chat/completions",
                  {"Content-Type": "application/json", "Authorization": "Bearer " + s["settings"]["llm_key"]}, b, "POST", 90)
        return r["choices"][0]["message"]["content"]
    except Exception:
        return None

FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
def wrap(t, n=24):
    w, line, out = [], "", ""
    for word in t.split():
        if len(line) + len(word) + 1 <= n: line = (line + " " + word).strip()
        else: out.append(line); line = word
    if line: out.append(line)
    return out

def scene_png(idx, title, body, d):
    tf = os.path.join(d, f"t{idx}.txt"); bf = os.path.join(d, f"b{idx}.txt")
    open(tf, "w").write(title)
    open(bf, "w").write("\n".join(wrap(body, 22)))
    out = os.path.join(d, f"s{idx}.mp4")
    vf = (f"drawtext=fontfile={FONT}:textfile={tf}:fontcolor=0x3ddc97:fontsize=62:"
          f"x=(w-text_w)/2:y=420,drawtext=fontfile={FONT}:textfile={bf}:fontcolor=white:"
          f"fontsize=50:line_spacing=22:x=(w-text_w)/2:y=620")
    subprocess.run(["ffmpeg", "-y", "-f", "lavfi", "-i", f"color=c=0x07101a:s=1080x1920:d={d}",
                    "-vf", vf, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", "30", out],
                   capture_output=True)
    return out

def make_video():
    s = load()
    a = Alpaca(s)
    acc = a.account() if a.ok else {}
    pos = a.positions() if a.ok else []
    sigs = scan()
    try: eq = float(acc.get("equity", 0))
    except Exception: eq = 0
    pnl = sum(float(p.get("unrealized_pl", 0)) for p in pos)
    base = (f"Hoy el bot revisó {len(EQUITIES)} acciones y tiene {len(pos)} posiciones abiertas. "
            f"Resultado del día {pnl:.0f} dólares. Patrimonio {eq:.0f} dólares.")
    guion = llm("Guionista de Shorts de bolsa en español. 5 frases cortas, gancho fuerte, sin jerga, tono directo. Cierra con que no es consejo financiero.", base, s)
    guion = guion or base
    escenas = [("EL BOT HABLA", base)]
    for x in sigs[:3]:
        escenas.append((x["symbol"], f"Señal de compra en {x['symbol']}. Sube {x['mom']}% en dos semanas, confianza {int(x['conf']*100)}%. Stop en {x['price']-x['atr']*1.6:.2f}."))
    escenas.append(("CIERRE", "Esto no es consejo financiero. Sígueme para el parte de mañana."))
    voz = os.path.join(VID, "voz.mp3")
    txt = " ".join(g for _, g in escenas)
    subprocess.run(["edge-tts", "--voice", "es-MX-JorgeNeural", "--rate=+10%", "--text", txt, "--write-media", voz], capture_output=True)
    dur = 6.0
    try:
        pr = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", voz], capture_output=True, text=True)
        dur = max(3.0, float(pr.stdout.strip()) / len(escenas))
    except Exception: pass
    d = tempfile.mkdtemp()
    parts = [scene_png(i, t, b, d) for i, (t, b) in enumerate(escenas)]
    lst = os.path.join(d, "l.txt")
    open(lst, "w").write("\n".join(f"file '{p}'" for p in parts))
    sil = os.path.join(d, "sil.mp4")
    subprocess.run(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", sil], capture_output=True)
    final = os.path.join(VID, f"video_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M')}.mp4")
    subprocess.run(["ffmpeg", "-y", "-i", sil, "-i", voz, "-c:v", "copy", "-c:a", "aac", "-shortest", final], capture_output=True)
    if os.path.exists(final) and os.path.getsize(final) > 20000:
        s["videos"] = ([{"file": os.path.basename(final), "at": datetime.now(timezone.utc).isoformat(),
                         "title": "Parte del día " + datetime.now().strftime("%d/%m"),
                         "desc": "Parte diario del bot. #shorts #bolsa #inversion"}] + s.get("videos", []))[:20]
        save(s)
        return final
    return None

def yt_token(s):
    st = s["settings"]
    if not (st["yt_client_id"] and st["yt_client_secret"] and st["yt_refresh"]): return None
    b = urllib.parse.urlencode({"client_id": st["yt_client_id"], "client_secret": st["yt_client_secret"],
                                "refresh_token": st["yt_refresh"], "grant_type": "refresh_token"}).encode()
    try:
        r = fetch("https://oauth2.googleapis.com/token", {"Content-Type": "application/x-www-form-urlencoded"}, b, "POST")
        return r["access_token"]
    except Exception:
        return None

def yt_upload(path, title, desc, s):
    tok = yt_token(s)
    if not tok: return "sin autorización de YouTube"
    data = open(path, "rb").read()
    meta = json.dumps({"snippet": {"title": title[:95], "description": desc, "categoryId": "25"},
                       "status": {"privacyStatus": s["settings"]["yt_privacy"], "selfDeclaredMadeForKids": False}}).encode()
    req = urllib.request.Request("https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status",
          data=meta, method="POST",
          headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json",
                   "X-Upload-Content-Type": "video/mp4", "X-Upload-Content-Length": str(len(data))})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            loc = r.headers["Location"]
        req2 = urllib.request.Request(loc, data=data, method="PUT",
              headers={"Content-Type": "video/mp4", "Content-Length": str(len(data))})
        with urllib.request.urlopen(req2, timeout=300) as r2:
            return json.loads(r2.read().decode()).get("id", "subido")
    except Exception as e:
        return str(e)[:120]

def video_job():
    s = load()
    p = make_video()
    if not p: return
    r = yt_upload(p, "Parte del día " + datetime.now().strftime("%d/%m"),
                  "Parte diario automático. No es consejo financiero. #shorts #bolsa #inversion", s)
    s = load(); s["log"].append("video subido: " + str(r)); save(s)

def scheduler():
    last_video = ""
    while True:
        try:
            now = datetime.now(timezone.utc)
            if now.hour == 21 and now.minute < 10 and last_video != now.strftime("%Y-%m-%d"):
                last_video = now.strftime("%Y-%m-%d"); video_job()
            cycle()
        except Exception as e:
            pass
        time.sleep(300)

HTML = r"""<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes"><link rel="manifest" href="/manifest.json">
<title>KAIROS</title><style>
*{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent}
body{background:#07101a;color:#e6eef6;font:16px/1.5 -apple-system,system-ui,sans-serif;padding-bottom:92px}
header{padding:16px;border-bottom:1px solid #14283a;position:sticky;top:0;background:#07101a;z-index:9}
h1{font-size:19px;letter-spacing:2px}h1 span{color:#3ddc97}
.badge{font-size:11px;padding:3px 9px;border-radius:99px;font-weight:700;margin-left:8px}
.pap{background:#1b2836;color:#7a8fa3}.real{background:#3ddc97;color:#04120c}
main{padding:14px}
.card{background:#0c1a28;border:1px solid #14283a;border-radius:14px;padding:14px;margin-bottom:10px}
.row{display:flex;justify-content:space-between;align-items:center;gap:8px}
.big{font-size:28px;font-weight:700}
.tag{font-size:11px;padding:2px 8px;border-radius:99px;font-weight:700;background:#0d3b28;color:#3ddc97}
.tag.neg{background:#3b1414;color:#ff7b72}
.bar{height:5px;background:#14283a;border-radius:9px;margin:9px 0;overflow:hidden}
.bar i{display:block;height:100%;background:linear-gradient(90deg,#3ddc97,#3d9bdc)}
.txt{font-size:14px;color:#b9c9d8;margin-top:6px}
.num{display:flex;gap:12px;margin-top:8px;font-size:12px;color:#7a8fa3;flex-wrap:wrap}
.btn{background:#14283a;border:none;color:#cfe2f2;padding:11px 14px;border-radius:10px;font-size:14px;font-weight:600}
.btn.pri{background:#3ddc97;color:#04120c}.btn.red{background:#3b1414;color:#ff7b72}
.btn.wide{width:100%;padding:15px;font-size:15px;margin-top:8px}
nav{position:fixed;bottom:0;left:0;right:0;display:flex;background:#0a1622;border-top:1px solid #14283a;padding-bottom:env(safe-area-inset-bottom)}
nav button{flex:1;background:none;border:none;padding:10px 2px 12px;font-size:10px;color:#5d7387}
nav button.on{color:#3ddc97}nav b{display:block;font-size:18px;font-weight:400}
h2{font-size:14px;margin:14px 0 8px;color:#9fb4c7;letter-spacing:1px;text-transform:uppercase}
input,select{width:100%;background:#0c1a28;border:1px solid #14283a;color:#e6eef6;padding:12px;border-radius:10px;font-size:15px;margin-top:6px}
label{font-size:13px;color:#8fa4b8;display:block;margin-top:12px}
.hide{display:none}.note{font-size:12px;color:#6b8296;margin-top:8px;line-height:1.5}
video{width:100%;border-radius:14px;background:#000}
</style></head><body>
<header><h1>KAI<span>ROS</span><span class="badge pap" id="mode">—</span></h1>
<div class="note" id="st">cargando</div></header>
<main>
<section id="p-cuenta"><h2>Cuenta</h2><div id="cuenta"></div>
<button class="btn wide" onclick="act('pause')" id="pb">Pausar</button>
<button class="btn wide red" onclick="act('closeall')">Cerrar todas las posiciones</button></section>
<section id="p-radar" class="hide"><h2>Señales de hoy</h2><div id="radar"></div></section>
<section id="p-video" class="hide"><h2>Video</h2><div id="vid"></div>
<button class="btn wide pri" onclick="act('video')">Generar video ahora</button>
<p class="note">Se sube solo a YouTube a las 21:00 UTC si conectaste la cuenta.</p></section>
<section id="p-set" class="hide"><h2>Ajustes</h2>
<label>Modo</label><select id="mode_s"><option value="paper">Simulación</option><option value="live">Dinero real</option></select>
<label>Perfil de riesgo</label><select id="risk"><option value="conservador">Conservador</option><option value="equilibrado">Equilibrado</option><option value="agresivo">Agresivo</option></select>
<label>Alpaca · llave de papel</label><input id="pk" placeholder="PK...">
<label>Alpaca · secreto de papel</label><input id="ps" type="password" placeholder="••••">
<label>Alpaca · llave real</label><input id="lk" placeholder="AK...">
<label>Alpaca · secreto real</label><input id="ls" type="password" placeholder="••••">
<label>YouTube · Client ID</label><input id="yc" placeholder="...apps.googleusercontent.com">
<label>YouTube · Client Secret</label><input id="ys" type="password">
<label>Privacidad</label><select id="yp"><option value="public">Público</option><option value="unlisted">Oculto</option><option value="private">Privado</option></select>
<button class="btn wide pri" onclick="saveS()">Guardar</button>
<button class="btn wide" onclick="location.href='/oauth/start'">Conectar YouTube</button>
<p class="note">El bot opera solo en horario de mercado. Corte automático al 3% de pérdida diaria.</p></section>
</main>
<nav>
<button class="on" onclick="go('cuenta',this)"><b>▤</b>Cuenta</button>
<button onclick="go('radar',this)"><b>◎</b>Radar</button>
<button onclick="go('video',this)"><b>▶</b>Video</button>
<button onclick="go('set',this)"><b>⚙</b>Ajustes</button>
</nav>
<script>
function go(i,e){document.querySelectorAll('main section').forEach(s=>s.classList.add('hide'));
document.getElementById('p-'+i).classList.remove('hide');
document.querySelectorAll('nav button').forEach(b=>b.classList.remove('on'));e.classList.add('on');if(i==='cuenta')load()}
function esc(t){return (t||'').replace(/</g,'&lt;')}
async function load(){
 const d=await (await fetch('/api/state')).json();
 document.getElementById('mode').textContent=d.mode==='live'?'DINERO REAL':'SIMULACIÓN';
 document.getElementById('mode').className='badge '+(d.mode==='live'?'real':'pap');
 document.getElementById('st').textContent=d.msg;
 document.getElementById('pb').textContent=d.paused?'Reanudar':'Pausar';
 document.getElementById('cuenta').innerHTML=`<div class="card"><div class="txt">Patrimonio</div>
 <div class="big">$${d.equity}</div><div class="num"><span>Hoy ${d.pnl>=0?'+':''}${d.pnl}</span><span>Efectivo $${d.cash}</span></div></div>`+
 (d.pos.length?d.pos.map(p=>`<div class="card"><div class="row"><span><b>${esc(p.symbol)}</b></span>
 <span class="tag ${p.pl<0?'neg':''}">${p.pl>=0?'+':''}${p.pl} $</span></div>
 <div class="num"><span>${p.qty} uds</span><span>Entrada ${p.entry}</span><span>Actual ${p.cur}</span></div></div>`).join('')
 :'<p class="note">Sin posiciones abiertas.</p>');
 document.getElementById('radar').innerHTML=d.sig.length?d.sig.map(x=>`<div class="card">
 <div class="row"><span><b>${esc(x.symbol)}</b></span><span class="tag">${x.conf*100|0}%</span></div>
 <div class="bar"><i style="width:${x.conf*100|0}%"></i></div>
 <div class="txt">Impulso ${x.mom}% · RSI ${x.rsi} · volumen ${x.vol}x</div>
 <div class="num"><span>Entrada ${x.price}</span><span>Stop ${(x.price-x.atr*1.6).toFixed(2)}</span></div></div>`).join('')
 :'<p class="note">Sin señales válidas ahora mismo.</p>';
 document.getElementById('vid').innerHTML=d.videos.length?`<video controls src="/video/${d.videos[0].file}"></video>
 <p class="note">${esc(d.videos[0].title)}</p>`:'<p class="note">Aún no hay videos. Genera uno.</p>';
}
async function act(a){await fetch('/api/'+a,{method:'POST'});load()}
async function saveS(){await fetch('/api/settings',{method:'POST',headers:{'Content-Type':'application/json'},
 body:JSON.stringify({mode:mode_s.value,risk:risk.value,ap_paper_key:pk.value,ap_paper_secret:ps.value,
 ap_live_key:lk.value,ap_live_secret:ls.value,yt_client_id:yc.value,yt_client_secret:ys.value,yt_privacy:yp.value})});
 alert('Guardado');load()}
(async()=>{const s=await (await fetch('/api/settings')).json();
 mode_s.value=s.mode;risk.value=s.risk;yp.value=s.yt_privacy;
 if(s.has_paper)pk.placeholder='configurada';if(s.has_yt)yc.placeholder='configurada';
 load();setInterval(load,60000)})();
</script></body></html>"""

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def js(self, o, c=200):
        b = json.dumps(o).encode(); self.send_response(c)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def raw(self, b, ct):
        self.send_response(200); self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        p = self.path.split("?")[0]
        if p in ("/", "/index.html"): return self.raw(HTML.encode(), "text/html; charset=utf-8")
        if p == "/manifest.json": return self.js({"name": "KAIROS", "short_name": "KAIROS", "start_url": "/", "display": "standalone", "background_color": "#07101a", "theme_color": "#07101a", "icons": []})
        if p.startswith("/video/"):
            f = os.path.join(VID, os.path.basename(p))
            if os.path.exists(f): return self.raw(open(f, "rb").read(), "video/mp4")
            return self.js({"e": 1}, 404)
        if p == "/api/settings":
            st = load()["settings"]
            return self.js({"mode": st["mode"], "risk": st["risk"], "yt_privacy": st["yt_privacy"],
                            "has_paper": bool(st["ap_paper_key"]), "has_yt": bool(st["yt_client_id"])})
        if p == "/api/state":
            s = load(); a = Alpaca(s)
            acc = a.account() if a.ok else {}
            pos = a.positions() if a.ok else []
            try: eq = float(acc.get("equity", 0)); cash = float(acc.get("cash", 0))
            except Exception: eq = cash = 0
            pl = sum(float(x.get("unrealized_pl", 0)) for x in pos)
            msg = "sin llaves de Alpaca" if not a.ok else ("pausado" if s["settings"]["paused"] else "operando")
            return self.js({"mode": s["settings"]["mode"], "paused": s["settings"]["paused"],
                            "equity": round(eq, 2), "cash": round(cash, 2), "pnl": round(pl, 2), "msg": msg,
                            "pos": [{"symbol": x["symbol"], "qty": x["qty"], "entry": x["avg_entry_price"],
                                     "cur": x["current_price"], "pl": round(float(x["unrealized_pl"]), 2)} for x in pos],
                            "sig": scan(), "videos": s.get("videos", [])})
        if p == "/oauth/start":
            s = load(); st = s["settings"]
            if not st["yt_client_id"]: return self.raw(b"falta client id", "text/plain")
            red = f"https://{self.headers['Host']}/oauth/cb"
            q = urllib.parse.urlencode({"client_id": st["yt_client_id"], "redirect_uri": red, "response_type": "code",
                                        "scope": "https://www.googleapis.com/auth/youtube.upload", "access_type": "offline",
                                        "prompt": "consent", "state": "k"})
            self.send_response(302); self.send_header("Location", "https://accounts.google.com/o/oauth2/v2/auth?" + q); self.end_headers(); return
        if p.startswith("/oauth/cb"):
            code = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("code", [""])[0]
            s = load(); st = s["settings"]
            b = urllib.parse.urlencode({"code": code, "client_id": st["yt_client_id"], "client_secret": st["yt_client_secret"],
                                        "redirect_uri": f"https://{self.headers['Host']}/oauth/cb",
                                        "grant_type": "authorization_code"}).encode()
            try:
                r = fetch("https://oauth2.googleapis.com/token", {"Content-Type": "application/x-www-form-urlencoded"}, b, "POST")
                s["settings"]["yt_refresh"] = r["refresh_token"]; save(s)
                return self.raw("<h3>YouTube conectado</h3><a href='/'>Volver</a>".encode(), "text/html")
            except Exception as e:
                return self.raw(f"<h3>Error</h3><pre>{e}</pre>".encode(), "text/html")
        self.js({"e": 1}, 404)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        s = load()
        if self.path == "/api/settings":
            for k, v in body.items():
                if k in s["settings"] and v: s["settings"][k] = v
            save(s); return self.js({"ok": 1})
        if self.path == "/api/pause":
            s["settings"]["paused"] = not s["settings"]["paused"]; save(s); return self.js({"ok": 1})
        if self.path == "/api/closeall":
            Alpaca(s).close_all(); return self.js({"ok": 1})
        if self.path == "/api/video":
            threading.Thread(target=video_job, daemon=True).start(); return self.js({"ok": 1})
        self.js({"e": 1}, 404)

threading.Thread(target=scheduler, daemon=True).start()
print("KAIROS", PORT)
ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
PYEOF
EXPOSE 10000
CMD ["python", "app.py"]
