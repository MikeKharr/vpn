#!/usr/bin/env bash
# Проверки bin/make-happ-json.sh. Исполняется САМ скрипт — тот же файл,
# который запускает владелец, а не его копия.
#
# Что здесь держится и почему именно так:
#
#   1. ЗНАЧЕНИЕ НЕ УХОДИТ В АРГУМЕНТЫ внешнего процесса. Прогон идёт с PATH,
#      в котором лежат ТОЛЬКО обёртки над mkdir, chmod, python3 и xray, и
#      каждая записывает свои аргументы в журнал. Отсюда две проверки сразу:
#      появись в скрипте `sed`, `cat`, `jq` или `grep` — внешней команды не
#      окажется в PATH и прогон покраснеет; подставь кто-нибудь значение
#      аргументом — его найдёт сверка журнала. Проверять по `ps` нельзя:
#      процесс живёт микросекунды, и выборка `ps` была бы зелёной при любой
#      гипотезе.
#   2. ПРАВА. Каталог 700, файлы 600 — при рождении (umask) И при уже
#      существующих чужих правах (chmod). Второй случай отдельным прогоном:
#      без него строки chmod можно удалить, оставив прогон зелёным.
#   3. КЛЮЧ th2 НЕ ПЕРЕЗАПИСЫВАЕТСЯ. Это главное требование скрипта: ключ —
#      личность сервера th2, и новая пара означает, что к th2 не подключается
#      ни один клиент. Проверяется сверкой содержимого ДО и ПОСЛЕ и тем, что
#      `xray` не позван вовсе (журнал аргументов).
#   4. КЛЮЧ СОЗДАЁТСЯ, когда его нет: отдельный прогон с обёрткой над `xray`.
#   5. STDOUT — РОВНО ПУТЬ, одна строка. Приглашения и сообщения в stderr.
#   6. ФОРМА. Негодное значение не даёт собрать файл.
#   7. ПОЛЯ JSON — сверка ПОЛНЫМ РАВЕНСТВОМ разобранного конфига ожидаемому.
#      Не выборка полей: конфиг уже импортирован в Happ на Mac, переимпорт в
#      поездке рвёт туннель (ADR 2026-10-05-2223, «Последствия»), поэтому
#      проверке подлежит вся структура, а не те поля, про которые вспомнили.
#   8. ЯДРО ПРИНИМАЕТ КОНФИГ: `xray run -test`. Берётся `xray` из PATH, иначе
#      закреплённый digest'ом образ из deploy/compose.yml, иначе шаг
#      пропускается С НАЗВАННОЙ ПРИЧИНОЙ и прогон остаётся зелёным — молчащий
#      пропуск не отличался бы от пройденной проверки.
#
# Фиктивные значения собираются из кусков в момент прогона: записанные
# литералом, UUID и 43-знаковый ключ сделали бы находкой сам этот файл, и
# сторож секретов краснел бы всегда — то есть не отличал бы чистое дерево от
# грязного (та же причина, что в test/secrets-guard.test.sh).
#
# Ни одно фиктивное значение не печатается: прогон идёт в публичном журнале
# Actions, и привычка печатать «всего лишь фиктивное» значение — та самая, из
# которой однажды печатается настоящее.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
script="$root/bin/make-happ-json.sh"
[ -r "$script" ] || { echo "нет $script"; exit 2; }

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'ПРОВАЛ %s\n' "$1"; }

# Фиктивные, но формой годные значения — по кускам.
uuid="$(printf '%s-%s-%s-%s-%s' 7f3a9c1e 4b2d 41e8 9a7c 0d5e6f8a1b23)"
sid="$(printf '%s%s' 3f9c 1e4b)"
# 47 знаков алфавита base64url, обрезанные до 43: литерал из 47 не подходит
# под образец сторожа (окно из 43 знаков внутри него окружено знаками того же
# алфавита), а в проверках участвуют ровно 43.
pbk="$(printf '%s' 'Qm9ndXNLZXlOb3RSZWFsbHlBS2V5QnV0NDNDaGFyc0xvbmc')"; pbk="${pbk:0:43}"
pub2="$(printf '%s' 'U2Vjb25kQm9ndXNLZXlOb3RSZWFsNDNDaGFyc0xvbmdYWVo')"; pub2="${pub2:0:43}"
priv2="$(printf '%s' 'UHJpdmF0ZUJvZ3VzS2V5Tm90UmVhbDQzQ2hhcnNMb25nQUJD')"; priv2="${priv2:0:43}"
# Пара, которую печатает обёртка над xray в прогоне «ключа нет».
genpriv="$(printf '%s' 'R2VuZXJhdGVkQm9ndXNQcml2NDNDaGFyc0xvbmdBQkNERUZH')"; genpriv="${genpriv:0:43}"
genpub="$(printf '%s' 'R2VuZXJhdGVkQm9ndXNQdWI0M0NoYXJzTG9uZ0FCQ0RFRkdI')"; genpub="${genpub:0:43}"

mklink() {
  # $1 — UUID, $2 — pbk, $3 — sid, $4 — схема (vless или мусор)
  printf '%s://%s@%s:443?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=cdn.zpq.ai&fp=chrome&pbk=%s&sid=%s#mac' \
    "$4" "$1" cdn.zpq.ai "$2" "$3"
}
link="$(mklink "$uuid" "$pbk" "$sid" vless)"

bash_abs=$(command -v bash)
python_abs=$(command -v python3) || { echo "нет python3"; exit 2; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Обёртки над внешними командами. Реальный путь берётся здесь и вшивается в
# обёртку: внутри прогона PATH содержит только каталог обёрток.
shim="$work/shim"
mkdir -p "$shim"
stat_abs=$(command -v stat) || { echo "нет stat"; exit 2; }
for cmd in mkdir chmod python3; do
  real=$(command -v "$cmd") || { echo "нет $cmd"; exit 2; }
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "%s $*" >> "%s"\n' "$cmd" "$work/argv.log"
    if [ "$cmd" = chmod ]; then
      # Права ДО применения chmod — то есть те, с которыми каталог и файл
      # родились. Это единственный способ увидеть действие umask: после
      # chmod его следа не остаётся, и строку `umask 077` можно было бы
      # удалить при зелёном прогоне.
      printf 'for a; do :; done\n'
      # shellcheck disable=SC2016
      printf 'm=$(%s -c "%%a" "$a" 2>/dev/null || %s -f "%%Lp" "$a")\n' "$stat_abs" "$stat_abs"
      # shellcheck disable=SC2016
      printf 'printf "%%s %%s\\n" "$m" "$a" >> "%s"\n' "$work/birth.log"
    fi
    printf 'exec %s "$@"\n' "$real"
  } > "$shim/$cmd"
  chmod 755 "$shim/$cmd"
done
# Обёртка над xray: настоящий xray звать нельзя — он создал бы НАСТОЯЩУЮ пару
# ключей, и прогон в CI писал бы на диск раннера живой приватный ключ.
# `$XRAY_FAKE_OUT` задаёт, что она печатает: пустой — молчит, и скрипт обязан
# отказаться.
{
  printf '#!/bin/sh\n'
  printf 'printf "%%s\\n" "xray $*" >> "%s"\n' "$work/argv.log"
  # shellcheck disable=SC2016
  printf 'printf "%%s" "${XRAY_FAKE_OUT-}"\n'
} > "$shim/xray"
chmod 755 "$shim/xray"

# $1 — каталог HOME, $2 — вывод обёртки xray, далее — строки ввода.
# Возвращает код скрипта; stdout и stderr складывает в файлы прогона.
run() {
  local home="$1" fake="$2"; shift 2
  local rc=0
  : > "$work/argv.log"
  : > "$work/birth.log"
  printf '%s\n' "$@" > "$work/stdin"
  env -i HOME="$home" PATH="$shim" XRAY_FAKE_OUT="$fake" "$bash_abs" "$script" \
    < "$work/stdin" > "$work/out" 2> "$work/err" || rc=$?
  return "$rc"
}

# Ни одно значение не имеет права оказаться в выводе или в аргументах внешних
# команд. Проверка зовётся после КАЖДОГО прогона, включая отказы.
assert_no_leak() {
  local title="$1" file secret
  for file in "$work/out" "$work/err" "$work/argv.log"; do
    for secret in "$uuid" "$pbk" "$pub2" "$priv2" "$sid" "$genpriv" "$genpub"; do
      if grep -qF -- "$secret" "$file" 2>/dev/null; then
        bad "$title: значение утекло в $(basename "$file")"
        return
      fi
    done
  done
  ok "$title: значений нет ни в stdout, ни в stderr, ни в аргументах внешних команд"
}

# stderr прогона печатается ТОЛЬКО если в нём нет ни одного значения: иначе
# мутация «значение в stderr плюс ненулевой код» уводила бы значение в
# публичный журнал Actions. На законном отказе значений в stderr нет, и
# диагностика не теряется.
safe_err() {
  local secret
  for secret in "$uuid" "$pbk" "$pub2" "$priv2" "$sid" "$genpriv" "$genpub"; do
    if grep -qF -- "$secret" "$work/err" 2>/dev/null; then
      printf 'stderr не печатается — в нём значение (строк: %s)' \
        "$(wc -l < "$work/err" | tr -d ' ')"
      return
    fi
  done
  cat "$work/err"
}

mode_of() {
  # Порядок попыток несущий: у GNU stat `-f` ЕСТЬ и означает
  # `--file-system`, то есть BSD-форма на Linux не падает, а печатает текст
  # про файловую систему. Поэтому сначала GNU `-c`, которого у BSD нет вовсе.
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

seed_keys() {
  local home="$1"
  mkdir -p "$home/.config/vpn"
  printf '%s\n' "$priv2" > "$home/.config/vpn/th2-reality.key"
  printf '%s\n' "$pub2"  > "$home/.config/vpn/th2-reality.pub"
}

# --- 1. Обычный прогон: ключ th2 уже есть -----------------------------------
home="$work/home-clean"
seed_keys "$home"
want="$home/.config/vpn/happ-failover.json"
rc=0
run "$home" '' "$link" || rc=$?

if [ "$rc" = 0 ]; then ok 'прогон завершился кодом 0'; else bad "прогон вернул код $rc: $(safe_err)"; fi

if [ "$(cat "$work/out")" = "$want" ]; then
  ok 'stdout — ровно путь к файлу'
else
  bad "stdout не равен пути к файлу (строк: $(wc -l < "$work/out"))"
fi

if [ -f "$want" ]; then ok 'файл конфига на месте'; else bad 'файла конфига нет'; fi
if [ "$(mode_of "$want")" = 600 ]; then ok 'файл 0600'; else bad "файл $(mode_of "$want"), а не 0600"; fi
if [ "$(mode_of "$home/.config/vpn")" = 700 ]; then
  ok 'каталог 0700'
else
  bad "каталог $(mode_of "$home/.config/vpn"), а не 0700"
fi

# Держатель строки umask 077: права, с которыми файл РОДИЛСЯ, до chmod. При
# umask 022 здесь было бы 644 — то есть конфиг со значениями на диске,
# читаемый всем, пока не дойдёт очередь до chmod.
#
# Каталог в этом прогоне уже существовал (его создала seed_keys под umask
# прогона), поэтому в birth.log от него — только права после mkdir -p, то
# есть 700 от chmod этого же скрипта в прошлой строке он получить не мог.
# Проверяется строка ФАЙЛА: ищем запись про happ-failover.json.
#
# `|| true` здесь несущий, а не украшение: без него пустой birth.log даёт
# grep код 1, `pipefail` роняет присваивание, и `set -e` обрывает ВЕСЬ файл
# проверок без единой строки вывода. Проверено мутацией «снят chmod 600 на
# конфиг»: в первой редакции она не краснела, а молча обрывала прогон, то
# есть этот файл не отличал бы провал от аварии.
birth_cfg=$(grep -F 'happ-failover.json' "$work/birth.log" | head -n 1 | cut -d' ' -f1 || true)
if [ "$birth_cfg" = 600 ]; then
  ok 'конфиг родился 0600 (umask), а не был закрыт потом'
else
  bad "права конфига при рождении: [$birth_cfg], ждали 600"
fi

# Ключ не тронут: ни по содержимому, ни по тому, что xray вообще не позван.
if [ "$(cat "$home/.config/vpn/th2-reality.key")" = "$priv2" ] \
   && [ "$(cat "$home/.config/vpn/th2-reality.pub")" = "$pub2" ]; then
  ok 'ключ th2 не перезаписан: содержимое пары то же'
else
  bad 'ключ th2 изменился — это отрезало бы все клиенты от th2'
fi
if grep -q '^xray ' "$work/argv.log"; then
  bad 'xray позван при уже существующем ключе — пара могла быть пересоздана'
else
  ok 'xray не позван при существующем ключе'
fi

# Под HOME ровно три файла: пара ключей и конфиг. Ни временного, ни резервной
# копии.
#
# ЧЕСТНАЯ ГРАНИЦА: считаются файлы ПОД HOME. Файл, записанный скриптом куда-то
# ещё (`/tmp`, каталог запуска), эта сверка не увидит. Общего держателя у «ни
# одного файла нигде» нет: его дало бы только наблюдение всех записей
# процесса, и держит это ревью исходника — внешних команд четыре,
# перенаправлений три.
#
# Из счёта вычтен кеш байт-кода Apple'овского /usr/bin/python3: он кладёт
# ~/Library/Caches/com.apple.python/... при каждом запуске, и это пишет
# ИНТЕРПРЕТАТОР, а не проверяемый скрипт. Наблюдено: та же проверка с
# `PATH=/usr/bin:/bin` на macOS даёт 39 файлов при нетронутом скрипте, то
# есть без вычета она краснела бы от выбора python3, а не от поведения
# скрипта. На Homebrew'ском python3 и на python3 раннера кеша нет.
files=$(find "$home" -type f -not -path '*/Library/Caches/com.apple.python/*' | wc -l | tr -d ' ')
if [ "$files" = 3 ]; then ok 'под HOME ровно три файла — пара ключей и конфиг'; else bad "под HOME файлов: $files, ждали 3"; fi

assert_no_leak 'обычный прогон'

# Дальше проверяется САМ конфиг, и без него остаток файла не проверка, а
# авария: `json.load` на отсутствующем файле падает, `set -e` обрывает прогон,
# и вывод кончается трассировкой python без строки «итог» — провал в такой
# форме не отличить от сломанного файла проверок. Поэтому отказ называется, и
# прогон кончается итогом. Проверено мутацией «ключ пересоздаётся всегда»: в
# первой редакции она давала ровно такой обрыв.
if [ ! -f "$want" ]; then
  bad 'конфига нет — сверка структуры, xray run -test и прогоны формы не выполнены'
  printf '\nитог: пройдено %s, провалено %s\n' "$pass" "$fail"
  exit 1
fi

# --- 2. Структура конфига: полное равенство ожидаемому ----------------------
# Значения уходят в python по stdin, не аргументом: те же правила, что у
# самого скрипта.
#
# Программа проверки кладётся в файл, а не подаётся по stdin: stdin занят
# значениями. Сама программа не секрет, значения — секрет.
cat > "$work/check.py" <<'PY'
import sys, json
uuid, pbk, pub2, sid = [l.strip() for l in sys.stdin.read().splitlines()[:4]]

def ob(tag, ip, sni, key):
    return {"tag": tag, "protocol": "vless",
      "settings": {"vnext": [{"address": ip, "port": 443, "users": [{"id": uuid, "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"serverName": sni, "fingerprint": "chrome", "publicKey": key, "shortId": sid, "spiderX": "/"}}}

want = {
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

got = json.load(open(sys.argv[1]))
if got == want:
    raise SystemExit(0)
# Расхождение называется ПУТЁМ, а не печатью конфигов: в них значения.
def paths(a, b, p=""):
    if type(a) is not type(b):
        yield p or "."
        return
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                yield p + "/" + k
            else:
                yield from paths(a[k], b[k], p + "/" + k)
    elif isinstance(a, list):
        if len(a) != len(b):
            yield (p or ".") + "[длина]"
        for i, (x, y) in enumerate(zip(a, b)):
            yield from paths(x, y, p + "[%d]" % i)
    elif a != b:
        yield p or "."
sys.stderr.write("расхождения: " + " ".join(sorted(set(paths(got, want)))) + "\n")
raise SystemExit(1)
PY
cfg_rc=0
printf '%s\n%s\n%s\n%s\n' "$uuid" "$pbk" "$pub2" "$sid" \
  | "$python_abs" "$work/check.py" "$want" > "$work/cfg.out" 2>&1 || cfg_rc=$?
if [ "$cfg_rc" = 0 ]; then
  ok 'конфиг совпадает с ожидаемым ПОЛНОСТЬЮ: теги th2/th1/direct/block, балансер main с fallbackTag th1, observatory, dns, inbounds 10808/10809, remarks'
else
  bad "конфиг разошёлся с ожидаемым: $(cat "$work/cfg.out")"
fi

# Положительный контроль сверки: на фикстуре с одним изменённым полем она
# обязана сказать «разошлось». Без него зелёная сверка не отличалась бы от
# сверки, которая сравнивает что-нибудь само с собой.
"$python_abs" -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["routing"]["balancers"][0]["fallbackTag"] = "direct"
json.dump(cfg, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
' "$want" "$work/mutated.json"
mut_rc=0
printf '%s\n%s\n%s\n%s\n' "$uuid" "$pbk" "$pub2" "$sid" \
  | "$python_abs" "$work/check.py" "$work/mutated.json" > "$work/mut.out" 2>&1 || mut_rc=$?
if [ "$mut_rc" != 0 ] && grep -q 'fallbackTag' "$work/mut.out"; then
  ok 'сверка умеет краснеть: на фикстуре с fallbackTag=direct она называет этот путь'
else
  bad "сверка не покраснела на подменённом fallbackTag: код $mut_rc, вывод $(cat "$work/mut.out")"
fi

# --- 3. Ядро принимает конфиг ----------------------------------------------
# Копия с правами 0644 в отдельном каталоге: образ Xray работает под uid
# 65532 и файл 0600 владельца прогона ему не прочитать — отказ выглядел бы
# отказом конфига.
core="$work/core"
mkdir -p "$core"
cp "$want" "$core/config.json"
chmod 644 "$core/config.json"
core_rc=0
if command -v xray >/dev/null 2>&1; then
  out=$(xray run -test -c "$core/config.json" 2>&1) || core_rc=$?
  if [ "$core_rc" = 0 ]; then
    ok "ядро приняло конфиг: xray run -test из PATH ($(xray version 2>/dev/null | head -n 1))"
  else
    bad "xray run -test вернул код $core_rc: $out"
  fi
elif command -v docker >/dev/null 2>&1; then
  # Образ берётся ИЗ compose, а не записан здесь второй раз: иначе проверялась
  # бы одна версия ядра, а на сервере стояла другая. `grep`, а не
  # `docker compose config`: у службы render файл secrets.env помечен
  # required, и без него разбор compose падает.
  image=$(grep -oE 'ghcr\.io/xtls/xray-core:[^ ]+' "$root/deploy/compose.yml" | head -n 1 || true)
  case "$image" in
    *@sha256:*) ;;
    *) bad "образ Xray в compose не закреплён digest'ом — проверять этим нельзя"; image='' ;;
  esac
  if [ -n "$image" ]; then
    out=$(docker run --rm -v "$core:/conf:ro" "$image" run -c /conf/config.json -test 2>&1) || core_rc=$?
    if [ "$core_rc" = 0 ]; then
      ok "ядро приняло конфиг: xray run -test в образе $image"
    else
      bad "xray run -test в образе вернул код $core_rc: $out"
    fi
  fi
else
  printf 'ПРОПУСК ядро не проверено: ни xray в PATH, ни docker — поставить xray (brew install xray) или запустить там, где есть docker\n'
fi

# --- 4. Ключа нет: создаётся, права 0600, публичный уходит в конфиг ---------
home="$work/home-nokey"
mkdir -p "$home"
rc=0
run "$home" "$(printf 'PrivateKey: %s\nPassword: %s\nHash32: deadbeef\n' "$genpriv" "$genpub")" "$link" || rc=$?
kp="$home/.config/vpn/th2-reality.key"
pp="$home/.config/vpn/th2-reality.pub"
if [ "$rc" = 0 ] && [ -s "$kp" ] && [ -s "$pp" ]; then
  ok 'ключа не было — пара создана'
else
  bad "пара не создана: код $rc: $(safe_err)"
fi
if [ "$(cat "$kp" 2>/dev/null)" = "$genpriv" ] && [ "$(cat "$pp" 2>/dev/null)" = "$genpub" ]; then
  ok 'в файлы попали ровно PrivateKey и Password из вывода xray'
else
  bad 'содержимое пары не то, что напечатал xray'
fi
if [ "$(mode_of "$kp")" = 600 ] && [ "$(mode_of "$pp")" = 600 ]; then
  ok 'пара ключей 0600'
else
  bad "права пары: $(mode_of "$kp") / $(mode_of "$pp")"
fi
# Публичный ключ th2 в конфиге — тот, что создан, а не оставшийся от прошлого
# прогона: иначе клиент шёл бы к th2 с чужим ключом.
if printf '%s\n' "$genpub" | "$python_abs" -c 'import json,sys; cfg=json.load(open(sys.argv[1])); sys.exit(0 if cfg["outbounds"][0]["streamSettings"]["realitySettings"]["publicKey"]==sys.stdin.read().strip() else 1)' \
     "$home/.config/vpn/happ-failover.json"; then
  ok 'в outbound th2 стоит только что созданный публичный ключ'
else
  bad 'в outbound th2 стоит не созданный публичный ключ'
fi
assert_no_leak 'прогон с созданием ключа'

# --- 5. xray молчит: ключ НЕ создан, отказ громкий --------------------------
home="$work/home-badxray"
mkdir -p "$home"
rc=0
run "$home" '' "$link" || rc=$?
if [ "$rc" != 0 ] && [ ! -e "$home/.config/vpn/th2-reality.key" ] \
   && [ ! -e "$home/.config/vpn/happ-failover.json" ]; then
  ok "вывод xray не разобрался: отказ кодом $rc, ни ключа, ни конфига"
else
  bad "вывод xray не разобрался, а прогон вернул $rc и что-то записал"
fi
assert_no_leak 'прогон с неразбираемым выводом xray'

# --- 6. Повторный прогон поверх чужих прав ---------------------------------
# Держатель строк chmod: umask на существующий каталог и существующий файл не
# действует, и без chmod конфиг остался бы читаемым всем.
home="$work/home-loose"
seed_keys "$home"
chmod 755 "$home/.config/vpn"
: > "$home/.config/vpn/happ-failover.json"
chmod 644 "$home/.config/vpn/happ-failover.json"
rc=0
run "$home" '' "$link" || rc=$?
loose="$home/.config/vpn"
if [ "$rc" = 0 ] && [ "$(mode_of "$loose")" = 700 ] && [ "$(mode_of "$loose/happ-failover.json")" = 600 ]; then
  ok 'уже существующие 0755/0644 приведены к 0700/0600'
else
  bad "существующие права не исправлены: код $rc, каталог $(mode_of "$loose"), файл $(mode_of "$loose/happ-failover.json")"
fi
assert_no_leak 'прогон поверх существующего файла'

# --- 7. Проверки формы ------------------------------------------------------
# Негодная ссылка => конфига нет. Ключ в HOME есть: иначе прогон краснел бы и
# от отсутствия ключа, то есть ослабление образца формы осталось бы зелёным.
form_case() {
  local title="$1" value="$2"
  local h; h="$work/home-form-$pass-$fail"
  rm -rf "$h"
  seed_keys "$h"
  local rc=0
  run "$h" '' "$value" || rc=$?
  local produced=no
  [ -f "$h/.config/vpn/happ-failover.json" ] && produced=yes
  if [ "$rc" != 0 ] && [ "$produced" = no ]; then
    ok "$title: отказ кодом $rc, конфига нет"
  else
    bad "$title: код $rc, конфиг собран: $produced"
  fi
  assert_no_leak "$title"
}

form_case 'пустой ввод' ''
form_case 'схема не vless' "$(mklink "$uuid" "$pbk" "$sid" https)"
form_case 'ссылка без pbk' \
  "$(printf 'vless://%s@%s:443?security=reality&sni=cdn.zpq.ai&fp=chrome&sid=%s#mac' "$uuid" cdn.zpq.ai "$sid")"
form_case 'UUID версии 7' \
  "$(mklink "$(printf '%s-%s-%s-%s-%s' 7f3a9c1e 4b2d 71e8 9a7c 0d5e6f8a1b23)" "$pbk" "$sid" vless)"
form_case 'UUID короче формы' "$(mklink "${uuid%??}" "$pbk" "$sid" vless)"
form_case 'pbk длиной 42' "$(mklink "$uuid" "${pbk:0:42}" "$sid" vless)"
form_case 'sid в верхнем регистре' "$(mklink "$uuid" "$pbk" 'ABCDEF12' vless)"

# Негодный публичный ключ th2 (не 43 знака base64url) — тоже отказ: он
# приходит не из ссылки, а из файла, и подменить его может чужая правка.
home="$work/home-badpub"
mkdir -p "$home/.config/vpn"
printf '%s\n' "$priv2" > "$home/.config/vpn/th2-reality.key"
printf '%s\n' "${pub2:0:40}" > "$home/.config/vpn/th2-reality.pub"
rc=0
run "$home" '' "$link" || rc=$?
if [ "$rc" != 0 ] && [ ! -f "$home/.config/vpn/happ-failover.json" ]; then
  ok "публичный ключ th2 не той формы: отказ кодом $rc, конфига нет"
else
  bad "публичный ключ th2 не той формы, а код $rc и конфиг собран"
fi
assert_no_leak 'негодный публичный ключ th2'

printf '\nитог: пройдено %s, провалено %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
