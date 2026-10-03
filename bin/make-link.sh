#!/usr/bin/env bash
# Собирает ссылки vless:// для одного устройства и печатает их В ТЕРМИНАЛ.
# Запускает ВЛАДЕЛЕЦ на своей машине (ADR 2026-10-03-0353, п. 5).
#
# Серверной страницы подписки нет и не будет: путь с токеном на публичном
# адресе — это секрет в URL, который уходит в журналы входа, историю браузера
# и превью мессенджеров, а отзывается только переустановкой у всех устройств.
#
# Что этот скрипт НЕ делает, намеренно:
#   - не пишет ссылку, QR и значения ни в один файл (готовая ссылка — тот же
#     секрет, что UUID; .gitignore — вторая линия, не первая);
#   - не ходит на сервер и ничего оттуда не читает;
#   - не кладёт ссылку в аргументы ни одного процесса: в qrencode она уходит
#     по stdin, иначе её было бы видно в `ps`;
#   - не трогает приватный ключ REALITY: в ссылке стоит ПУБЛИЧНЫЙ (pbk).
#
# На каждое устройство выходит две ссылки: :443 — рабочая, :8443 — запасная
# на случай отката единицы `sni` в zpq-ai. Вторую импортировать выключенной.
#
# Запуск:  bash bin/make-link.sh [имя-устройства]
set -euo pipefail

SERVER_NAME="${SERVER_NAME:-cdn.zpq.ai}"
PORT_MAIN="${PORT_MAIN:-443}"
PORT_FALLBACK="${PORT_FALLBACK:-8443}"
# chrome, а не firefox: при ядре Xray >= 26.9.8 гибридный key share
# X25519MLKEM768 в utls есть только у chrome (ADR, п. 3). Цена названа там же —
# именно chrome режут на части мобильных сетей.
FINGERPRINT="${FINGERPRINT:-chrome}"

label="${1:-}"
if [ -z "$label" ]; then
  printf 'Имя устройства (попадёт в подпись профиля, например mac или iphone)\n> '
  read -r label || true
fi
case "$label" in
  '' ) echo "Имя устройства не задано — ничего не собрано." >&2; exit 1 ;;
  *[!A-Za-z0-9._-]* ) echo "В имени устройства только A-Za-z0-9._- — оно уходит во фрагмент URL." >&2; exit 1 ;;
esac

ask() {
  local name="$1" prompt="$2" form="$3" hint="$4" value=''
  while true; do
    printf '%s (ввод не отображается)\n> ' "$prompt"
    read -rs value || true
    printf '\n'
    if [ -z "$value" ]; then
      echo "Пусто — ничего не собрано." >&2
      exit 1
    fi
    if printf '%s' "$value" | grep -Eq "$form"; then
      break
    fi
    echo "Не та форма: ожидается $hint. Повторите." >&2
  done
  eval "$name=\$value"
}

ask PUBLIC_KEY 'Password/PublicKey из вывода xray x25519 — ПУБЛИЧНЫЙ ключ' \
               '^[A-Za-z0-9_-]{43}$' '43 знака base64url'
ask UUID       "UUID устройства $label"  \
               '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$' 'UUID из uuidgen'
ask SHORT_ID   "shortId устройства $label" \
               '^[0-9a-f]{8}$' '8 знаков hex'

link() {
  local port="$1" suffix="$2"
  printf 'vless://%s@%s:%s?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=%s&fp=%s&pbk=%s&sid=%s#%s\n' \
    "$UUID" "$SERVER_NAME" "$port" "$SERVER_NAME" "$FINGERPRINT" "$PUBLIC_KEY" "$SHORT_ID" "${label}${suffix}"
}

main_link=$(link "$PORT_MAIN" '')
fallback_link=$(link "$PORT_FALLBACK" '-fallback')

show() {
  local title="$1" value="$2"
  printf '\n=== %s ===\n%s\n' "$title" "$value"
  if command -v qrencode >/dev/null 2>&1; then
    # -t ANSIUTF8 — QR рисуется знаками в терминале. Файла не возникает:
    # вывод идёт в stdout, -o не передаётся.
    # Ссылка уходит по stdin, а не аргументом: аргументы процесса видны в `ps`
    # процессам того же пользователя и root, а готовая ссылка — секрет того же
    # веса, что UUID. Это то же соображение, по которому
    # deploy/render/render.sh отказывается от `sed "s|…|$val|"`
    # (находки reviewer и compliance).
    printf '%s' "$value" | qrencode -t ANSIUTF8 -m 1
  else
    echo '(QR не нарисован: нет qrencode. Поставить — brew install qrencode;'
    echo ' без него ссылку переносить AirDrop'"'"'ом или через менеджер паролей.)'
  fi
}

show "$label — рабочая, порт $PORT_MAIN" "$main_link"
show "$label — запасная, порт $PORT_FALLBACK (импортировать выключенной)" "$fallback_link"

cat <<EOF

Дальше:
  1. Импортировать рабочую ссылку в Happ (id6504287215), запасную — в список,
     выключенной.
  2. Правила маршрутизации: direct на zpq.ai, challenge.zpq.ai, mail.zpq.ai,
     ${SERVER_NAME} и локальные сети — иначе трафик к своему же серверу идёт
     петлёй через него.
  3. Вывод выше — секрет того же веса, что UUID. Очистить историю терминала:
       clear && printf '\\033[3J'
EOF
