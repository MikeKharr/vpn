#!/usr/bin/env bash
# Отказы deploy/render/render.sh. Исполняется сам скрипт — тот же файл, что
# монтируется в единицу `render` и что запускает шаг CI с `xray run -test`.
#
# Проверяется именно ГРОМКОСТЬ отказа: «нет значения», «не та форма» и
# «остался плейсхолдер» должны давать свой код выхода, а не конфиг, который
# Xray примет и с которым ни одно устройство не подключится.
#
# Фиктивные значения собираются в момент прогона, в файлы репозитория не
# ложатся и в вывод не печатаются.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root="$here/.."
render="$root/deploy/render/render.sh"
template="$root/deploy/config.template.json"
[ -x "$render" ] || { echo "нет $render"; exit 2; }

pass=0
fail=0

# Фиктивные, но формой годные значения. Ключ — случайные 32 байта в base64url
# без выравнивания: ровно 43 знака, как у вывода `xray x25519`.
fake_key() { openssl rand 32 | openssl base64 -A | tr '+/' '-_' | tr -d '='; }
fake_uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
fake_sid() { openssl rand -hex 4; }

# Годный набор. Перекрытия в прогонах ниже задаются как NAME=VALUE,
# выбрасывание значения — как -NAME.
base_env() {
  printf '%s\n' \
    "REALITY_PRIVATE_KEY=$(fake_key)" \
    "UUID_MAC=$(fake_uuid)" \
    "UUID_IPHONE=$(fake_uuid)" \
    "SHORTID_MAC=$(fake_sid)" \
    "SHORTID_IPHONE=$(fake_sid)" \
    "XRAY_TARGET=zpq:8444" \
    "MASK_NAME=cdn2.zpq.ai"
}

# $1 — что проверяем, $2 — ожидаемый код, $3 — ожидаемый кусок текста,
# $4 — путь к шаблону, далее — перекрытия.
case_is() {
  local title="$1" want="$2" needle="$3" tmpl="$4"; shift 4
  local dir rc=0 out line name over
  local -a pairs=()
  while IFS= read -r line; do
    name="${line%%=*}"
    for over in "$@"; do
      case "$over" in
        "-$name") name=''; break ;;
        "$name="*) line="$over" ;;
      esac
    done
    [ -n "$name" ] && pairs+=("$line")
  done < <(base_env)
  dir=$(mktemp -d)
  out=$(env -i PATH="$PATH" "${pairs[@]}" TEMPLATE="$tmpl" OUT="$dir/config.json" \
        bash "$render" 2>&1) || rc=$?
  local produced=no
  [ -f "$dir/config.json" ] && produced=yes
  local leftovers=no
  [ -f "$dir/config.json" ] && grep -q '__[A-Z0-9_]*__' "$dir/config.json" && leftovers=yes
  rm -rf "$dir"
  if [ "$rc" = "$want" ] && printf '%s' "$out" | grep -qF -- "$needle"; then
    pass=$((pass + 1)); printf 'ok   %s (код %s)\n' "$title" "$rc"
  else
    fail=$((fail + 1)); printf 'ПРОВАЛ %s: ждали код %s и текст «%s», получили код %s\n%s\n' \
      "$title" "$want" "$needle" "$rc" "$out"
  fi
  # Отказ не имеет права оставить после себя файл: healthcheck единицы
  # `render` — это «файл на месте», и недособранный файл стал бы зелёным
  # признаком готовности.
  if [ "$want" != 0 ] && [ "$produced" = yes ]; then
    fail=$((fail + 1)); printf 'ПРОВАЛ %s: после отказа остался config.json\n' "$title"
  fi
  if [ "$want" = 0 ] && [ "$leftovers" = yes ]; then
    fail=$((fail + 1)); printf 'ПРОВАЛ %s: в результате остался плейсхолдер\n' "$title"
  fi
}

case_is 'годный набор' 0 'плейсхолдеров не осталось' "$template"

case_is 'нет приватного ключа' 2 'REALITY_PRIVATE_KEY' "$template" -REALITY_PRIVATE_KEY
case_is 'нет XRAY_TARGET'      2 'XRAY_TARGET'         "$template" -XRAY_TARGET
case_is 'ключ короче 43 знаков' 3 'не той формы' "$template" 'REALITY_PRIVATE_KEY=слишкомкоротко'
case_is 'shortId в 4 знака'     3 'SHORTID_MAC'   "$template" 'SHORTID_MAC=abcd'
case_is 'shortId в верхнем регистре' 3 'SHORTID_IPHONE' "$template" 'SHORTID_IPHONE=ABCDEF12'
case_is 'UUID без дефисов'      3 'UUID_MAC'      "$template" 'UUID_MAC=7f3a9c1e4b2d41e89a7c0d5e6f8a1b23'
case_is 'target без порта'      3 'XRAY_TARGET'   "$template" 'XRAY_TARGET=caddy'
# MASK_NAME появился в ADR 2026-10-05-2223: имя маски стало плейсхолдером,
# потому что шаблон один на два хоста. Отсутствие значения обязано быть
# ОТКАЗОМ, а не подстановкой пустой строки: `serverNames: [""]` — конфиг,
# который `xray run -test` ПРИМЕТ, а ни одно устройство не подключит.
case_is 'нет MASK_NAME'         2 'MASK_NAME'     "$template" -MASK_NAME
case_is 'MASK_NAME пустой'      2 'MASK_NAME'     "$template" 'MASK_NAME='
case_is 'MASK_NAME без точки'   3 'MASK_NAME'     "$template" 'MASK_NAME=localhost'
# Пробел и кавычка сломали бы JSON уже ПОСЛЕ подстановки, то есть отказом
# ядра на сервере, а не отказом рендера.
case_is 'MASK_NAME с пробелом'  3 'MASK_NAME'     "$template" 'MASK_NAME=cdn2 zpq.ai'
# Значение собрано из кусков: литерал «SHORTID_MAC=<8 hex>» сам стал бы
# находкой сторожа публичного репозитория (он ловит shortId в контексте).
same=$(printf '%s%s' 0a0a 0a0a)
case_is 'одинаковые shortId'    3 'отозвал бы оба' "$template" "SHORTID_MAC=$same" "SHORTID_IPHONE=$same"

# Плейсхолдер, которого нет в списке подстановки: шаблон опережает скрипт.
# Без этой ветви опечатка в имени плейсхолдера дала бы конфиг со строкой
# `__UUID_IPAD__` в поле id — Xray такой id не примет, но узнал бы об этом
# только сервер, а не прогон.
extra=$(mktemp -d)
sed 's/__UUID_IPHONE__/__UUID_IPAD__/' "$template" > "$extra/template.json"
case_is 'в шаблоне неизвестный плейсхолдер' 4 '__UUID_IPAD__' "$extra/template.json"
rm -rf "$extra"

# Результат годного набора — валидный JSON с теми значениями, что подали.
dir=$(mktemp -d)
# Не mapfile: в bash 3.2 на macOS его нет, а прогон идёт и локально.
pairs=()
while IFS= read -r line; do pairs+=("$line"); done < <(base_env)
env -i PATH="$PATH" "${pairs[@]}" TEMPLATE="$template" OUT="$dir/config.json" bash "$render" >/dev/null
if python3 - "$dir/config.json" <<'PY'
import json, re, sys
# Ядро Xray отбрасывает комментарии при чтении конфига, и в шаблоне они есть —
# там объяснено, почему правило блокировки не ломает маскировку. json.load их
# не понимает, поэтому снимаются строки, которые ЦЕЛИКОМ являются комментарием.
# Хвостовой комментарий (`"xver": 0, // …`) этот снос НЕ трогает, и тогда
# json.load падает — то есть ошибаться он может только в красную сторону.
# Авторитет по «примет ли это ядро» остаётся за шагом CI `xray run -test`.
raw = open(sys.argv[1]).read()
cfg = json.loads(re.sub(r'(?m)^[ \t]*//.*$', '', raw))
assert cfg['log'] == {'access': 'none', 'error': '', 'loglevel': 'warning', 'dnsLog': False}, cfg['log']
ports = [i['port'] for i in cfg['inbounds']]
assert ports == [443, 8443], ports
tcp = [i['streamSettings']['tcpSettings']['acceptProxyProtocol'] for i in cfg['inbounds']]
assert tcp == [True, False], tcp
for inb in cfg['inbounds']:
    r = inb['streamSettings']['realitySettings']
    # Имя приходит из MASK_NAME (base_env выше), а не литералом из шаблона:
    # литерал стоял здесь до ADR 2026-10-05-2223 и был бы именем ПЕРВОГО
    # хоста на втором сервере — то есть `sni`, которого нет в serverNames.
    assert r['serverNames'] == ['cdn2.zpq.ai'], r['serverNames']
    assert r['xver'] == 0, r['xver']
    assert r['target'] == 'zpq:8444', r['target']
    assert len(r['shortIds']) == 2 and len(set(r['shortIds'])) == 2, r['shortIds']
    assert all(c['flow'] == 'xtls-rprx-vision' for c in inb['settings']['clients'])
    assert inb['settings']['decryption'] == 'none'

# Выход в приватные сети закрыт в самом Xray. Без этих строк правило снимут
# попутной правкой, и прогон останется зелёным: `xray run -test` конфиг без
# маршрутизации принимает молча.
tags = {o['tag']: o['protocol'] for o in cfg['outbounds']}
assert tags.get('block') == 'blackhole', tags
# domainStrategy — не косметика: при умолчании AsIs правило с одним `ip` не
# матчит цель, заданную ИМЕНЕМ, и клиент дотянулся бы до соседа по сети edge
# через Docker DNS, обойдя блок целиком.
assert cfg['routing']['domainStrategy'] == 'IPIfNonMatch', cfg['routing']['domainStrategy']
blocking = [r for r in cfg['routing']['rules'] if r.get('outboundTag') == 'block']
assert len(blocking) == 1, blocking
blocked = set(blocking[0]['ip'])
required = {
    '127.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '169.254.0.0/16',
    '172.16.0.0/12', '192.168.0.0/16', '::1/128', 'fc00::/7', 'fe80::/10',
}
missing = required - blocked
assert not missing, f'в правиле блокировки нет диапазонов: {sorted(missing)}'
print('ok   результат — валидный JSON с параметрами из ADR, п. 3, и приватные сети закрыты')
PY
then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo 'ПРОВАЛ: результат не прошёл сверку с ADR, п. 3 и с запретом приватных сетей — причина в AssertionError выше'
fi
# Сначала форма GNU, потом BSD, и результат ОБЯЗАН быть восьмеричным числом.
# Обратный порядок уже дал ложный провал в CI: у GNU stat флаг -f означает
# «сведения о файловой системе», он успешно печатает блоки и иноды, а `||`
# при коде 0 не срабатывает — проверка сравнивала права с выводом про ext4
# и печатала «400, а не 400».
perm=$(stat -c '%a' "$dir/config.json" 2>/dev/null || true)
case "$perm" in
  ''|*[!0-7]*) perm=$(stat -f '%Lp' "$dir/config.json") ;;
esac
case "$perm" in
  ''|*[!0-7]*) echo "ПРОВАЛ: права файла не прочитались ни одной формой stat: «$perm»"; exit 2 ;;
esac
if [ "$perm" = 400 ]; then
  pass=$((pass + 1)); echo 'ok   права результата — 400'
else
  fail=$((fail + 1)); printf 'ПРОВАЛ: права результата %s, а не 400\n' "$perm"
fi
rm -rf "$dir"

printf '\nитог: пройдено %s, провалено %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
