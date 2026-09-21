"""5. Waar knikt het? Een meting, geen aanval.

Korte stoten met oplopende gelijktijdigheid, met rust ertussen, zodat dit de
dienst niet langer raakt dan de meting duurt. Wat we zoeken is niet "hoeveel kan
hij aan" maar "wat doet hij als het te veel wordt": netjes weigeren is goed,
stilstaan tot de browser opgeeft is slecht.
"""
import sys, os, statistics, concurrent.futures as cf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harnas import *

token = inloggen()
print("== 5. Gedrag onder belasting ==\n")
print(f"  {'gelijktijdig':>12} {'ok':>4} {'4xx':>4} {'5xx':>4} {'stuk':>5} "
      f"{'mediaan':>9} {'p95':>9} {'traagst':>9}")

def meet(niveau, pad="/auth/me", n=None, timeout=30):
    n = n or niveau * 2
    with cf.ThreadPoolExecutor(max_workers=niveau) as pool:
        res = [f.result() for f in [pool.submit(roep, "GET", pad, None, token, None, timeout)
                                    for _ in range(n)]]
    st = Counter(s for s, _, _, _ in res)
    tijden = sorted(dt for s, _, dt, _ in res if s)
    ok = sum(v for k, v in st.items() if 200 <= k < 300)
    v4 = sum(v for k, v in st.items() if 400 <= k < 500)
    v5 = sum(v for k, v in st.items() if k >= 500)
    stuk = st.get(0, 0)
    med = statistics.median(tijden) if tijden else float("nan")
    p95 = tijden[int(len(tijden) * 0.95) - 1] if tijden else float("nan")
    traag = tijden[-1] if tijden else float("nan")
    print(f"  {niveau:>12} {ok:>4} {v4:>4} {v5:>4} {stuk:>5} "
          f"{med*1000:>7.0f}ms {p95*1000:>7.0f}ms {traag*1000:>7.0f}ms")
    return {"niveau": niveau, "ok": ok, "4xx": v4, "5xx": v5, "stuk": stuk,
            "mediaan_ms": med * 1000, "p95_ms": p95 * 1000}

metingen = []
for niveau in (1, 2, 5, 10, 20, 40):
    metingen.append(meet(niveau))
    time.sleep(4)

print()
json.dump(metingen, open(os.path.join(os.path.dirname(HIER), "belasting.json"), "w"), indent=1)
