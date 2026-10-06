#!/usr/bin/env bash
# Собирает полный конфиг Xray для Happ: основной сервер — th2 (Triplify,
# 160.236.128.28), резервный — th1 (45.91.134.23). Переключение делает сам
# клиент: балансер с `fallbackTag` и `observatory` (ADR 2026-10-05-2223, п. 4;
# основным th2 выбран владельцем — «Статус» того же ADR).
#
# Запускает ВЛАДЕЛЕЦ на своей машине. Файл кладётся в ~/.config/vpn и
# импортируется в Happ через буфер обмена (README, «Клиент с автопереключением»).
#
# Что этот скрипт НЕ делает, намеренно:
#   - не печатает ни одного значения: в stdout уходит РОВНО путь к файлу,
#     приглашения и сообщения — в stderr;
#   - не кладёт значения в аргументы ни одного процесса: ссылка и публичный
#     ключ уходят в python по stdin, иначе их было бы видно в `ps`
#     (то же соображение, что в bin/make-link.sh и deploy/render/render.sh);
#   - НИКОГДА не перезаписывает ~/.config/vpn/th2-reality.key. Этот ключ —
#     личность сервера th2: он уже на сервере (или поедет туда), и новая пара
#     означала бы, что ни один клиент к th2 не подключается;
#   - не ходит на сервер и ничего оттуда не читает.
#
# ПОЧЕМУ ФОРМУ ЭТОГО ФАЙЛА МЕНЯТЬ НЕЛЬЗЯ БЕЗ РЕШЕНИЯ ВЛАДЕЛЬЦА: конфиг уже
# импортирован в Happ на Mac профилем «TH failover», и переимпорт в поездке
# рвёт туннель — то есть требует рабочего VPN, чтобы восстановить VPN. Любая
# правка выхода — это переимпорт на двух устройствах (ADR 2026-10-05-2223,
# «Последствия», «Режим JSON отключает интерфейс Happ»).
#
# Запуск:  bash bin/make-happ-json.sh
set -euo pipefail
umask 077

D="$HOME/.config/vpn"
mkdir -p "$D"
# chmod на СУЩЕСТВУЮЩИЙ каталог: umask на него не действует, а каталог мог
# родиться 0755 раньше и не этим скриптом.
chmod 700 "$D"
OUT="$D/happ-failover.json"
KEY="$D/th2-reality.key"
PUB="$D/th2-reality.pub"

# 1. Ключ REALITY для th2: создаётся ОДИН РАЗ и потом уходит на сервер
#    (`deploy/put-secrets.sh` с `SERVER=` на th2). Повторный запуск скрипта
#    его не трогает — см. шапку.
if [ ! -s "$KEY" ]; then
  command -v xray >/dev/null 2>&1 || {
    printf 'ОШИБКА: ключа th2 нет, а xray не найден — поставить (brew install xray) или скопировать ~/.config/vpn/th2-reality.key с машины, где он создан\n' >&2
    exit 1
  }
  priv=''
  pub=''
  # Процессная подстановка, а не `<<<`: here-string в bash идёт через
  # временный файл, то есть приватный ключ лёг бы в /tmp.
  while IFS= read -r line; do
    case "$line" in
      'PrivateKey: '*) priv=${line#*': '} ;;
      # `Password:` — так печатает xray 26.x; `PublicKey:` — прежние сборки.
      'Password: '*|'PublicKey: '*) [ -n "$pub" ] || pub=${line#*': '} ;;
    esac
  done < <(xray x25519)
  if [ -z "$priv" ] || [ -z "$pub" ]; then
    printf 'ОШИБКА: вывод xray x25519 разобрать не удалось — ключ НЕ создан\n' >&2
    exit 1
  fi
  printf '%s\n' "$priv" > "$KEY"
  printf '%s\n' "$pub" > "$PUB"
  unset priv pub
  chmod 600 "$KEY" "$PUB"
  printf 'ключ th2 создан: %s — его же положить на сервер th2 через deploy/put-secrets.sh\n' "$KEY" >&2
else
  printf 'ключ th2 уже есть: %s — не перезаписан\n' "$KEY" >&2
fi
if [ ! -s "$KEY" ] || [ ! -s "$PUB" ]; then
  printf 'ОШИБКА: пары ключей th2 нет на месте — конфиг не собран\n' >&2
  exit 1
fi

# 2. Ссылка рабочего сервера th1 из Happ (`bin/make-link.sh iphone`/`mac`):
#    из неё берутся UUID, shortId, отпечаток и публичный ключ th1. Ввод скрыт.
printf 'Ссылка vless:// рабочего сервера th1 (ввод не отображается): ' >&2
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

# 3. Сборка JSON. Значения идут в python по stdin, путь — аргументом: путь
#    не секрет, значения — секрет.
{
  printf '%s\n' "$LINK"
  # Публичный ключ читается встроенным `$(<файл)`: без `cat` значение не
  # проходит через чужой процесс вовсе.
  printf '%s\n' "$(<"$PUB")"
} | python3 -c '
import sys, json, re, urllib.parse as u

def die(msg):
    sys.stderr.write("ОШИБКА: " + msg + "\n")
    raise SystemExit(1)

lines = sys.stdin.read().splitlines()
if len(lines) < 2:
    die("на вход пришло меньше двух строк — ждались ссылка th1 и публичный ключ th2")
link, pub2 = [l.strip() for l in lines[:2]]
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
if not re.fullmatch(B64, pub2):
    die("публичный ключ th2 — не 43 знака base64url")
if sid and not re.fullmatch(r"[0-9a-f]{8}", sid):
    die("sid в ссылке — не 8 знаков hex")
pbk = q["pbk"]

def ob(tag, ip, sni, key):
    return {"tag": tag, "protocol": "vless",
      "settings": {"vnext": [{"address": ip, "port": 443, "users": [{"id": uuid, "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"serverName": sni, "fingerprint": fp, "publicKey": key, "shortId": sid, "spiderX": "/"}}}

cfg = {
 "remarks": "TH failover",
 "log": {"loglevel": "warning"},
 "dns": {"servers": ["https://1.1.1.1/dns-query"], "queryStrategy": "UseIPv4", "tag": "dns-in"},
 "inbounds": [
  {"tag": "socks", "listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": {"udp": True}, "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}},
  {"tag": "http", "listen": "127.0.0.1", "port": 10809, "protocol": "http", "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}}],
 "outbounds": [
  ob("th2", "160.236.128.28", "cdn2.zpq.ai", pub2),
  ob("th1", "45.91.134.23", "cdn.zpq.ai", pbk),
  {"tag": "direct", "protocol": "freedom"},
  {"tag": "block", "protocol": "blackhole"}],
 "observatory": {"subjectSelector": ["th"], "probeUrl": "https://www.gstatic.com/generate_204", "probeInterval": "30s"},
 "routing": {"domainStrategy": "AsIs",
  "balancers": [{"tag": "main", "selector": ["th2"], "fallbackTag": "th1", "strategy": {"type": "leastPing"}}],
  "rules": [
   {"inboundTag": ["dns-in"], "balancerTag": "main"},
   {"ip": ["geoip:private"], "outboundTag": "direct"},
   {"network": "udp", "port": "443", "outboundTag": "block"},
   {"network": "tcp,udp", "balancerTag": "main"}]}}
json.dump(cfg, open(sys.argv[1], "w"), ensure_ascii=False, indent=1)
' "$OUT"
unset LINK
chmod 600 "$OUT"
printf 'конфиг собран: основной th2 (160.236.128.28), резерв th1 (45.91.134.23)\n' >&2
printf '%s\n' "$OUT"
