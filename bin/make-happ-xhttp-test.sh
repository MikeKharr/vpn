#!/usr/bin/env bash
# Собирает ТЕСТОВЫЙ профиль Happ «TH mobile TEST»: один outbound VLESS по
# транспорту XHTTP поверх REALITY в ЗАПАСНОЙ вход th1 (45.91.134.19:443, через
# единицу `sni` проекта zpq-ai), без балансировщика и без Vision. Это шаг 2
# ADR 2026-10-07-0920: проверка, проходит ли на российской мобильной сети
# больше 15 КБ, пока рабочий путь там замерзает.
#
# Запускает ВЛАДЕЛЕЦ на своей машине. Файл кладётся в ~/.config/vpn и
# импортируется в Happ через буфер обмена (README, «Тестовый профиль XHTTP»).
#
# ПОЧЕМУ ЭТО ОТДЕЛЬНЫЙ ФАЙЛ, а не режим bin/make-happ-json.sh. Рабочий профиль
# «TH failover» уже импортирован на двух устройствах, и его переимпорт в поездке
# рвёт туннель, то есть требует рабочего VPN, чтобы восстановить VPN (ADR
# 2026-10-05-2223, «Последствия»). Решение владельца 2026-10-07 — «давай делать
# в виде отдельного профиля», поэтому выход make-happ-json.sh обязан остаться
# прежним БАЙТ В БАЙТ; отдельный файл делает это свойством устройства дерева, а
# не обещанием автора. Общего кода у двух сборок почти нет: здесь нет пары
# ключей th2, нет балансировщика и нет observatory.
#
# Что этот скрипт НЕ делает, намеренно:
#   - не печатает ни одного значения: в stdout уходит РОВНО путь к файлу,
#     приглашения и сообщения — в stderr;
#   - не кладёт значения в аргументы ни одного процесса: ссылка уходит в python
#     по stdin, иначе её было бы видно в `ps` (то же соображение, что в
#     bin/make-link.sh, bin/make-happ-json.sh и deploy/render/render.sh);
#   - НЕ ЧИТАЕТ И НЕ СОЗДАЁТ ~/.config/vpn/th2-reality.key: th2 в этом
#     эксперименте не участвует вовсе;
#   - не трогает ~/.config/vpn/happ-failover.json — рабочий профиль;
#   - не ходит на сервер и ничего оттуда не читает.
#
# Запуск:  bash bin/make-happ-xhttp-test.sh
set -euo pipefail
umask 077

D="$HOME/.config/vpn"
mkdir -p "$D"
# chmod на СУЩЕСТВУЮЩИЙ каталог: umask на него не действует, а каталог мог
# родиться 0755 раньше и не этим скриптом.
chmod 700 "$D"
OUT="$D/happ-xhttp-test.json"

# Ссылка ЗАПАСНОГО профиля th1 (`bin/make-link.sh <устройство> th1`, вторая из
# двух — на адрес 45.91.134.19): из неё берутся UUID, shortId, отпечаток и
# публичный ключ th1. Годится и рабочая ссылка th1 — различаются они только
# адресом, а адрес здесь свой. Ввод скрыт.
printf 'Ссылка vless:// для th1 (ввод не отображается): ' >&2
# Значение инициализируется ДО `read`: при исчерпанном stdin `read` не
# присваивает переменную вовсе, и `set -u` оборвал бы скрипт на `case` с
# «unbound variable» вместо названной причины отказа.
LINK=''
IFS= read -rs LINK || true
printf '\n' >&2
case "$LINK" in
  vless://*) ;;
  *) printf 'ОШИБКА: это не ссылка vless://\n' >&2; exit 1 ;;
esac

# Сборка JSON. Значение идёт в python по stdin, путь — аргументом: путь не
# секрет, значение — секрет.
printf '%s\n' "$LINK" | python3 -c '
import sys, json, re, urllib.parse as u

def die(msg):
    sys.stderr.write("ОШИБКА: " + msg + "\n")
    raise SystemExit(1)

lines = sys.stdin.read().splitlines()
if not lines:
    die("на вход не пришло ни одной строки — ждалась ссылка th1")
link = lines[0].strip()
p = u.urlparse(link); q = dict(u.parse_qsl(p.query))
uuid = u.unquote(p.username or "")
fp = q.get("fp", "chrome"); sid = q.get("sid", "")
# Проверки формы — здесь, а не в shell: иначе значение пришлось бы сверять
# внешним grep, то есть положить его в аргументы процесса. Ни одно значение
# в сообщение об отказе не попадает.
B64 = r"[A-Za-z0-9_-]{43}"
if not re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}", uuid):
    die("UUID в ссылке не той формы")
if "pbk" not in q:
    die("в ссылке нет pbk — это не ссылка REALITY")
if not re.fullmatch(B64, q["pbk"]):
    die("pbk в ссылке — не 43 знака base64url")
if sid and not re.fullmatch(r"[0-9a-f]{8}", sid):
    die("sid в ссылке — не 8 знаков hex")
pbk = q["pbk"]

# Транспорт. Значения обязаны совпадать с inbound vless-443 в
# deploy/config.template.json, иначе рукопожатия не будет:
#   path          — сервер сверяет его ПРЕФИКСОМ (splithttp/hub.go:103);
#   xPaddingBytes — сервер ПРОВЕРЯЕТ длину набивки клиента на попадание в свой
#                   отрезок (hub.go:142-148), и отрезок здесь тот же 100-3000.
# Режим stream-up выбран на клиенте, а не на сервере: на сервере стоит "auto",
# который принимает все три режима (hub.go:154,199,241), поэтому следующую
# пробу с другим режимом можно поставить правкой ОДНОЙ строки здесь, без PR в
# серверный шаблон. Почему именно stream-up: наверх — один длинный POST, вниз —
# один длинный GET, то есть ни одного постоянного ручейка мелких запросов (это
# дал бы packet-up — ровно то, чего опасается владелец), и при этом сервер
# досылает в поток набивку случайной длины через случайные 20-80 с
# (hub.go:219-228), то есть размеры не ложатся в один рисунок. flow нет:
# Vision работает только на «голом» TLS/REALITY
# (proxy/vless/inbound/inbound.go:581), а сервер с Vision в аккаунте отказал бы
# клиенту без него (там же, :594) — поэтому у этого inbound Vision снят с обеих
# сторон. xmux не задан намеренно: умолчания ядра держат не больше трёх
# соединений, а «больше трёх параллельных рукопожатий к одному SNI» — сам по
# себе признак из разбора ADR.
xhttp = {"path": "/assets/hls/segments", "mode": "stream-up", "xPaddingBytes": "100-3000"}

cfg = {
 "remarks": "TH mobile TEST",
 "log": {"loglevel": "warning"},
 "dns": {"servers": ["https://1.1.1.1/dns-query"], "queryStrategy": "UseIPv4", "tag": "dns-in"},
 "inbounds": [
  {"tag": "socks", "listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": {"udp": True}, "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}},
  {"tag": "http", "listen": "127.0.0.1", "port": 10809, "protocol": "http", "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}}],
 "outbounds": [
  {"tag": "th1-xhttp", "protocol": "vless",
   "settings": {"vnext": [{"address": "45.91.134.19", "port": 443, "users": [{"id": uuid, "encryption": "none"}]}]},
   "streamSettings": {"network": "xhttp", "security": "reality",
     "realitySettings": {"serverName": "cdn.zpq.ai", "fingerprint": fp, "publicKey": pbk, "shortId": sid, "spiderX": "/"},
     "xhttpSettings": xhttp}},
  {"tag": "direct", "protocol": "freedom"},
  {"tag": "block", "protocol": "blackhole"}],
 "routing": {"domainStrategy": "AsIs",
  "rules": [
   {"inboundTag": ["dns-in"], "outboundTag": "th1-xhttp"},
   {"ip": ["geoip:private"], "outboundTag": "direct"},
   {"network": "udp", "port": "443", "outboundTag": "block"},
   {"network": "tcp,udp", "outboundTag": "th1-xhttp"}]}}
json.dump(cfg, open(sys.argv[1], "w"), ensure_ascii=False, indent=1)
' "$OUT"
unset LINK
chmod 600 "$OUT"
printf 'тестовый профиль собран: XHTTP в запасной вход th1 (45.91.134.19), без балансировщика\n' >&2
printf '%s\n' "$OUT"
