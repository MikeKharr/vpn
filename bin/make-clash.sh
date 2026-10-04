#!/usr/bin/env bash
# Собирает профиль mihomo для Clash Verge Rev на Mac и кладёт его ОДНИМ файлом
# вне репозитория. Запускает ВЛАДЕЛЕЦ на своём Mac
# (ADR 2026-10-04-1726, «Как секреты попадают в YAML»).
#
# Три значения Mac — UUID, ПУБЛИЧНЫЙ ключ REALITY, shortId — вводятся скрытым
# `read -rs` с проверкой формы, как `ask` в bin/make-link.sh. Разница между
# этими двумя скриптами одна: make-link.sh печатает секрет в терминал, этот
# пишет его в файл, потому что Verge умеет импортировать только файл.
#
# Что этот скрипт НЕ делает, намеренно:
#   - не передаёт ни одно значение АРГУМЕНТОМ внешнему процессу: YAML
#     собирается встроенным `printf` прямо в файл, никаких `sed`, `yq`,
#     `envsubst`. Аргументы процесса видны в `ps` любому процессу того же
#     пользователя, а готовый профиль — секрет того же веса, что UUID.
#     Проверку формы `grep` получает по stdin — в его аргументах только
#     образец. Внешних команд здесь ровно три: grep, mkdir, chmod, и ни одна
#     не получает значения (держатель — test/make-clash.test.sh);
#   - не пишет ни одного файла, кроме целевого: ни временного, ни резервной
#     копии. Недописанный или забытый временный файл — тот же секрет на диске,
#     только без прав и без ведома владельца;
#   - не печатает в stdout ничего, кроме пути к файлу: приглашения и ошибки
#     идут в stderr. Значение не печатается нигде и никогда — иначе оно ушло
#     бы в прокрутку терминала, то есть ровно туда, откуда его уводит скрытый
#     ввод;
#   - не ходит на сервер, не читает буфер обмена, не запускает Verge, не
#     трогает приватный ключ REALITY (в профиле стоит ПУБЛИЧНЫЙ).
#
# Шаблон ниже лежит в публичном репозитории без значений — как
# deploy/config.template.json. Сторож секретов проверяет его наравне со всем
# остальным (AGENTS.md, граница 1); приманка на заполненный профиль —
# test/secrets-guard.test.sh.
#
# Запуск:  bash bin/make-clash.sh
set -euo pipefail
# umask до первой записи: и каталог, и файл должны родиться закрытыми, а не
# быть закрыты потом. chmod ниже — для случая, когда они уже существуют с
# чужими правами (например, собраны руками до появления скрипта).
umask 077

: "${HOME:?HOME не задан — некуда писать профиль}"
OUT_DIR="$HOME/Library/Application Support/vpn"
OUT="$OUT_DIR/clash-mac.yaml"

# Приглашения — в stderr: stdout этого скрипта это ровно путь к файлу.
ask() {
  local name="$1" prompt="$2" form="$3" hint="$4" value=''
  while true; do
    printf '%s (ввод не отображается)\n> ' "$prompt" >&2
    read -rs value || true
    printf '\n' >&2
    if [ -z "$value" ]; then
      echo "Пусто — ничего не собрано." >&2
      exit 1
    fi
    # Значение уходит в grep по stdin, а не аргументом: в аргументах только
    # образец формы.
    if printf '%s' "$value" | grep -Eq "$form"; then
      break
    fi
    echo "Не та форма: ожидается $hint. Повторите." >&2
  done
  eval "$name=\$value"
}

ask UUID       'UUID этого Mac (тот же, что в Happ)' \
               '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$' \
               'UUID из uuidgen'
ask PUBLIC_KEY 'Password/PublicKey из вывода xray x25519 — ПУБЛИЧНЫЙ ключ' \
               '^[A-Za-z0-9_-]{43}$' '43 знака base64url'
ask SHORT_ID   'shortId этого Mac' \
               '^[0-9a-f]{8}$' '8 знаков hex'

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

# Шаблон — ADR 2026-10-04-1726, раздел «Профиль mihomo»; поле в поле.
# Подстановок ровно три: %s для UUID, публичного ключа и shortId.
#
# Обратные слэши удвоены (`Yandex\\.app`): это ФОРМАТ printf, и одиночный
# слэш перед точкой он разобрал бы как escape-последовательность. В файл
# уходит `^/Applications/Yandex\.app/` — регулярное выражение, которого ждёт
# mihomo.
#
# Настройки TUN в профиле не стоят и стоять не могут: по ADR («Настройки
# Verge», п. 3) TUN включается в самом Verge, DNS Hijack `any:53` и stack
# задаются там же, а DNS Overwrite для этого профиля выключается. Ниже они
# записаны комментарием, чтобы файл, попав в руки через год, сам напоминал,
# чего в нём нет.
#
# Пометки «не проверено» перенесены из ADR, раздел «Проверено лично»: на
# момент сборки скрипта Verge не был установлен и ни одного подключения не
# было.
printf 'mode: rule
find-process-mode: strict

proxies:
  - name: vpn
    type: vless
    server: cdn.zpq.ai
    port: 443
    uuid: %s
    flow: xtls-rprx-vision
    udp: true
    packet-encoding: xudp
    tls: true
    servername: cdn.zpq.ai
    client-fingerprint: chrome
    reality-opts:
      public-key: %s
      short-id: %s
      support-x25519mlkem768: true
    network: tcp
    smux:
      enabled: false

proxy-groups:
  - name: PROXY
    type: select
    proxies: [vpn]

dns:
  enable: true
  enhanced-mode: redir-host
  nameserver:
    - https://1.1.1.1/dns-query#PROXY
  proxy-server-nameserver:
    - https://1.1.1.1/dns-query

rules:
  - PROCESS-PATH-REGEX,^/Applications/Yandex\\.app/,DIRECT
  - DOMAIN-SUFFIX,zpq.ai,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - IP-CIDR6,fe80::/10,DIRECT,no-resolve
  - MATCH,PROXY

# Собрано bin/make-clash.sh по ADR 2026-10-04-1726. Этот файл — секрет того
# же веса, что ссылка vless://: в нём UUID, публичный ключ REALITY и shortId.
#
# Настройки, которых здесь нет и быть не может — они живут в самом Verge
# (ADR, «Настройки Verge»): Service Mode установлен; Tun Mode включён;
# в настройках TUN DNS Hijack = any:53, stack — умолчание Verge (gVisor);
# DNS Overwrite для ЭТОГО профиля выключен (переключатель хранится на
# профиль, иначе Verge подменит блок dns выше).
#
# Не проверено на момент сборки (ADR, «Проверено лично»): проходит ли
# рукопожатие mihomo chrome + support-x25519mlkem768 с Xray 26.9.30;
# принимает ли суффикс #PROXY в nameserver имя ГРУППЫ, а не только
# встроенное имя; стоит ли any:53 в настройках TUN по умолчанию; матчится ли
# DOMAIN-SUFFIX,zpq.ai при redir-host без включённого sniffer.
#
# После импорта в Verge (New profile -> local -> выбрать файл) Verge хранит
# свою копию, и этот файл можно удалить: rm -P
' \
  "$UUID" "$PUBLIC_KEY" "$SHORT_ID" > "$OUT"

chmod 600 "$OUT"

# Единственное, что уходит в stdout.
printf '%s\n' "$OUT"
