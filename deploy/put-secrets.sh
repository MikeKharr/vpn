#!/usr/bin/env bash
# Кладёт deploy/secrets.env этого проекта на сервер. Запускает ВЛАДЕЛЕЦ со
# своей машины: новый секрет на сервере — только его руками (AGENTS.md).
#
# Форма — по образцу deploy/put-secrets.sh адвента: значения вводятся скрытно
# (`read -rs`), уходят на сервер по stdin через ssh и поэтому не попадают ни в
# историю shell, ни в список процессов, ни в вывод, ни на диск этой машины.
# Файл на сервере создаётся под umask 077 и получает chmod 600.
#
# Значения владелец получает у себя же (ADR 2026-10-03-0353, «Ручные шаги», п. 4):
#   docker run --rm ghcr.io/xtls/xray-core:26.9.30 x25519   → PrivateKey
#   uuidgen                                                 → по одному на устройство
#   openssl rand -hex 4                                     → по одному на устройство
# Ничего из этого не вставлять в чат агенту.
#
# Запуск:  bash deploy/put-secrets.sh
# Переопределения: SERVER=user@host, SSH_KEY=/путь/к/ключу, SSH_PORT=22
set -euo pipefail

SERVER="${SERVER:-advent@challenge.zpq.ai}"
SSH_PORT="${SSH_PORT:-22}"
REMOTE_PATH="vpn/deploy/secrets.env"

ssh_args=(-p "$SSH_PORT")
if [ -n "${SSH_KEY:-}" ]; then
  ssh_args+=(-i "$SSH_KEY")
fi

# Форма значений проверяется здесь, чтобы опечатка не доехала до сервера и не
# превратилась в контейнер, который падает на старте. Держателем формы остаётся
# deploy/render/render.sh: он проверяет то же самое уже на сервере, и это он
# решает, годен ли файл.
ask() {
  local name="$1" prompt="$2" form="$3" hint="$4" value=''
  while true; do
    printf '%s (ввод не отображается)\n> ' "$prompt"
    read -rs value || true
    printf '\n'
    if [ -z "$value" ]; then
      echo "Пусто — ничего не записано, выхожу." >&2
      exit 1
    fi
    if printf '%s' "$value" | grep -Eq "$form"; then
      break
    fi
    echo "Не та форма: ожидается $hint. Повторите." >&2
  done
  eval "$name=\$value"
}

UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'

ask REALITY_PRIVATE_KEY 'PrivateKey из вывода xray x25519' '^[A-Za-z0-9_-]{43}$' '43 знака base64url'
ask UUID_MAC            'UUID устройства Mac'              "$UUID_RE"            'UUID из uuidgen'
ask UUID_IPHONE         'UUID устройства iPhone'           "$UUID_RE"            'UUID из uuidgen'
ask SHORTID_MAC         'shortId устройства Mac'           '^[0-9a-f]{8}$'       '8 знаков hex, openssl rand -hex 4'
ask SHORTID_IPHONE      'shortId устройства iPhone'        '^[0-9a-f]{8}$'       '8 знаков hex, openssl rand -hex 4'

if [ "$UUID_MAC" = "$UUID_IPHONE" ] || [ "$SHORTID_MAC" = "$SHORTID_IPHONE" ]; then
  echo "Значения устройств совпали: отзыв одного отозвал бы оба. Ничего не записано." >&2
  exit 1
fi

# Скрипт исполняется на сервере, значения приходят по одному в строке stdin.
# Файл перезаписывается целиком: в нём ровно пять строк, и «сохранить
# остальное» тут нечего — в отличие от общего secrets.env адвента.
# XRAY_TARGET сюда НЕ попадает: это не секрет, а строка межрепозиторного
# контракта, и она живёт в deploy/compose.yml, где её держит шаг CI. Иначе
# смена одного не-секрета требовала бы заново ввести пять секретов
# (находка reviewer).
REMOTE_SCRIPT=$(cat <<REMOTE
set -eu
umask 077
f="${REMOTE_PATH}"
mkdir -p "\$(dirname "\$f")"
read -r key
read -r uuid_mac
read -r uuid_iphone
read -r sid_mac
read -r sid_iphone
tmp="\$(mktemp "\$(dirname "\$f")/.secrets.XXXXXX")"
trap 'rm -f "\$tmp"' EXIT
{ echo '# Секреты VPN. Только на сервере, chmod 600. Создан deploy/put-secrets.sh.'
  echo '# Читает их ТОЛЬКО контейнер render; у контейнера xray env_file нет.'
  printf 'REALITY_PRIVATE_KEY=%s\n' "\$key"
  printf 'UUID_MAC=%s\n' "\$uuid_mac"
  printf 'UUID_IPHONE=%s\n' "\$uuid_iphone"
  printf 'SHORTID_MAC=%s\n' "\$sid_mac"
  printf 'SHORTID_IPHONE=%s\n' "\$sid_iphone"
} > "\$tmp"
mv "\$tmp" "\$f"
trap - EXIT
chmod 600 "\$f"
ls -l "\$f"
# Печатаются ИМЕНА и длины, не значения: эта сессия не должна увидеть ключ.
awk -F= '/^[A-Z]/ { printf "%s: %d знаков\n", \$1, length(\$2) }' "\$f"
REMOTE
)

# SC2029: подстановка на стороне клиента здесь и нужна — REMOTE_SCRIPT собран
# выше ровно для того, чтобы уехать текстом, как в put-secrets.sh адвента.
# shellcheck disable=SC2029
printf '%s\n%s\n%s\n%s\n%s\n' \
  "$REALITY_PRIVATE_KEY" "$UUID_MAC" "$UUID_IPHONE" \
  "$SHORTID_MAC" "$SHORTID_IPHONE" \
  | ssh "${ssh_args[@]}" "$SERVER" "$REMOTE_SCRIPT"

cat <<'EOF'

Осталось сделать:
  1. Пересоздать ОБА контейнера, иначе новые значения не вступят в силу:
     render соберёт новый конфиг, а живой Xray продолжит работать с прежним —
     он читает config.json один раз на старте и reload'а не умеет.
       push в main или workflow_dispatch «deploy» в GitHub Actions.
     Руками на сервере — только владельцу:
       cd vpn/deploy && docker compose up -d --force-recreate
  2. При ротации ключа или UUID — переустановить ссылки на обоих
     устройствах: bash bin/make-link.sh (в своём терминале).
EOF
