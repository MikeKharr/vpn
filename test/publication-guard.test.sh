#!/usr/bin/env bash
# Приманки держателя наложений (.github/scripts/publication-guard.sh).
#
# Зачем приманки. Красный держатель без них не отличим от держателя, который
# краснеет всегда; зелёный — от держателя, который не ловит ничего. Каждая
# приманка ниже — это ошибка, которая на живой машине проходит разбор compose,
# проходит `xray run -test`, проходит выкатку и обнаруживается только
# неподключающимся клиентом или упавшим сайтом.
#
# На вход держателю идёт разобранный compose. Здесь он подаётся СОБРАННЫМ
# РУКАМИ — docker в этом прогоне не нужен, и приманки гоняются локально. Цена
# названа прямо: если `docker compose config` сменит форму вывода, образцы
# ниже устареют молча. Держит это положительный контроль внутри самого
# скрипта («ports не длинной формой» → код 2) и то, что в CI он исполняется на
# ВЫВОДЕ НАСТОЯЩЕГО docker compose, а не на этих образцах.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
guard="$here/../.github/scripts/publication-guard.sh"
[ -r "$guard" ] || { echo "нет $guard"; exit 2; }
command -v jq >/dev/null || { echo "нет jq"; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/th1.json" <<'JSON'
{
  "name": "vpn",
  "services": {
    "render": {
      "image": "alpine:3.24.2@sha256:dead",
      "env_file": [{"path": "/home/u/vpn/deploy/secrets.env", "required": true}],
      "environment": {"XRAY_TARGET": "zpq:8444", "MASK_NAME": "cdn.zpq.ai"},
      "network_mode": "none"
    },
    "xray": {
      "image": "ghcr.io/xtls/xray-core:26.9.30@sha256:beef",
      "ports": [{"mode": "ingress", "host_ip": "45.91.134.23", "target": 8443, "published": "443", "protocol": "tcp"}],
      "networks": {"edge": {"aliases": ["vpn"]}}
    }
  }
}
JSON

cat > "$tmp/th2.json" <<'JSON'
{
  "name": "vpn",
  "services": {
    "render": {
      "image": "alpine:3.24.2@sha256:dead",
      "env_file": [{"path": "/home/u/vpn/deploy/secrets.env", "required": true}],
      "environment": {"XRAY_TARGET": "mask:8444", "MASK_NAME": "cdn2.zpq.ai"},
      "network_mode": "none"
    },
    "xray": {
      "image": "ghcr.io/xtls/xray-core:26.9.30@sha256:beef",
      "ports": [{"mode": "ingress", "host_ip": "160.236.128.28", "target": 8443, "published": "443", "protocol": "tcp"}],
      "networks": {"mask": null}
    },
    "mask": {
      "image": "caddy:2.11.7-alpine@sha256:cafe",
      "ports": [{"mode": "ingress", "host_ip": "160.236.128.28", "target": 80, "published": "80", "protocol": "tcp"}],
      "networks": {"mask": null}
    }
  }
}
JSON

pass=0
fail=0

# $1 — заголовок, $2 — хост, $3 — ожидаемый код, $4 — ожидаемый кусок текста
# (пусто — не проверяется), $5 — программа jq для порчи базового образца
# (пусто — образец как есть).
case_is() {
  local title="$1" host="$2" want="$3" needle="$4" mutate="${5:-}"
  local src="$tmp/${host}.json" file="$tmp/case.json" rc=0 out
  if [ -n "$mutate" ]; then
    jq "$mutate" "$src" > "$file" || { printf 'ПРОВАЛ %s: программа jq не применилась\n' "$title"; fail=$((fail + 1)); return; }
    # Порча ОБЯЗАНА что-то менять: приманка, совпавшая с образцом, проверяет
    # пустоту. Это та же ошибка, что мутация по текстовому совпадению, которая
    # не нашла, что портить.
    if cmp -s "$src" "$file"; then
      printf 'ПРОВАЛ %s: приманка не изменила образец\n' "$title"; fail=$((fail + 1)); return
    fi
  else
    cp "$src" "$file"
  fi
  out=$(bash "$guard" "$host" "$file" 2>&1) || rc=$?
  if [ "$rc" = "$want" ] && { [ -z "$needle" ] || printf '%s' "$out" | grep -qF -- "$needle"; }; then
    pass=$((pass + 1)); printf 'ok   %s (код %s)\n' "$title" "$rc"
  else
    fail=$((fail + 1)); printf 'ПРОВАЛ %s: ждали код %s и текст «%s», получили код %s\n%s\n' \
      "$title" "$want" "$needle" "$rc" "$out"
  fi
}

echo '--- th1: резерв, одна публикация, контракт с zpq-ai ---'
case_is 'годное наложение th1' th1 0 'наложение th1'
# Голое `443:8443` — это ВСЕ адреса машины: Xray отнял бы 443 у единицы `sni`
# на прежнем адресе и уронил сайты. Признак пришёл бы с прода —
# `port is already allocated` уже после --force-recreate, при лежащем VPN.
case_is 'адрес публикации не задан' th1 1 'ВСЕ-АДРЕСА' '.services.xray.ports[0].host_ip = ""'
case_is 'адрес 0.0.0.0'            th1 1 'опубликовано не то' '.services.xray.ports[0].host_ip = "0.0.0.0"'
case_is 'адрес с опечаткой'        th1 1 'опубликовано не то' '.services.xray.ports[0].host_ip = "45.91.134.32"'
# published != 443 — имя маски перестаёт быть «родным для своего адреса».
case_is 'снаружи не 443'           th1 1 'опубликовано не то' '.services.xray.ports[0].published = "8443"'
# target != 8443 — публикация вела бы в inbound vless-443 с
# acceptProxyProtocol: true, где Xray ТРЕБУЕТ заголовок PROXY. Выкатка
# зелёная, маска снаружи молчит, клиент не подключается.
case_is 'внутри не 8443'           th1 1 'опубликовано не то' '.services.xray.ports[0].target = 443'
case_is 'вторая публикация'        th1 1 'опубликовано не то' \
  '.services.xray.ports += [{"mode":"ingress","host_ip":"45.91.134.23","target":8443,"published":"8443","protocol":"tcp"}]'
case_is 'публикация снята'         th1 1 'опубликовано не то' '.services.xray.ports = []'
case_is 'алиас vpn переименован'   th1 1 'нет алиаса vpn' '.services.xray.networks.edge.aliases = ["vpn2"]'
case_is 'XRAY_TARGET на общий вход' th1 1 'XRAY_TARGET' '.services.render.environment.XRAY_TARGET = "caddy:443"'
# Самая дорогая приманка: наложения перепутаны местами. Всё разбирается, всё
# стартует, и ни одно устройство не подключается — `sni` ссылки нет в
# serverNames сервера.
case_is 'имя маски от чужого хоста' th1 1 'MASK_NAME' '.services.render.environment.MASK_NAME = "cdn2.zpq.ai"'
case_is 'ключ уехал в окружение xray' th1 1 'приватный ключ попал бы' \
  '.services.xray.environment = {"REALITY_PRIVATE_KEY": "x"}'
case_is 'образ без digest'          th1 1 'не закреплён digest' \
  '.services.xray.image = "ghcr.io/xtls/xray-core:26.9.30"'

echo '--- положительные контроли: проверка, которая перестала проверять ---'
# Короткая форма ports: ни одного поля host_ip/published/target нет, и без
# этого контроля держатель зеленел бы, не проверив ничего.
case_is 'ports короткой формой' th1 2 'не длинной формой' '.services.xray.ports = ["443:8443"]'
# secrets.env исчез у render — значит форма вывода compose сменилась, и
# проверка «ключ не у xray» мертва.
case_is 'у render нет secrets.env' th1 2 'перестала что-либо проверять' \
  'del(.services.render.env_file) | del(.services.render.environment)'

echo '--- th2: основной, две публикации, своя маска ---'
case_is 'годное наложение th2' th2 0 'наложение th2'
case_is 'нет публикации 80 (ACME и редирект)' th2 1 'опубликовано не то' '.services.mask.ports = []'
case_is 'маска слушает все адреса' th2 1 'ВСЕ-АДРЕСА' '.services.mask.ports[0].host_ip = ""'
case_is 'внутренний 8444 опубликован наружу' th2 1 'опубликовано не то' \
  '.services.mask.ports += [{"mode":"ingress","host_ip":"160.236.128.28","target":8444,"published":"8444","protocol":"tcp"}]'
case_is 'адрес th1 на th2' th2 1 'опубликовано не то' '.services.xray.ports[0].host_ip = "45.91.134.23"'
# Сети edge на th2 нет вовсе: выкатка упала бы на отсутствующей внешней сети
# уже ПОСЛЕ --force-recreate, то есть при лежащем VPN.
case_is 'xray подмешан в edge' th2 1 'состоит в сетях' '.services.xray.networks = {"edge": {"aliases": ["vpn"]}}'
case_is 'службы mask нет'      th2 1 'нет службы mask' 'del(.services.mask)'
case_is 'target на чужой хост' th2 1 'XRAY_TARGET' '.services.render.environment.XRAY_TARGET = "zpq:8444"'
case_is 'имя маски от чужого хоста' th2 1 'MASK_NAME' '.services.render.environment.MASK_NAME = "cdn.zpq.ai"'
case_is 'Caddy без digest'     th2 1 'не закреплён digest' '.services.mask.image = "caddy:2.11.7-alpine"'

echo '--- аргументы ---'
rc=0; out=$(bash "$guard" th3 "$tmp/th1.json" 2>&1) || rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -qF 'неизвестный хост'; then
  pass=$((pass + 1)); echo 'ok   неизвестный хост — код 2'
else
  fail=$((fail + 1)); printf 'ПРОВАЛ неизвестный хост: код %s\n%s\n' "$rc" "$out"
fi
rc=0; out=$(bash "$guard" th1 "$tmp/нет-такого.json" 2>&1) || rc=$?
if [ "$rc" = 2 ]; then
  pass=$((pass + 1)); echo 'ok   нет файла с разобранным compose — код 2'
else
  fail=$((fail + 1)); printf 'ПРОВАЛ нет файла: код %s\n%s\n' "$rc" "$out"
fi

printf '\nитог: пройдено %s, провалено %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
