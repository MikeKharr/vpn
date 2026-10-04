#!/usr/bin/env bash
# Проверки bin/make-clash.sh. Исполняется сам скрипт — тот же файл, который
# запускает владелец, а не его копия.
#
# Что здесь держится и почему именно так:
#
#   1. ЗНАЧЕНИЕ НЕ УХОДИТ В АРГУМЕНТЫ внешнего процесса. Прогон идёт с PATH,
#      в котором лежат ТОЛЬКО обёртки над grep, mkdir и chmod, и каждая
#      записывает свои аргументы в журнал. Отсюда две проверки сразу:
#      появись в скрипте `sed`, `yq`, `envsubst` или `tee` — внешней команды
#      не окажется в PATH и прогон покраснеет; подставь кто-нибудь значение
#      аргументом в grep/mkdir/chmod — его найдёт сверка журнала. Проверять
#      по `ps` нельзя: процесс живёт микросекунды, и выборка `ps` была бы
#      зелёной при любой гипотезе.
#   2. ПРАВА. Каталог 700, файл 600 — при рождении (umask) И при уже
#      существующих чужих правах (chmod). Второй случай отдельным прогоном:
#      без него строки chmod можно удалить, оставив прогон зелёным.
#   3. ОДИН ФАЙЛ. После прогона под $HOME лежит ровно целевой файл: ни
#      временного, ни резервной копии.
#   4. STDOUT — РОВНО ПУТЬ, одна строка. Приглашения в stderr.
#   5. ФОРМА. Негодное значение не даёт собрать файл.
#   6. ПОЛЯ YAML — поле в поле по ADR 2026-10-04-1726.
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
script="$here/../bin/make-clash.sh"
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
pub="$(printf '%s' 'Qm9ndXNLZXlOb3RSZWFsbHlBS2V5QnV0NDNDaGFyc0xvbmc')"
pub="${pub:0:43}"

bash_abs=$(command -v bash)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Обёртки над внешними командами. Реальный путь берётся здесь и вшивается в
# обёртку: внутри прогона PATH содержит только каталог обёрток.
shim="$work/shim"
mkdir -p "$shim"
stat_abs=$(command -v stat) || { echo "нет stat"; exit 2; }
for cmd in grep mkdir chmod; do
  real=$(command -v "$cmd") || { echo "нет $cmd"; exit 2; }
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "%s $*" >> "%s"\n' "$cmd" "$work/argv.log"
    if [ "$cmd" = chmod ]; then
      # Права ДО применения chmod — то есть те, с которыми каталог и файл
      # родились. Это единственный способ увидеть действие umask: после
      # chmod его следа не остаётся, и строку `umask 077` можно было бы
      # удалить при зелёном прогоне. Окно между созданием файла с секретом и
      # chmod существует, и закрывает его только umask.
      printf 'for a; do :; done\n'
      # shellcheck disable=SC2016
      printf 'm=$(%s -f "%%Lp" "$a" 2>/dev/null || %s -c "%%a" "$a")\n' "$stat_abs" "$stat_abs"
      # shellcheck disable=SC2016
      printf 'printf "%%s %%s\\n" "$m" "$a" >> "%s"\n' "$work/birth.log"
    fi
    printf 'exec %s "$@"\n' "$real"
  } > "$shim/$cmd"
  chmod 755 "$shim/$cmd"
done

# $1 — каталог HOME, далее — строки ввода. Возвращает код скрипта;
# stdout и stderr складывает в файлы прогона.
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

# Ни один из трёх секретов не имеет права оказаться в выводе или в аргументах
# внешних команд. Проверка зовётся после КАЖДОГО прогона, включая отказы.
assert_no_leak() {
  local title="$1" file secret
  for file in "$work/out" "$work/err" "$work/argv.log"; do
    for secret in "$uuid" "$pub" "$sid"; do
      if grep -qF -- "$secret" "$file" 2>/dev/null; then
        bad "$title: значение утекло в $(basename "$file")"
        return
      fi
    done
  done
  ok "$title: значений нет ни в stdout, ни в stderr, ни в аргументах внешних команд"
}

mode_of() {
  # stat на macOS и в GNU coreutils зовётся по-разному.
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

# --- 1. Обычный прогон на чистом HOME ---------------------------------------
home="$work/home-clean"
mkdir -p "$home"
rc=0
run "$home" "$uuid" "$pub" "$sid" || rc=$?
want="$home/Library/Application Support/vpn/clash-mac.yaml"

if [ "$rc" = 0 ]; then ok 'прогон завершился кодом 0'; else bad "прогон вернул код $rc: $(cat "$work/err")"; fi

if [ "$(cat "$work/out")" = "$want" ]; then
  ok 'stdout — ровно путь к файлу'
else
  bad "stdout не равен пути к файлу (строк: $(wc -l < "$work/out"))"
fi

if [ -f "$want" ]; then ok 'файл профиля на месте'; else bad 'файла профиля нет'; fi

if [ "$(mode_of "$want")" = 600 ]; then ok 'файл 0600'; else bad "файл $(mode_of "$want"), а не 0600"; fi
if [ "$(mode_of "$home/Library/Application Support/vpn")" = 700 ]; then
  ok 'каталог 0700'
else
  bad "каталог $(mode_of "$home/Library/Application Support/vpn"), а не 0700"
fi

# Держатель строки umask 077: права, с которыми каталог и файл РОДИЛИСЬ, до
# chmod. При umask 022 здесь было бы 755 и 644 — то есть секрет на диске,
# читаемый всем, пока не дойдёт очередь до chmod.
birth=$(cut -d' ' -f1 "$work/birth.log" | tr '\n' ' ')
if [ "$birth" = '700 600 ' ]; then
  ok 'каталог и файл родились 0700/0600 (umask), а не были закрыты потом'
else
  bad "права при рождении: [$birth], ждали [700 600 ]"
fi

files=$(find "$home" -type f | wc -l | tr -d ' ')
if [ "$files" = 1 ]; then ok 'под HOME ровно один файл — целевой'; else bad "под HOME файлов: $files"; fi

assert_no_leak 'обычный прогон'

# --- 2. Поля YAML -----------------------------------------------------------
# Каждое поле — отдельная строка ожидания. Сверяется ПОЛНАЯ строка файла
# (-x), иначе проверка зеленела бы на `udp: false`, содержащем `udp:`.
have_line() {
  local needle="$1"
  if grep -qxF -- "$needle" "$want"; then
    ok "поле на месте: ${2:-$needle}"
  else
    bad "поля нет или оно другое: ${2:-$needle}"
  fi
}

have_line 'mode: rule'
have_line 'find-process-mode: strict'
have_line '  - name: vpn'
have_line '    type: vless'
have_line '    server: cdn.zpq.ai'
have_line '    port: 443'
have_line "    uuid: $uuid" 'uuid: <значение>'
have_line '    flow: xtls-rprx-vision'
have_line '    udp: true'
have_line '    packet-encoding: xudp'
have_line '    tls: true'
have_line '    servername: cdn.zpq.ai'
have_line '    client-fingerprint: chrome'
have_line '    reality-opts:'
have_line "      public-key: $pub" 'public-key: <значение>'
have_line "      short-id: $sid" 'short-id: <значение>'
have_line '      support-x25519mlkem768: true'
have_line '    network: tcp'
have_line '      enabled: false'
have_line '  - name: PROXY'
have_line '    type: select'
have_line '    proxies: [vpn]'
have_line '  enhanced-mode: redir-host'
have_line '    - https://1.1.1.1/dns-query#PROXY'
have_line '  proxy-server-nameserver:'
have_line '    - https://1.1.1.1/dns-query'
# Обратный слэш в файле ОДИН: это регулярное выражение mihomo. Удвоение в
# формате printf — деталь printf, и если оно уедет в файл, mihomo получит
# другое выражение.
have_line '  - PROCESS-PATH-REGEX,^/Applications/Yandex\.app/,DIRECT'
have_line '  - DOMAIN-SUFFIX,zpq.ai,DIRECT'
have_line '  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve'
have_line '  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve'
have_line '  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve'
have_line '  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve'
have_line '  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve'
have_line '  - IP-CIDR6,fc00::/7,DIRECT,no-resolve'
have_line '  - IP-CIDR6,fe80::/10,DIRECT,no-resolve'
have_line '  - MATCH,PROXY'

# Порядок правил несущий: MATCH,PROXY обязан быть ПОСЛЕДНИМ правилом, иначе
# всё остальное в списке мертво — включая обход для Яндекса.
#
# Список правил — это строки `  - ЗАГЛАВНАЯ…`: элементы proxies и
# proxy-groups начинаются с `  - name:` и под образец не подходят.
rules=$(grep '^  - [A-Z]' "$want")
if [ "$(printf '%s\n' "$rules" | tail -n 1)" = '  - MATCH,PROXY' ]; then
  ok 'MATCH,PROXY — последнее правило'
else
  bad 'MATCH,PROXY не последнее правило'
fi
# Обход для Яндекса — первым: стоящее выше правило уводило бы его трафик
# раньше, чем до него дойдёт очередь.
if [ "$(printf '%s\n' "$rules" | head -n 1)" = '  - PROCESS-PATH-REGEX,^/Applications/Yandex\.app/,DIRECT' ]; then
  ok 'правило по пути процесса — первое'
else
  bad 'правило по пути процесса не первое'
fi

# В файле не должно остаться незаполненного места под значение.
if grep -qE '%s|__[A-Z_]+__|<[A-ZА-Я_]+>' "$want"; then
  bad 'в файле остался плейсхолдер'
else
  ok 'плейсхолдеров в файле не осталось'
fi

# --- 3. HOME с уже существующими чужими правами -----------------------------
# Держатель строк chmod: umask на существующий каталог и существующий файл не
# действует, и без chmod профиль остался бы читаемым всем.
home="$work/home-loose"
mkdir -p "$home/Library/Application Support/vpn"
chmod 755 "$home/Library/Application Support/vpn"
: > "$home/Library/Application Support/vpn/clash-mac.yaml"
chmod 644 "$home/Library/Application Support/vpn/clash-mac.yaml"
rc=0
run "$home" "$uuid" "$pub" "$sid" || rc=$?
loose="$home/Library/Application Support/vpn"
if [ "$rc" = 0 ] && [ "$(mode_of "$loose")" = 700 ] && [ "$(mode_of "$loose/clash-mac.yaml")" = 600 ]; then
  ok 'уже существующие 0755/0644 приведены к 0700/0600'
else
  bad "существующие права не исправлены: код $rc, каталог $(mode_of "$loose"), файл $(mode_of "$loose/clash-mac.yaml")"
fi
assert_no_leak 'прогон поверх существующего файла'

# --- 4. Проверки формы ------------------------------------------------------
# Негодное значение => файла нет. Подаются ВСЕ ТРИ значения, одно из них
# негодное, — а не одно негодное и конец ввода. Разница несущая: при
# оборванном вводе прогон покраснел бы и от исчерпанного stdin, то есть
# ослабление формы (образец `.` вместо `^…$`) осталось бы зелёным. Проба это
# показала: с тремя значениями мутация образца краснит, с одним — нет.
form_case() {
  local title="$1"; shift
  local h; h="$work/home-$RANDOM$RANDOM"
  mkdir -p "$h"
  local rc=0
  run "$h" "$@" || rc=$?
  local produced=no
  [ -f "$h/Library/Application Support/vpn/clash-mac.yaml" ] && produced=yes
  if [ "$rc" != 0 ] && [ "$produced" = no ]; then
    ok "$title: отказ кодом $rc, файла нет"
  else
    bad "$title: код $rc, файл собран: $produced"
  fi
  assert_no_leak "$title"
}

form_case 'пустой ввод' ''
form_case 'UUID короче формы' "${uuid%??}" "$pub" "$sid"
form_case 'UUID версии 7' \
  "$(printf '%s-%s-%s-%s-%s' 7f3a9c1e 4b2d 71e8 9a7c 0d5e6f8a1b23)" "$pub" "$sid"
form_case 'ключ короче 43 знаков' "$uuid" "${pub:0:42}" "$sid"
form_case 'ключ со знаком вне base64url' "$uuid" "${pub:0:42}+" "$sid"
form_case 'shortId в верхнем регистре' "$uuid" "$pub" 'ABCDEF12'
form_case 'shortId длиной 7' "$uuid" "$pub" "${sid:0:7}"

printf '\nитог: пройдено %s, провалено %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
