#!/usr/bin/env bash
# Приманки держателя слушателя маски (.github/scripts/mask-listener-guard.sh).
#
# Образец вывода `caddy adapt` собран РУКАМИ — Caddy и docker в этом прогоне
# не нужны, и приманки гоняются локально. Цена названа прямо: если Caddy
# сменит форму адаптированной конфигурации, образец устареет молча. Держат это
# положительные контроли внутри самого скрипта (нет серверов, нет сервера
# :8444, нет маршрутов → код 2) и то, что в CI он исполняется на выводе
# НАСТОЯЩЕГО `caddy adapt` того же образа по тому же digest, что идёт на
# сервер.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
guard="$here/../.github/scripts/mask-listener-guard.sh"
[ -r "$guard" ] || { echo "нет $guard"; exit 2; }
command -v jq >/dev/null || { echo "нет jq"; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/base.json" <<'JSON'
{
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [":8444"],
          "protocols": ["h1", "h2"],
          "strict_sni_host": true,
          "routes": [
            {
              "match": [{"host": ["cdn2.zpq.ai"]}],
              "handle": [
                {
                  "handler": "subroute",
                  "routes": [
                    {
                      "handle": [
                        {
                          "handler": "headers",
                          "response": {
                            "set": {
                              "X-Content-Type-Options": ["nosniff"],
                              "X-Robots-Tag": ["noindex, nofollow"]
                            },
                            "deletes": ["Server"]
                          }
                        },
                        {"handler": "file_server", "root": "/srv/cdn"}
                      ]
                    }
                  ]
                }
              ],
              "terminal": true
            }
          ]
        },
        "srv1": {
          "listen": [":80"],
          "routes": [
            {
              "match": [{"host": ["cdn2.zpq.ai"]}],
              "handle": [{"handler": "static_response", "headers": {"Location": ["https://cdn2.zpq.ai{http.request.uri}"]}, "status_code": 301}],
              "terminal": true
            }
          ]
        }
      }
    },
    "tls": {
      "automation": {
        "policies": [
          {
            "subjects": ["cdn2.zpq.ai"],
            "issuers": [
              {
                "module": "acme",
                "email": "admin@zpq.ai",
                "challenges": {"tls-alpn": {"disabled": true}}
              }
            ]
          }
        ]
      }
    }
  }
}
JSON

pass=0
fail=0

# $1 — заголовок, $2 — ожидаемый код, $3 — ожидаемый кусок текста,
# $4 — программа jq для порчи образца (пусто — образец как есть).
case_is() {
  local title="$1" want="$2" needle="$3" mutate="${4:-}"
  local file="$tmp/case.json" rc=0 out
  if [ -n "$mutate" ]; then
    jq "$mutate" "$tmp/base.json" > "$file" || { printf 'ПРОВАЛ %s: программа jq не применилась\n' "$title"; fail=$((fail + 1)); return; }
    if cmp -s "$tmp/base.json" "$file"; then
      printf 'ПРОВАЛ %s: приманка не изменила образец\n' "$title"; fail=$((fail + 1)); return
    fi
  else
    cp "$tmp/base.json" "$file"
  fi
  out=$(bash "$guard" "$file" 2>&1) || rc=$?
  if [ "$rc" = "$want" ] && { [ -z "$needle" ] || printf '%s' "$out" | grep -qF -- "$needle"; }; then
    pass=$((pass + 1)); printf 'ok   %s (код %s)\n' "$title" "$rc"
  else
    fail=$((fail + 1)); printf 'ПРОВАЛ %s: ждали код %s и текст «%s», получили код %s\n%s\n' \
      "$title" "$want" "$needle" "$rc" "$out"
  fi
}

case_is 'годная конфигурация маски' 0 'слушатель маски th2'

# Требование владельца 2026-10-05, носитель второй из двух.
case_is 'заголовок noindex снят' 1 'X-Robots-Tag' \
  'del(.apps.http.servers.srv0.routes[0].handle[0].routes[0].handle[0].response.set["X-Robots-Tag"])'
case_is 'noindex без nofollow' 1 'X-Robots-Tag' \
  '.apps.http.servers.srv0.routes[0].handle[0].routes[0].handle[0].response.set["X-Robots-Tag"] = ["noindex"]'
# Заголовок уехал в ЧУЖОЙ блок: по Caddyfile grep зеленел бы, а имя маски
# осталось бы открытым. Это и есть причина, по которой проверка идёт по
# результату адаптации.
case_is 'заголовок у сервера :80, а не у :8444' 1 'X-Robots-Tag' \
  'del(.apps.http.servers.srv0.routes[0].handle[0].routes[0].handle[0].response.set["X-Robots-Tag"])
   | .apps.http.servers.srv1.routes[0].handle += [{"handler":"headers","response":{"set":{"X-Robots-Tag":["noindex, nofollow"]}}}]'

# alt-svc: h3 — то, из-за чего зонд узнаёт внутренний порт.
case_is 'protocols с h3'          1 'protocols' '.apps.http.servers.srv0.protocols = ["h1","h2","h3"]'
case_is 'protocols по умолчанию'  1 'protocols' 'del(.apps.http.servers.srv0.protocols)'
case_is 'protocols только h1'     1 'protocols' '.apps.http.servers.srv0.protocols = ["h1"]'

case_is 'strict_sni_host снят' 1 'strict_sni_host' 'del(.apps.http.servers.srv0.strict_sni_host)'
case_is 'strict_sni_host = false' 1 'strict_sni_host' '.apps.http.servers.srv0.strict_sni_host = false'

# Без :80 не будет ни ACME HTTP-01, ни снятия авторедиректа на :8444.
case_is 'сервера :80 нет'      1 'слушатели' 'del(.apps.http.servers.srv1)'
case_is 'лишний слушатель 443' 1 'слушатели' '.apps.http.servers.srv2 = {"listen": [":443"], "routes": []}'
case_is 'порт маски сменился'  2 'слушающих :8444' '.apps.http.servers.srv0.listen = ["8444"]'

# Выпуск только по HTTP-01: TLS-ALPN-01 приходит на 443 имени, а 443 машины
# держит Xray. Снятие строки `disable_tlsalpn_challenge` из Caddyfile даёт в
# адаптации либо issuer без `challenges`, либо отсутствие issuer'а вовсе —
# оба случая ниже.
case_is 'TLS-ALPN не выключен'          1 'TLS-ALPN-01 не выключен' \
  'del(.apps.tls.automation.policies[0].issuers[0].challenges)'
case_is 'TLS-ALPN выключен значением false' 1 'TLS-ALPN-01 не выключен' \
  '.apps.tls.automation.policies[0].issuers[0].challenges["tls-alpn"].disabled = false'
# Вторая политика с тем же именем и своим issuer'ом: проверка «у первого
# выключено» этого не различила бы, поэтому считаются все issuer'ы.
case_is 'вторая политика без выключения' 1 'TLS-ALPN-01 не выключен' \
  '.apps.tls.automation.policies += [{"subjects":["cdn2.zpq.ai"],"issuers":[{"module":"acme"}]}]'
case_is 'блок tls пропал целиком'       1 'ни одного ACME-issuer' \
  'del(.apps.tls)'
echo '--- положительные контроли: проверка, которая перестала проверять ---'
case_is 'серверов нет вовсе'   2 'ни одного http-сервера' '.apps.http.servers = {}'
case_is 'два сервера :8444'    2 'должен быть ровно один' \
  '.apps.http.servers.srv2 = .apps.http.servers.srv0'
case_is 'у :8444 нет маршрутов' 2 'ни одного маршрута' '.apps.http.servers.srv0.routes = []'

echo '--- аргументы ---'
rc=0; out=$(bash "$guard" 2>&1) || rc=$?
if [ "$rc" = 2 ]; then
  pass=$((pass + 1)); echo 'ok   без аргумента — код 2'
else
  fail=$((fail + 1)); printf 'ПРОВАЛ без аргумента: код %s\n%s\n' "$rc" "$out"
fi

printf '\nитог: пройдено %s, провалено %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
