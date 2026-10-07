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
#   5. STDOUT — РОВНО ДВА ПУТИ, по строке на файл, в порядке
#      «TH failover», «TH mobile». Приглашения и сообщения в stderr.
#   6. ФОРМА. Негодное значение не даёт собрать НИ ОДНОГО файла.
#   7. ПОЛЯ JSON — сверка ПОЛНЫМ РАВЕНСТВОМ разобранного конфига ожидаемому, у
#      КАЖДОГО из двух профилей. Не выборка полей: «TH failover» уже
#      импортирован в Happ на двух устройствах, переимпорт в поездке рвёт
#      туннель (ADR 2026-10-05-2223, «Последствия»), поэтому проверке подлежит
#      вся структура, а не те поля, про которые вспомнили. Для «TH failover»
#      эта сверка — ЕДИНСТВЕННЫЙ держатель того, что добавление второго
#      профиля (ADR 2026-10-07-1123) не изменило его выход ни на байт.
#   8. ТРАНСПОРТ «TH mobile» СОВПАДАЕТ С СЕРВЕРОМ. `path` и `xPaddingBytes`
#      сверяются не с литералом в этом файле, а с inbound `vless-xhttp` в
#      deploy/config.template.json: сервер сверяет путь префиксом
#      (splithttp/hub.go:103) и ПРОВЕРЯЕТ длину набивки клиента на попадание в
#      свой отрезок (hub.go:142-148), поэтому расхождение двух литералов — это
#      профиль, который ядро примет, а сервер отдаст 400 или 404. Два литерала
#      в двух файлах без держателя разошлись бы первой же правкой.
#   9. ЯДРО ПРИНИМАЕТ ОБА КОНФИГА: `xray run -test`. Берётся `xray` из PATH,
#      иначе закреплённый digest'ом образ из deploy/compose.yml, иначе шаг
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
template="$root/deploy/config.template.json"
[ -r "$script" ] || { echo "нет $script"; exit 2; }
[ -r "$template" ] || { echo "нет $template"; exit 2; }

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
      # Журналится КАЖДЫЙ аргумент, а не последний: `chmod 600 a b` — одна
      # команда на два файла, и запись только о последнем оставила бы права
      # первого при рождении без держателя вовсе.
      # shellcheck disable=SC2016
      printf 'for a; do\n'
      # shellcheck disable=SC2016
      printf '  case "$a" in -*) continue ;; esac\n'
      # Режим («600», «700») — такой же аргумент, и файлом он не является:
      # без этой строки в журнал ложилась бы строка без прав вовсе.
      # shellcheck disable=SC2016
      printf '  [ -e "$a" ] || continue\n'
      # shellcheck disable=SC2016
      printf '  m=$(%s -c "%%a" "$a" 2>/dev/null || %s -f "%%Lp" "$a")\n' "$stat_abs" "$stat_abs"
      # shellcheck disable=SC2016
      printf '  printf "%%s %%s\\n" "$m" "$a" >> "%s"\n' "$work/birth.log"
      printf 'done\n' 
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
want_mobile="$home/.config/vpn/happ-mobile.json"
rc=0
run "$home" '' "$link" || rc=$?

if [ "$rc" = 0 ]; then ok 'прогон завершился кодом 0'; else bad "прогон вернул код $rc: $(safe_err)"; fi

# Контракт stdout — ДВЕ строки в заданном порядке: README велит владельцу
# положить в буфер второй файл по его пути, и перепутанный порядок увёл бы в
# Happ не тот профиль под тем же именем «Импорт из буфера».
if [ "$(cat "$work/out")" = "$(printf '%s\n%s' "$want" "$want_mobile")" ]; then
  ok 'stdout — ровно два пути: сначала happ-failover.json, потом happ-mobile.json'
else
  bad "stdout не равен двум путям в нужном порядке (строк: $(wc -l < "$work/out"))"
fi

if [ -f "$want" ]; then ok 'файл «TH failover» на месте'; else bad 'файла happ-failover.json нет'; fi
if [ -f "$want_mobile" ]; then ok 'файл «TH mobile» на месте'; else bad 'файла happ-mobile.json нет'; fi
if [ "$(mode_of "$want")" = 600 ]; then ok 'файл «TH failover» 0600'; else bad "файл $(mode_of "$want"), а не 0600"; fi
if [ -f "$want_mobile" ] && [ "$(mode_of "$want_mobile")" = 600 ]; then
  ok 'файл «TH mobile» 0600'
else
  bad "happ-mobile.json $(mode_of "$want_mobile" 2>/dev/null), а не 0600"
fi
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
for base in happ-failover.json happ-mobile.json; do
  birth_cfg=$(grep -F "$base" "$work/birth.log" | head -n 1 | cut -d' ' -f1 || true)
  if [ "$birth_cfg" = 600 ]; then
    ok "$base родился 0600 (umask), а не был закрыт потом"
  else
    bad "права $base при рождении: [$birth_cfg], ждали 600"
  fi
done

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

# Под HOME ровно четыре файла: пара ключей и два профиля. Ни временного, ни
# резервной копии.
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
if [ "$files" = 4 ]; then ok 'под HOME ровно четыре файла — пара ключей и два профиля'; else bad "под HOME файлов: $files, ждали 4"; fi

assert_no_leak 'обычный прогон'

# Дальше проверяется САМ конфиг, и без него остаток файла не проверка, а
# авария: `json.load` на отсутствующем файле падает, `set -e` обрывает прогон,
# и вывод кончается трассировкой python без строки «итог» — провал в такой
# форме не отличить от сломанного файла проверок. Поэтому отказ называется, и
# прогон кончается итогом. Проверено мутацией «ключ пересоздаётся всегда»: в
# первой редакции она давала ровно такой обрыв.
if [ ! -f "$want" ] || [ ! -f "$want_mobile" ]; then
  bad 'одного из профилей нет — сверка структуры, xray run -test и прогоны формы не выполнены'
  printf '\nитог: пройдено %s, провалено %s\n' "$pass" "$fail"
  exit 1
fi

# --- 2. Структура обоих конфигов: полное равенство ожидаемому ---------------
# Значения уходят в python по stdin, не аргументом: те же правила, что у
# самого скрипта.
#
# Программа проверки кладётся в файл, а не подаётся по stdin: stdin занят
# значениями. Сама программа не секрет, значения — секрет.
cat > "$work/check.py" <<'CHECKPY'
import sys, json, re
uuid, pbk, pub2, sid = [l.strip() for l in sys.stdin.read().splitlines()[:4]]
which, got_path, tmpl_path = sys.argv[1], sys.argv[2], sys.argv[3]

def ob(tag, ip, sni, key):
    return {"tag": tag, "protocol": "vless",
      "settings": {"vnext": [{"address": ip, "port": 443, "users": [{"id": uuid, "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"serverName": sni, "fingerprint": "chrome", "publicKey": key, "shortId": sid, "spiderX": "/"}}}

# Транспорт «TH mobile» берётся ИЗ ШАБЛОНА СЕРВЕРА, а не записан здесь
# литералом: сервер сверяет путь префиксом и проверяет длину набивки клиента на
# попадание в свой отрезок, поэтому расхождение двух литералов — это 404 или 400
# вместо туннеля. Берётся именно inbound `vless-xhttp` — тот, в который TCP-входы
# отдают соединение по `fallbacks` (ADR 2026-10-07-1123).
raw = open(tmpl_path).read()
tmpl = json.loads(re.sub(r'(?m)^[ \t]*//.*$', '', raw))
srv = [i for i in tmpl['inbounds'] if i['tag'] == 'vless-xhttp'][0]['streamSettings']
assert srv['network'] == 'xhttp', srv['network']
xs = srv['xhttpSettings']
xhttp = {"path": xs['path'], "mode": "stream-up", "xPaddingBytes": xs['xPaddingBytes']}

def ob_xhttp(tag, ip, sni, key):
    return {"tag": tag, "protocol": "vless",
      "settings": {"vnext": [{"address": ip, "port": 443, "users": [{"id": uuid, "encryption": "none"}]}]},
      "streamSettings": {"network": "xhttp", "security": "reality",
        "realitySettings": {"serverName": sni, "fingerprint": "chrome", "publicKey": key, "shortId": sid, "spiderX": "/"},
        "xhttpSettings": xhttp}}

def want_for(remarks, obs):
    tags = [o["tag"] for o in obs]
    return {
     "remarks": remarks,
     "log": {"loglevel": "warning"},
     "dns": {"servers": ["https://1.1.1.1/dns-query"], "queryStrategy": "UseIPv4", "tag": "dns-in"},
     "inbounds": [
      {"tag": "socks", "listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": {"udp": True}, "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}},
      {"tag": "http", "listen": "127.0.0.1", "port": 10809, "protocol": "http", "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}}],
     "outbounds": obs + [
      {"tag": "direct", "protocol": "freedom"},
      {"tag": "block", "protocol": "blackhole"}],
     "observatory": {"subjectSelector": ["th"], "probeUrl": "https://www.gstatic.com/generate_204", "probeInterval": "30s"},
     "routing": {"domainStrategy": "AsIs",
      "balancers": [{"tag": "main", "selector": [tags[0]], "fallbackTag": tags[1], "strategy": {"type": "leastPing"}}],
      "rules": [
       {"inboundTag": ["dns-in"], "balancerTag": "main"},
       {"ip": ["geoip:private"], "outboundTag": "direct"},
       {"network": "udp", "port": "443", "outboundTag": "block"},
       {"network": "tcp,udp", "balancerTag": "main"}]}}

if which == "failover":
    want = want_for("TH failover", [
      ob("th2", "160.236.128.28", "cdn2.zpq.ai", pub2),
      ob("th1", "45.91.134.23", "cdn.zpq.ai", pbk)])
elif which == "mobile":
    # Адрес th1 — 45.91.134.23, прямой вход, как у «TH failover», а не
    # 45.91.134.19 из эксперимента: ADR 2026-10-07-1123, п. 2.
    want = want_for("TH mobile", [
      ob_xhttp("th2-xhttp", "160.236.128.28", "cdn2.zpq.ai", pub2),
      ob_xhttp("th1-xhttp", "45.91.134.23", "cdn.zpq.ai", pbk)])
else:
    sys.stderr.write("неизвестный профиль: " + which + "\n")
    raise SystemExit(2)

got = json.load(open(got_path))
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
CHECKPY

check_cfg() {
  # $1 — профиль (failover|mobile), $2 — путь к собранному файлу
  local rc=0
  printf '%s\n%s\n%s\n%s\n' "$uuid" "$pbk" "$pub2" "$sid" \
    | "$python_abs" "$work/check.py" "$1" "$2" "$template" > "$work/cfg-$1.out" 2>&1 || rc=$?
  return "$rc"
}

if check_cfg failover "$want"; then
  ok '«TH failover» совпадает с ожидаемым ПОЛНОСТЬЮ: теги th2/th1/direct/block, балансер main с fallbackTag th1, observatory, dns, inbounds 10808/10809, remarks. Это же — держатель того, что второй профиль не изменил его ни на байт'
else
  bad "«TH failover» разошёлся с ожидаемым: $(cat "$work/cfg-failover.out")"
fi

if check_cfg mobile "$want_mobile"; then
  ok '«TH mobile» совпадает с ожидаемым ПОЛНОСТЬЮ: теги th2-xhttp/th1-xhttp, xhttp+reality без flow, mode stream-up, балансер main с fallbackTag th1-xhttp, observatory; path и xPaddingBytes — из inbound vless-xhttp шаблона сервера'
else
  bad "«TH mobile» разошёлся с ожидаемым: $(cat "$work/cfg-mobile.out")"
fi

# Положительный контроль сверки, по одному на профиль: на фикстуре с одним
# изменённым полем она обязана сказать «разошлось». Без него зелёная сверка не
# отличалась бы от сверки, которая сравнивает что-нибудь само с собой.
#
# Поля выбраны не наугад: у «TH failover» это `fallbackTag` — без него профиль
# работал бы без резерва; у «TH mobile» — `path`, расхождение которого с
# сервером даёт 404, а не отказ ядра, то есть именно тот случай, который
# литералом в проверке не ловился бы вовсе.
control() {
  # $1 — профиль, $2 — фикстура, $3 — путь, который сверка обязана назвать
  local rc=0
  printf '%s\n%s\n%s\n%s\n' "$uuid" "$pbk" "$pub2" "$sid" \
    | "$python_abs" "$work/check.py" "$1" "$2" "$template" > "$work/mut-$1.out" 2>&1 || rc=$?
  if [ "$rc" != 0 ] && grep -q "$3" "$work/mut-$1.out"; then
    ok "сверка «$1» умеет краснеть: на фикстуре она называет $3"
  else
    bad "сверка «$1» не покраснела на подменённом $3: код $rc, вывод $(cat "$work/mut-$1.out")"
  fi
}

"$python_abs" -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["routing"]["balancers"][0]["fallbackTag"] = "direct"
json.dump(cfg, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
' "$want" "$work/mutated-failover.json"
control failover "$work/mutated-failover.json" fallbackTag

"$python_abs" -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["outbounds"][0]["streamSettings"]["xhttpSettings"]["path"] = "/другой/путь"
json.dump(cfg, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
' "$want_mobile" "$work/mutated-mobile.json"
control mobile "$work/mutated-mobile.json" path

# --- 3. Ядро принимает ОБА конфига ------------------------------------------
# Копии с правами 0644 в отдельных каталогах: образ Xray работает под uid
# 65532 и файл 0600 владельца прогона ему не прочитать — отказ выглядел бы
# отказом конфига.
#
# Проверяются ОБА профиля: у «TH mobile» своя форма streamSettings
# (network: xhttp плюс xhttpSettings), и конфиг, который ядро не примет,
# выглядел бы на устройстве как «профиль не подключается».
core="$work/core"
mkdir -p "$core/failover" "$core/mobile"
cp "$want" "$core/failover/config.json"
cp "$want_mobile" "$core/mobile/config.json"
chmod 644 "$core/failover/config.json" "$core/mobile/config.json"
if command -v xray >/dev/null 2>&1; then
  for prof in failover mobile; do
    core_rc=0
    out=$(xray run -test -c "$core/$prof/config.json" 2>&1) || core_rc=$?
    if [ "$core_rc" = 0 ]; then
      ok "ядро приняло «${prof}»: xray run -test из PATH ($(xray version 2>/dev/null | head -n 1))"
    else
      bad "xray run -test на «${prof}» вернул код $core_rc: $out"
    fi
  done
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
    for prof in failover mobile; do
      core_rc=0
      out=$(docker run --rm -v "$core/$prof:/conf:ro" "$image" run -c /conf/config.json -test 2>&1) || core_rc=$?
      if [ "$core_rc" = 0 ]; then
        ok "ядро приняло «${prof}»: xray run -test в образе $image"
      else
        bad "xray run -test на «${prof}» в образе вернул код $core_rc: $out"
      fi
    done
  fi
else
  printf 'ПРОПУСК ядро не проверено ни на одном профиле: ни xray в PATH, ни docker — поставить xray (brew install xray) или запустить там, где есть docker\n'
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
   && [ ! -e "$home/.config/vpn/happ-failover.json" ] \
   && [ ! -e "$home/.config/vpn/happ-mobile.json" ]; then
  ok "вывод xray не разобрался: отказ кодом $rc, ни ключа, ни одного из двух конфигов"
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
: > "$home/.config/vpn/happ-mobile.json"
chmod 644 "$home/.config/vpn/happ-failover.json" "$home/.config/vpn/happ-mobile.json"
rc=0
run "$home" '' "$link" || rc=$?
loose="$home/.config/vpn"
if [ "$rc" = 0 ] && [ "$(mode_of "$loose")" = 700 ] \
   && [ "$(mode_of "$loose/happ-failover.json")" = 600 ] \
   && [ "$(mode_of "$loose/happ-mobile.json")" = 600 ]; then
  ok 'уже существующие 0755/0644 приведены к 0700/0600 у каталога и ОБОИХ профилей'
else
  bad "существующие права не исправлены: код $rc, каталог $(mode_of "$loose"), файлы $(mode_of "$loose/happ-failover.json") / $(mode_of "$loose/happ-mobile.json")"
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
  [ -f "$h/.config/vpn/happ-failover.json" ] && produced=failover
  [ -f "$h/.config/vpn/happ-mobile.json" ] && produced="$produced+mobile"
  if [ "$rc" != 0 ] && [ "$produced" = no ]; then
    ok "$title: отказ кодом $rc, ни одного конфига нет"
  else
    bad "$title: код $rc, собрано: $produced"
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
if [ "$rc" != 0 ] && [ ! -f "$home/.config/vpn/happ-failover.json" ] \
   && [ ! -f "$home/.config/vpn/happ-mobile.json" ]; then
  ok "публичный ключ th2 не той формы: отказ кодом $rc, ни одного конфига нет"
else
  bad "публичный ключ th2 не той формы, а код $rc и конфиг собран"
fi
assert_no_leak 'негодный публичный ключ th2'

printf '\nитог: пройдено %s, провалено %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
