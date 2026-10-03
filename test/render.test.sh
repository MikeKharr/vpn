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
    "XRAY_TARGET=zpq:443"
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
case_is 'одинаковые shortId'    3 'отозвал бы оба' "$template" 'SHORTID_MAC=0a0a0a0a' 'SHORTID_IPHONE=0a0a0a0a'

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
import json, sys
cfg = json.load(open(sys.argv[1]))
assert cfg['log'] == {'access': 'none', 'error': '', 'loglevel': 'warning', 'dnsLog': False}, cfg['log']
ports = [i['port'] for i in cfg['inbounds']]
assert ports == [443, 8443], ports
tcp = [i['streamSettings']['tcpSettings']['acceptProxyProtocol'] for i in cfg['inbounds']]
assert tcp == [True, False], tcp
for inb in cfg['inbounds']:
    r = inb['streamSettings']['realitySettings']
    assert r['serverNames'] == ['cdn.zpq.ai'], r['serverNames']
    assert r['xver'] == 0, r['xver']
    assert r['target'] == 'zpq:443', r['target']
    assert len(r['shortIds']) == 2 and len(set(r['shortIds'])) == 2, r['shortIds']
    assert all(c['flow'] == 'xtls-rprx-vision' for c in inb['settings']['clients'])
    assert inb['settings']['decryption'] == 'none'
print('ok   результат — валидный JSON с параметрами из ADR, п. 3')
PY
then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo 'ПРОВАЛ: результат не прошёл сверку с ADR, п. 3'
fi
perm=$(stat -f '%Lp' "$dir/config.json" 2>/dev/null || stat -c '%a' "$dir/config.json")
if [ "$perm" = 400 ]; then
  pass=$((pass + 1)); echo 'ok   права результата — 400'
else
  fail=$((fail + 1)); printf 'ПРОВАЛ: права результата %s, а не 400\n' "$perm"
fi
rm -rf "$dir"

printf '\nитог: пройдено %s, провалено %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
