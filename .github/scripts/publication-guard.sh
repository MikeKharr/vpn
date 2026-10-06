#!/usr/bin/env bash
# Держатель наложения хоста: что проект отдаёт НАРУЖУ, в каких он сетях и с
# какими значениями межрепозиторного контракта. Исполняется шагом ci.yml по
# каждому хосту и приманками test/publication-guard.test.sh — один и тот же
# файл, поэтому проверяется поведение держателя, а не его копия.
#
#   bash .github/scripts/publication-guard.sh <th1|th2> <файл с выводом
#        `docker compose -f compose.yml -f hosts/<хост>/compose.yml config
#         --format json`>
#
# На вход идёт РАЗОБРАННЫЙ compose, а не текст файлов: наложение перекрывает
# общую часть, и `grep` по двум файлам отвечал бы на вопрос «что написано», а
# не «что получится». Разбирает его docker, то есть тот же код, что исполняет
# выкатка.
#
# Почему адреса и значения контракта записаны ЗДЕСЬ вторым местом: это
# единственный способ покраснеть на опечатке в наложении. Опечатка в адресе
# или в `XRAY_TARGET` проходит и разбор, и `xray run -test`, и выкатку —
# признаком остаётся только неподключающийся клиент (находка reviewer к ADR
# 2026-10-03-0353). Смена любого из этих значений — правка ЭТОГО файла и
# наложения вместе, то есть видимая в диффе.
#
# Коды: 0 — наложение в порядке, 1 — находка, 2 — проверка не выполнилась.
set -euo pipefail

host="${1:-}"
json_file="${2:-}"
[ -n "$host" ] && [ -n "$json_file" ] || { echo "::error::нужны два аргумента: <хост> <файл с выводом docker compose config --format json>"; exit 2; }
[ -s "$json_file" ] || { echo "::error::файл $json_file пуст или не существует — разбор compose не состоялся"; exit 2; }

# Ожидания по хостам. Строка публикации — «служба адрес снаружи внутри
# протокол»; набор сверяется ЦЕЛИКОМ, поэтому лишняя публикация краснит так
# же, как снятая.
#
#   8443 внутри — это inbound `vless-8443` с `acceptProxyProtocol: false`,
#   единственный, куда может попасть соединение с интернета без заголовка
#   PROXY: при `true` Xray оборачивает слушатель в proxyproto.Listener с
#   политикой REQUIRE (transport/internet/system_listener.go:170, v26.9.30 —
#   проверено по исходнику, ADR 2026-10-05-1546, п. 1).
#   443 снаружи — иначе «SNI родной для своего адреса» перестаёт быть правдой.
#   Адрес литералом и обязателен: голое `443:8443` — это ВСЕ адреса машины.
#   На th1 это отняло бы 443 у единицы `sni` и уронило сайты; на th2 — подняло
#   бы слушателя на всех адресах, включая те, которых мы не знаем.
#   80 у th2 — вход ACME HTTP-01 и редирект маски (ADR 2026-10-05-2223, п. 1).
case "$host" in
  th1)
    want_ports='xray 45.91.134.23 443 8443 tcp'
    want_target='zpq:8444'
    want_mask='cdn.zpq.ai'
    ;;
  th2)
    want_ports='mask 160.236.128.28 80 80 tcp
xray 160.236.128.28 443 8443 tcp'
    want_target='mask:8444'
    want_mask='cdn2.zpq.ai'
    ;;
  *) echo "::error::неизвестный хост «${host}»: наложения есть у th1 и th2"; exit 2 ;;
esac

json=$(cat "$json_file")
found=0
# Сам $json в журнал не печатается: в разрешённой форме он содержит значения
# из secrets.env.

# --- положительный контроль формы --------------------------------------------
# `docker compose config` нормализует ports в длинную форму (host_ip/
# published/target/protocol). Если версия compose начнёт отдавать короткую
# строку, разбор ниже не нашёл бы ни одного поля — пусть это будет отказ с
# причиной, а не зелёный шаг, который ничего не проверил.
kinds=$(printf '%s' "$json" | jq -r '[.services | to_entries[] | (.value.ports // [])[] | type] | unique | join(",")')
if [ -n "$kinds" ] && [ "$kinds" != object ]; then
  echo "::error::docker compose config отдал ports не длинной формой, а «${kinds}» — разбор host_ip/published/target перестал бы что-либо проверять"
  exit 2
fi

# --- публикации наружу --------------------------------------------------------
# published приходит строкой в одних версиях compose и числом в других —
# отсюда tostring, иначе сверка зеленела бы или краснела от версии раннера, а
# не от содержимого наложения.
got_ports=$(printf '%s' "$json" | jq -r '
  [ .services | to_entries[] as $s | ($s.value.ports // [])[] |
    [$s.key,
     (if (.host_ip // "") == "" then "ВСЕ-АДРЕСА" else .host_ip end),
     (.published | tostring),
     (.target | tostring),
     (.protocol // "tcp")] | join(" ") ] | sort | .[]')
if [ "$got_ports" != "$want_ports" ]; then
  echo "::error::у хоста ${host} наружу опубликовано не то, что решено ADR 2026-10-05-2223, п. 2. Ждали:"
  printf '%s\n' "$want_ports" | sed 's/^/::error::  ждали: /'
  printf '%s\n' "${got_ports:-<ничего>}" | sed 's/^/::error::  вышло: /'
  echo "::error::вторая публикация и снятие существующей — отдельное решение и отдельный PR, а не попутная правка"
  found=1
fi

# --- контракт: target REALITY и имя маски -------------------------------------
# XRAY_TARGET — внутренний слушатель, за которым стоит ТОЛЬКО страница маски.
# На th1 это `zpq:8444` соседнего репозитория (имя `zpq`, а не `caddy`: под
# именем `caddy` в сети edge отвечают два Caddy), на th2 — своя служба `mask`.
# Проброс в общий вход на 443 открывал бы клиенту VPN все имена машины.
# MASK_NAME уезжает в `serverNames` REALITY: имя маски, имя в сертификате и
# `sni=` ссылки обязаны быть одним и тем же, иначе рукопожатия не будет.
got_target=$(printf '%s' "$json" | jq -r '.services.render.environment.XRAY_TARGET // ""')
if [ "$got_target" != "$want_target" ]; then
  echo "::error::XRAY_TARGET у ${host} равен «${got_target}», а наложение обязано давать «${want_target}» (ADR 2026-10-03-0353, п. 1; ADR 2026-10-05-2223, п. 2)"
  found=1
fi
got_mask=$(printf '%s' "$json" | jq -r '.services.render.environment.MASK_NAME // ""')
if [ "$got_mask" != "$want_mask" ]; then
  echo "::error::MASK_NAME у ${host} равен «${got_mask}», а наложение обязано давать «${want_mask}» — имя в serverNames REALITY, в сертификате маски и в sni= ссылок одно и то же (ADR 2026-10-05-2223)"
  found=1
fi

# --- сети ---------------------------------------------------------------------
nets=$(printf '%s' "$json" | jq -r '.services.xray.networks // {} | keys | sort | join(",")')
if [ "$host" = th1 ]; then
  # Алиас `vpn` в edge — строка межрепозиторного контракта: по нему `sni`
  # проекта zpq-ai находит контейнер и присылает ЗАПАСНОЙ вход.
  # Переименование тихо ломает путь откатa.
  alias=$(printf '%s' "$json" | jq -r '.services.xray.networks.edge.aliases // [] | join(" ")')
  case " $alias " in
    *" vpn "*) ;;
    *) echo "::error::у службы xray на th1 нет алиаса vpn в сети edge — единица sni проекта zpq-ai не найдёт её, и запасной вход мёртв (ADR 2026-10-03-0353, п. 1)"; found=1 ;;
  esac
  [ "$nets" = edge ] || { echo "::error::службa xray на th1 состоит в сетях «${nets}», а должна ровно в edge"; found=1; }
else
  # На th2 сети edge НЕТ на машине вовсе: маска живёт в самом проекте. Запись
  # xray в edge здесь означала бы, что наложение th1 подмешалось к th2, —
  # и выкатка упала бы на отсутствующей внешней сети уже после
  # `--force-recreate`, то есть при лежащем VPN.
  [ "$nets" = mask ] || { echo "::error::служба xray на th2 состоит в сетях «${nets}», а должна ровно в mask: сети edge на этой машине нет (ADR 2026-10-05-2223, п. 2)"; found=1; }
  printf '%s' "$json" | jq -e '.services.mask' >/dev/null 2>&1 \
    || { echo "::error::на th2 нет службы mask — без неё target REALITY мёртв, и не подключается ни одно устройство"; found=1; }
fi

# --- секреты видит только render ----------------------------------------------
# Проверка идёт по упоминанию `secrets.env` или имени REALITY_PRIVATE_KEY в
# службе ЦЕЛИКОМ, а не по полю env_file: `docker compose config` в разных
# версиях то оставляет env_file путями, то разрешает его в environment, и
# проверка `has("env_file")` в одной из этих форм зеленела бы всегда.
# $svc — переменная jq, не shell: кавычки одинарные намеренно.
# shellcheck disable=SC2016
probe='(.services[$svc] // {}) | tostring | test("REALITY_PRIVATE_KEY|secrets\\.env")'
holds_render=$(printf '%s' "$json" | jq -r --arg svc render "$probe")
if [ "$holds_render" != true ]; then
  echo "::error::в выводе compose нет связи render с secrets.env — форма вывода сменилась, и проверка «ключ не у xray» перестала что-либо проверять"
  exit 2
fi
for svc in $(printf '%s' "$json" | jq -r '.services | keys[] | select(. != "render")'); do
  if [ "$(printf '%s' "$json" | jq -r --arg svc "$svc" "$probe")" = true ]; then
    echo "::error::служба ${svc} упоминает secrets.env или REALITY_PRIVATE_KEY — приватный ключ попал бы в её окружение; секреты видит только render"
    found=1
  fi
done

# --- образы закреплены digest'ом ----------------------------------------------
# Тег без digest означает, что на двух серверах в разные дни поднимется разное
# ядро или разный Caddy, и расхождение не будет видно ни в одной строке диффа.
while IFS= read -r line; do
  svc="${line%% *}"; image="${line#* }"
  case "$image" in
    *@sha256:*) ;;
    *) echo "::error::образ службы ${svc} не закреплён digest'ом: ${image}"; found=1 ;;
  esac
done < <(printf '%s' "$json" | jq -r '.services | to_entries[] | "\(.key) \(.value.image // "<нет образа>")"')

if [ "$found" -ne 0 ]; then
  exit 1
fi
printf 'ok: наложение %s — публикации, контракт, сети, секреты и digest'"'"'ы на месте\n' "$host"
printf '%s\n' "$want_ports" | sed 's/^/  наружу: /'
printf '  XRAY_TARGET=%s MASK_NAME=%s\n' "$want_target" "$want_mask"
