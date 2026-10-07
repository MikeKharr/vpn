#!/usr/bin/env bash
# Держатель слушателя маски th2: что Caddy РЕАЛЬНО соберёт из Caddyfile.
# Исполняется шагом ci.yml на выводе `caddy adapt` и приманками
# test/mask-listener-guard.test.sh — один и тот же файл.
#
#   bash .github/scripts/mask-listener-guard.sh <файл с выводом
#        `caddy adapt --config deploy/hosts/th2/Caddyfile`>
#
# На вход идёт РЕЗУЛЬТАТ адаптации, а не текст Caddyfile. Это не формальность:
# `grep` по Caddyfile зеленел бы и на заголовке, случайно уехавшем в чужой
# блок, и на `protocols`, заданном не тому серверу, — а имя при этом осталось
# бы открытым или по-прежнему называло бы внутренний порт.
#
# Что проверяется и почему каждое — улика, а не вкус:
#
#   1. `X-Robots-Tag: noindex, nofollow` у сервера :8444. Требование
#      владельца 2026-10-05. Это ВТОРОЙ носитель запрета: robots.txt просит
#      не ХОДИТЬ, заголовок запрещает ИНДЕКСИРОВАТЬ уже полученный ответ — в
#      том числе когда адрес пришёл роботу ссылкой, а не обходом. Первый
#      носитель держит .github/scripts/mask-page-guard.sh; снятие любого из
#      двух оставляет имя наполовину открытым.
#   2. `protocols` ровно ["h1","h2"] — БЕЗ h3. С умолчанием Caddy анонсирует
#      HTTP/3 заголовком `alt-svc: h3=":8444"`, то есть НАЗЫВАЕТ ЗОНДУ
#      внутренний порт, которого снаружи нет. Так сегодня у cdn.zpq.ai —
#      живой заголовок проверен владельцем 2026-10-05 (ADR 2026-10-05-2223,
#      таблица, строка «Блокировка»).
#   3. `strict_sni_host` у :8444 — запрос с подменённым Host получает 421, а
#      не страницу.
#   4. сервер :80 существует — по нему идёт ACME HTTP-01 и редирект; без него
#      сертификата не будет вовсе, а автоматический редирект Caddy повёл бы
#      на https://cdn2.zpq.ai:8444, которого снаружи нет.
#   5. наружу у этого Caddy не объявлено ничего, кроме :80 и :8444. Третий
#      слушатель означал бы, что маска отвечает там, где её не ждут.
#   6. у КАЖДОГО ACME-issuer'а выключен TLS-ALPN-01. Проверка этого типа
#      приходит на 443 ИМЕНИ, а 443 машины держит Xray — Caddy там не
#      слушает вовсе. Дойдёт ли она до :8444 пробросом зонда REALITY, не
#      гарантировано (зависит от обхождения REALITY с ALPN `acme-tls/1`), и
#      выпуск сертификата на это опираться не должен: остаётся HTTP-01 через
#      опубликованный :80. Умолчание здесь НЕ безвредно — адаптер Caddyfile
#      сам этот тип не выключает ни на каком порту сайта, то есть certmagic
#      пробовал бы его первым и жёг отдельный лимит отказов авторизации
#      Let's Encrypt. Отсутствие явного ACME-issuer'а — такая же находка:
#      тогда действуют умолчания, и TLS-ALPN-01 включён.
#
# Чего НЕ проверяет: что сертификат выпустился и что страница отдаётся живьём
# (это проверка выкатки и таблица ADR) и что не выключен HTTP-01 — последний
# путь выпуска на этой машине; `disable_http_challenge` в Caddyfile держатель
# пропустит, это на авторе и на ревью.
#
# Коды: 0 — чисто, 1 — находка, 2 — проверка не выполнилась.
set -euo pipefail

json_file="${1:-}"
[ -n "$json_file" ] || { echo "::error::нужен аргумент: файл с выводом caddy adapt"; exit 2; }
[ -s "$json_file" ] || { echo "::error::файл $json_file пуст или не существует — адаптация Caddyfile не состоялась"; exit 2; }
command -v jq >/dev/null || { echo "::error::нет jq"; exit 2; }

json=$(cat "$json_file")

# --- положительные контроли ---------------------------------------------------
# Без них проверки ниже могли бы зеленеть на выводе, в котором серверов нет
# вовсе: `jq ... // empty` на пустом наборе ничего не находит и ничего не
# говорит.
servers=$(printf '%s' "$json" | jq -r '[.apps.http.servers // {} | to_entries[]] | length')
if [ "$servers" = 0 ]; then
  echo "::error::в выводе caddy adapt нет ни одного http-сервера — либо это не вывод адаптации, либо Caddyfile пуст"
  exit 2
fi
mask=$(printf '%s' "$json" | jq -c '[.apps.http.servers[]? | select(.listen == [":8444"])]')
mask_count=$(printf '%s' "$mask" | jq 'length')
if [ "$mask_count" != 1 ]; then
  echo "::error::серверов, слушающих :8444, в выводе адаптации $mask_count, а должен быть ровно один — это target REALITY, и без него не подключается ни одно устройство"
  printf '%s' "$json" | jq -c '[.apps.http.servers[]? | .listen]' | sed 's/^/::error::  слушатели: /'
  exit 2
fi
routes=$(printf '%s' "$mask" | jq '[.[0].routes // []] | flatten | length')
if [ "$routes" = 0 ]; then
  echo "::error::у сервера :8444 нет ни одного маршрута — страницу он не отдаёт, и проверки заголовков ниже проверяли бы пустоту"
  exit 2
fi

found=0

# --- 1. noindex ---------------------------------------------------------------
if ! printf '%s' "$mask" | jq -e '[.[0] | .. | objects | select(.handler? == "headers")
      | (.response.set // {})["X-Robots-Tag"]? // empty] | flatten
      | index("noindex, nofollow") != null' >/dev/null; then
  echo "::error::у сервера :8444 нет заголовка X-Robots-Tag: noindex, nofollow — имя маски индексируемо, хотя требование владельца 2026-10-05 его закрывает; robots.txt один этого не держит (он просит не ходить, а не не индексировать)"
  printf '%s' "$mask" | jq -c '[.[0] | .. | objects | select(.handler? == "headers") | (.response.set // {})]' | sed 's/^/::error::  что найдено: /'
  found=1
fi

# --- 2. без h3 ----------------------------------------------------------------
protocols=$(printf '%s' "$mask" | jq -r '.[0].protocols // [] | join(",")')
if [ "$protocols" != "h1,h2" ]; then
  echo "::error::у сервера :8444 protocols = «${protocols:-<умолчание>}», а требуется ровно «h1,h2». С h3 Caddy шлёт alt-svc: h3=\":8444\" и называет зонду ВНУТРЕННИЙ порт, которого снаружи нет (ADR 2026-10-05-2223, таблица, «Блокировка»)"
  found=1
fi

# --- 3. строгий SNI -----------------------------------------------------------
if [ "$(printf '%s' "$mask" | jq -r '.[0].strict_sni_host // false')" != true ]; then
  echo "::error::у сервера :8444 нет strict_sni_host — запрос с подменённым Host получал бы страницу вместо 421"
  found=1
fi

# --- 4-5. набор слушателей ----------------------------------------------------
listens=$(printf '%s' "$json" | jq -r '[.apps.http.servers[]?.listen[]?] | sort | unique | join(",")')
if [ "$listens" != ":80,:8444" ]; then
  echo "::error::слушатели этого Caddy — «${listens}», а должны быть ровно «:80,:8444». :80 — вход ACME HTTP-01 и редиректа (без него сертификата не будет); третий слушатель означает, что маска отвечает там, где её не ждут"
  found=1
fi

# --- 6. выпуск только по HTTP-01 ---------------------------------------------
# Считаются ВСЕ ACME-issuer'ы всех политик, а не только первый: политика,
# добавленная позже и покрывающая то же имя, выпускала бы сертификат по своим
# правилам, и проверка «у первого выключено» этого не различила бы.
acme_total=$(printf '%s' "$json" | jq '[.apps.tls.automation.policies[]? | .issuers[]? | select(.module? == "acme")] | length')
if [ "$acme_total" = 0 ]; then
  echo "::error::в выводе адаптации нет ни одного ACME-issuer'а — значит сертификат выпускается по УМОЛЧАНИЯМ, то есть с включённым TLS-ALPN-01. Он приходит на 443 имени, а 443 этой машины держит Xray; нужен блок tls { issuer acme { disable_tlsalpn_challenge } } у сайта маски"
  found=1
else
  alpn_on=$(printf '%s' "$json" | jq '[.apps.tls.automation.policies[]? | .issuers[]? | select(.module? == "acme")
        | select((.challenges["tls-alpn"].disabled? // false) != true)] | length')
  if [ "$alpn_on" != 0 ]; then
    echo "::error::у $alpn_on из $acme_total ACME-issuer'ов TLS-ALPN-01 не выключен. Эта проверка приходит на 443 имени, а 443 машины держит Xray — Caddy там не слушает; certmagic пробовал бы её первой и жёг лимит отказов авторизации Let's Encrypt. Нужен disable_tlsalpn_challenge в issuer acme (ADR 2026-10-05-2223, п. 1: порт 80 открыт именно под HTTP-01)"
    printf '%s' "$json" | jq -c '[.apps.tls.automation.policies[]? | {subjects, issuers: [.issuers[]? | {module, challenges}]}]' | sed 's/^/::error::  политики: /'
    found=1
  fi
fi

if [ "$found" -ne 0 ]; then
  exit 1
fi
echo "ok: слушатель маски th2 — :8444 с noindex, h1/h2 без h3 и строгим SNI; :80 для ACME и редиректа; TLS-ALPN-01 выключен у всех $acme_total ACME-issuer'ов"
