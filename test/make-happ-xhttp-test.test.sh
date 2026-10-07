#!/usr/bin/env bash
# Проверки bin/make-happ-xhttp-test.sh — сборки ТЕСТОВОГО профиля «TH mobile
# TEST» (ADR 2026-10-07-0920, шаг 2). Исполняется САМ скрипт — тот же файл,
# который запускает владелец, а не его копия.
#
# Что здесь держится и почему именно так:
#
#   1. ЗНАЧЕНИЕ НЕ УХОДИТ В АРГУМЕНТЫ внешнего процесса. Прогон идёт с PATH, в
#      котором лежат ТОЛЬКО обёртки над mkdir, chmod и python3, и каждая пишет
#      свои аргументы в журнал. Отсюда две проверки сразу: появись в скрипте
#      `sed`, `cat`, `jq`, `grep` или `xray` — внешней команды не окажется в
#      PATH и прогон покраснеет; подставь кто-нибудь значение аргументом — его
#      найдёт сверка журнала. Проверять по `ps` нельзя: процесс живёт
#      микросекунды, и выборка `ps` была бы зелёной при любой гипотезе.
#   2. ПРАВА. Каталог 700, файл 600 — при рождении (umask) И при уже
#      существующих чужих правах (chmod), отдельными прогонами.
#   3. ЧУЖОЕ НЕ ТРОНУТО. Ключ th2 и рабочий профиль happ-failover.json лежат в
#      том же каталоге. Эксперимент не имеет права их коснуться: ключ — личность
#      сервера th2, а переимпорт рабочего профиля в поездке рвёт туннель.
#      Проверяется сверкой содержимого ДО и ПОСЛЕ и отсутствием `xray` в PATH
#      (пару ключей создать нечем, и попытка покраснела бы).
#   4. STDOUT — РОВНО ПУТЬ, одна строка.
#   5. ПОЛЯ JSON — сверка ПОЛНЫМ РАВЕНСТВОМ разобранного конфига ожидаемому, с
#      положительным контролем сверки на подменённом поле.
#   6. ТРАНСПОРТ СОВПАДАЕТ С СЕРВЕРОМ. `path` и `xPaddingBytes` сверяются не с
#      литералом в этом файле, а с inbound `vless-443` в
#      deploy/config.template.json: сервер сверяет путь префиксом
#      (splithttp/hub.go:103) и ПРОВЕРЯЕТ длину набивки клиента на попадание в
#      свой отрезок (hub.go:142-148), поэтому расхождение двух литералов — это
#      профиль, который ядро примет, а сервер отдаст 400 или 404. Два литерала
#      в двух файлах без держателя разошлись бы первой же правкой.
#   7. ФОРМА. Негодное значение не даёт собрать файл.
#   8. ЯДРО ПРИНИМАЕТ КОНФИГ: `xray run -test`. Берётся `xray` из PATH, иначе
#      закреплённый digest'ом образ из deploy/compose.yml, иначе шаг
#      пропускается С НАЗВАННОЙ ПРИЧИНОЙ и прогон остаётся зелёным — молчащий
#      пропуск не отличался бы от пройденной проверки.
#
# Чего этот файл не проверяет и проверить не может: проходит ли XHTTP через
# единицу `sni` и порог мобильного оператора. Это и есть сам эксперимент
# (README, «Тестовый профиль XHTTP»).
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
script="$root/bin/make-happ-xhttp-test.sh"
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
priv2="$(printf '%s' 'UHJpdmF0ZUJvZ3VzS2V5Tm90UmVhbDQzQ2hhcnNMb25nQUJD')"; priv2="${priv2:0:43}"

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
# обёртку: внутри прогона PATH содержит только каталог обёрток. `xray` в нём
# НЕТ намеренно — этот скрипт не имеет права звать его вовсе.
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
      # родились. Это единственный способ увидеть действие umask: после chmod
      # его следа не остаётся, и строку `umask 077` можно было бы удалить при
      # зелёном прогоне.
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

# $1 — каталог HOME, далее — строки ввода. Возвращает код скрипта; stdout и
# stderr складывает в файлы прогона.
run() {
  local home="$1"; shift
  local rc=0
  : > "$work/argv.log"
  : > "$work/birth.log"
  printf '%s\n' "$@" > "$work/stdin"
  env -i HOME="$home" PATH="$shim" "$bash_abs" "$script" \
    < "$work/stdin" > "$work/out" 2> "$work/err" || rc=$?
  return "$rc"
}

assert_no_leak() {
  local title="$1" file secret
  for file in "$work/out" "$work/err" "$work/argv.log"; do
    for secret in "$uuid" "$pbk" "$priv2" "$sid"; do
      if grep -qF -- "$secret" "$file" 2>/dev/null; then
        bad "$title: значение утекло в $(basename "$file")"
        return
      fi
    done
  done
  ok "$title: значений нет ни в stdout, ни в stderr, ни в аргументах внешних команд"
}

# stderr прогона печатается ТОЛЬКО если в нём нет ни одного значения: иначе
# мутация «значение в stderr плюс ненулевой код» уводила бы значение в публичный
# журнал Actions. На законном отказе значений в stderr нет.
safe_err() {
  local secret
  for secret in "$uuid" "$pbk" "$priv2" "$sid"; do
    if grep -qF -- "$secret" "$work/err" 2>/dev/null; then
      printf 'stderr не печатается — в нём значение (строк: %s)' \
        "$(wc -l < "$work/err" | tr -d ' ')"
      return
    fi
  done
  cat "$work/err"
}

mode_of() {
  # Порядок попыток несущий: у GNU stat `-f` ЕСТЬ и означает `--file-system`,
  # то есть BSD-форма на Linux не падает, а печатает текст про файловую
  # систему. Поэтому сначала GNU `-c`, которого у BSD нет вовсе.
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# Соседи по каталогу, которых эксперимент не имеет права тронуть.
neighbour_marker='не тронуто этим прогоном'
seed_neighbours() {
  local home="$1"
  mkdir -p "$home/.config/vpn"
  printf '%s\n' "$priv2" > "$home/.config/vpn/th2-reality.key"
  printf '%s\n' "$neighbour_marker" > "$home/.config/vpn/happ-failover.json"
}

# --- 1. Обычный прогон -------------------------------------------------------
home="$work/home-clean"
seed_neighbours "$home"
want="$home/.config/vpn/happ-xhttp-test.json"
rc=0
run "$home" "$link" || rc=$?

if [ "$rc" = 0 ]; then ok 'прогон завершился кодом 0'; else bad "прогон вернул код $rc: $(safe_err)"; fi

if [ "$(cat "$work/out")" = "$want" ]; then
  ok 'stdout — ровно путь к файлу'
else
  bad "stdout не равен пути к файлу (строк: $(wc -l < "$work/out"))"
fi

if [ -f "$want" ]; then ok 'файл профиля на месте'; else bad 'файла профиля нет'; fi
if [ -f "$want" ] && [ "$(mode_of "$want")" = 600 ]; then
  ok 'файл 0600'
else
  bad "файл $(mode_of "$want" 2>/dev/null), а не 0600"
fi
if [ "$(mode_of "$home/.config/vpn")" = 700 ]; then
  ok 'каталог 0700'
else
  bad "каталог $(mode_of "$home/.config/vpn"), а не 0700"
fi

# Держатель строки umask 077: права, с которыми файл РОДИЛСЯ, до chmod. При
# umask 022 здесь было бы 644 — то есть профиль со значениями на диске,
# читаемый всем, пока не дойдёт очередь до chmod.
#
# `|| true` здесь несущий, а не украшение: без него пустой birth.log даёт grep
# код 1, `pipefail` роняет присваивание, и `set -e` обрывает ВЕСЬ файл проверок
# без единой строки вывода.
birth_cfg=$(grep -F 'happ-xhttp-test.json' "$work/birth.log" | head -n 1 | cut -d' ' -f1 || true)
if [ "$birth_cfg" = 600 ]; then
  ok 'профиль родился 0600 (umask), а не был закрыт потом'
else
  bad "права профиля при рождении: [$birth_cfg], ждали 600"
fi

# Соседи не тронуты: ни ключ th2, ни рабочий профиль.
if [ "$(cat "$home/.config/vpn/th2-reality.key")" = "$priv2" ]; then
  ok 'ключ th2 не тронут: содержимое то же'
else
  bad 'ключ th2 изменился — это отрезало бы все клиенты от th2'
fi
if [ "$(cat "$home/.config/vpn/happ-failover.json")" = "$neighbour_marker" ]; then
  ok 'рабочий профиль happ-failover.json не тронут'
else
  bad 'рабочий профиль перезаписан — это переимпорт на двух устройствах'
fi

# Под HOME ровно три файла: два соседа и собранный профиль. Ни временного, ни
# резервной копии.
#
# ЧЕСТНАЯ ГРАНИЦА: считаются файлы ПОД HOME. Файл, записанный скриптом куда-то
# ещё (`/tmp`, каталог запуска), эта сверка не увидит; общего держателя у «ни
# одного файла нигде» нет, и держит это ревью исходника — внешних команд три,
# перенаправлений одно.
#
# Из счёта вычтен кеш байт-кода Apple'овского /usr/bin/python3: он кладёт
# ~/Library/Caches/com.apple.python/... при каждом запуске, и это пишет
# ИНТЕРПРЕТАТОР, а не проверяемый скрипт.
files=$(find "$home" -type f -not -path '*/Library/Caches/com.apple.python/*' | wc -l | tr -d ' ')
if [ "$files" = 3 ]; then ok 'под HOME ровно три файла — два соседа и профиль'; else bad "под HOME файлов: $files, ждали 3"; fi

assert_no_leak 'обычный прогон'

# Дальше проверяется САМ профиль, и без него остаток файла не проверка, а
# авария: `json.load` на отсутствующем файле падает, `set -e` обрывает прогон, и
# вывод кончается трассировкой python без строки «итог».
if [ ! -f "$want" ]; then
  bad 'профиля нет — сверка структуры, сверка с шаблоном, xray run -test и прогоны формы не выполнены'
  printf '\nитог: пройдено %s, провалено %s\n' "$pass" "$fail"
  exit 1
fi

# --- 2. Структура профиля: полное равенство ожидаемому -----------------------
# Значения уходят в python по stdin, не аргументом: те же правила, что у самого
# скрипта. Программа проверки кладётся в файл: stdin занят значениями.
cat > "$work/check.py" <<'PY'
import json, re, sys
uuid, pbk, sid = [l.strip() for l in sys.stdin.read().splitlines()[:3]]
got_path, want_path = sys.argv[1], sys.argv[2]

# Транспорт берётся ИЗ ШАБЛОНА СЕРВЕРА, а не записан здесь литералом: сервер
# сверяет путь префиксом и проверяет длину набивки клиента на попадание в свой
# отрезок, поэтому расхождение двух литералов — это 404 или 400 вместо туннеля.
raw = open(want_path).read()
tmpl = json.loads(re.sub(r'(?m)^[ \t]*//.*$', '', raw))
srv = [i for i in tmpl['inbounds'] if i['tag'] == 'vless-443'][0]['streamSettings']
assert srv['network'] == 'xhttp', srv['network']
xs = srv['xhttpSettings']

xhttp = {"path": xs['path'], "mode": "stream-up", "xPaddingBytes": xs['xPaddingBytes']}

want = {
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
     "realitySettings": {"serverName": "cdn.zpq.ai", "fingerprint": "chrome", "publicKey": pbk, "shortId": sid, "spiderX": "/"},
     "xhttpSettings": xhttp}},
  {"tag": "direct", "protocol": "freedom"},
  {"tag": "block", "protocol": "blackhole"}],
 "routing": {"domainStrategy": "AsIs",
  "rules": [
   {"inboundTag": ["dns-in"], "outboundTag": "th1-xhttp"},
   {"ip": ["geoip:private"], "outboundTag": "direct"},
   {"network": "udp", "port": "443", "outboundTag": "block"},
   {"network": "tcp,udp", "outboundTag": "th1-xhttp"}]}}

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
PY
cfg_rc=0
printf '%s\n%s\n%s\n' "$uuid" "$pbk" "$sid" \
  | "$python_abs" "$work/check.py" "$want" "$template" > "$work/cfg.out" 2>&1 || cfg_rc=$?
if [ "$cfg_rc" = 0 ]; then
  ok 'профиль совпадает с ожидаемым ПОЛНОСТЬЮ: один outbound th1-xhttp по xhttp+reality без flow, без балансировщика и observatory, path и xPaddingBytes — из шаблона сервера'
else
  bad "профиль разошёлся с ожидаемым: $(cat "$work/cfg.out")"
fi

# Положительный контроль сверки: на фикстуре с одним изменённым полем она
# обязана сказать «разошлось». Без него зелёная сверка не отличалась бы от
# сверки, которая сравнивает что-нибудь само с собой. Подменяется именно
# `path` — то поле, расхождение которого с сервером даёт 404, а не отказ ядра.
"$python_abs" -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["outbounds"][0]["streamSettings"]["xhttpSettings"]["path"] = "/другой/путь"
json.dump(cfg, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
' "$want" "$work/mutated.json"
mut_rc=0
printf '%s\n%s\n%s\n' "$uuid" "$pbk" "$sid" \
  | "$python_abs" "$work/check.py" "$work/mutated.json" "$template" > "$work/mut.out" 2>&1 || mut_rc=$?
if [ "$mut_rc" != 0 ] && grep -q 'path' "$work/mut.out"; then
  ok 'сверка умеет краснеть: на фикстуре с чужим path она называет этот путь'
else
  bad "сверка не покраснела на подменённом path: код $mut_rc, вывод $(cat "$work/mut.out")"
fi

# --- 3. Ядро принимает профиль ----------------------------------------------
# Копия с правами 0644 в отдельном каталоге: образ Xray работает под uid 65532 и
# файл 0600 владельца прогона ему не прочитать — отказ выглядел бы отказом
# конфига.
core="$work/core"
mkdir -p "$core"
cp "$want" "$core/config.json"
chmod 644 "$core/config.json"
core_rc=0
if command -v xray >/dev/null 2>&1; then
  out=$(xray run -test -c "$core/config.json" 2>&1) || core_rc=$?
  if [ "$core_rc" = 0 ]; then
    ok "ядро приняло профиль: xray run -test из PATH ($(xray version 2>/dev/null | head -n 1))"
  else
    bad "xray run -test вернул код $core_rc: $out"
  fi
elif command -v docker >/dev/null 2>&1; then
  # Образ берётся ИЗ compose, а не записан здесь второй раз: иначе проверялась
  # бы одна версия ядра, а на сервере стояла другая. `grep`, а не
  # `docker compose config`: у службы render файл secrets.env помечен required,
  # и без него разбор compose падает.
  image=$(grep -oE 'ghcr\.io/xtls/xray-core:[^ ]+' "$root/deploy/compose.yml" | head -n 1 || true)
  case "$image" in
    *@sha256:*) ;;
    *) bad "образ Xray в compose не закреплён digest'ом — проверять этим нельзя"; image='' ;;
  esac
  if [ -n "$image" ]; then
    out=$(docker run --rm -v "$core:/conf:ro" "$image" run -c /conf/config.json -test 2>&1) || core_rc=$?
    if [ "$core_rc" = 0 ]; then
      ok "ядро приняло профиль: xray run -test в образе $image"
    else
      bad "xray run -test в образе вернул код $core_rc: $out"
    fi
  fi
else
  printf 'ПРОПУСК ядро не проверено: ни xray в PATH, ни docker — поставить xray (brew install xray) или запустить там, где есть docker\n'
fi

# --- 4. Повторный прогон поверх чужих прав ----------------------------------
# Держатель строк chmod: umask на существующий каталог и существующий файл не
# действует, и без chmod профиль остался бы читаемым всем.
home="$work/home-loose"
seed_neighbours "$home"
chmod 755 "$home/.config/vpn"
: > "$home/.config/vpn/happ-xhttp-test.json"
chmod 644 "$home/.config/vpn/happ-xhttp-test.json"
rc=0
run "$home" "$link" || rc=$?
loose="$home/.config/vpn"
if [ "$rc" = 0 ] && [ "$(mode_of "$loose")" = 700 ] && [ "$(mode_of "$loose/happ-xhttp-test.json")" = 600 ]; then
  ok 'уже существующие 0755/0644 приведены к 0700/0600'
else
  bad "существующие права не исправлены: код $rc, каталог $(mode_of "$loose"), файл $(mode_of "$loose/happ-xhttp-test.json")"
fi
assert_no_leak 'прогон поверх существующего файла'

# --- 5. Проверки формы -------------------------------------------------------
# Негодная ссылка => профиля нет.
form_case() {
  local title="$1" value="$2"
  local h; h="$work/home-form-$pass-$fail"
  rm -rf "$h"
  seed_neighbours "$h"
  local rc=0
  run "$h" "$value" || rc=$?
  local produced=no
  [ -f "$h/.config/vpn/happ-xhttp-test.json" ] && produced=yes
  if [ "$rc" != 0 ] && [ "$produced" = no ]; then
    ok "$title: отказ кодом $rc, профиля нет"
  else
    bad "$title: код $rc, профиль собран: $produced"
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

printf '\nитог: пройдено %s, провалено %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
