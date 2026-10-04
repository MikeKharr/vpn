#!/usr/bin/env bash
# Приманки для .github/scripts/secrets-guard.sh. Исполняется САМ сторож, тот
# же файл, что в шаге CI, — а не его копия (норма I-14 адвента: защита
# приезжает вместе с держателем).
#
# Все приманки собираются из кусков в момент прогона: записанные литералом,
# UUID и ссылка сделали бы находкой сам этот файл, и сторож краснел бы всегда
# — то есть не отличал бы чистое дерево от грязного.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
guard="$here/../.github/scripts/secrets-guard.sh"
[ -x "$guard" ] || { echo "нет $guard"; exit 2; }

pass=0
fail=0

# Приманки по кускам.
uuid="$(printf '%s-%s-%s-%s-%s' 7f3a9c1e 4b2d 41e8 9a7c 0d5e6f8a1b23)"
# Тот же вид, но версия 7: под форму UUID версий 1-5 он НЕ подходит, поэтому
# ссылку с ним ловит ТОЛЬКО альтернатива vless://. Без этой приманки ветвь
# vless:// держателем не покрыта: её можно было убрать, и прогон оставался
# зелёным (находка compliance).
uuid7="$(printf '%s-%s-%s-%s-%s' 7f3a9c1e 4b2d 71e8 9a7c 0d5e6f8a1b23)"
shortid="$(printf '%s%s' 3f9c 1e4b)"
key43="$(printf '%s' 'Qm9ndXNLZXlOb3RSZWFsbHlBS2V5QnV0NDNDaGFyc0xvbmc')"
key43="${key43:0:43}"
vless="$(printf 'vless://%s@cdn.zpq.ai:443?security=reality' "$uuid")"
vless7="$(printf 'vless://%s@cdn.zpq.ai:443?security=reality' "$uuid7")"

# $1 — что проверяем, $2 — ожидаемый код, далее — строки «путь<TAB>содержимое»
case_is() {
  local title="$1" want="$2"; shift 2
  local dir rc=0 out
  dir=$(mktemp -d)
  printf '# обычный документ без улик\n' > "$dir/README.md"
  local spec path body
  for spec in "$@"; do
    path="${spec%%	*}"
    body="${spec#*	}"
    mkdir -p "$dir/$(dirname "$path")"
    printf '%b' "$body" > "$dir/$path"
  done
  out=$(bash "$guard" "$dir" 2>&1) || rc=$?
  rm -rf "$dir"
  if [ "$rc" = "$want" ]; then
    pass=$((pass + 1))
    printf 'ok   %s (код %s)\n' "$title" "$rc"
  else
    fail=$((fail + 1))
    printf 'ПРОВАЛ %s: ждали код %s, получили %s\n%s\n' "$title" "$want" "$rc" "$out"
  fi
  # Находка не должна печатать саму улику: репозиторий публичный, и журнал
  # Actions в нём — такое же публичное место, как файл. Проверяются все четыре
  # вида улики, а не только два: приманка на новую форму без этой проверки
  # закрепляла бы утечку в журнал как норму.
  if [ "$rc" = 1 ]; then
    for spec in "$@"; do
      body="${spec#*	}"
      for secret in "$uuid" "$uuid7" "$key43" "$shortid"; do
        case "$body" in
          *"$secret"*)
            if printf '%s' "$out" | grep -qF "$secret"; then
              fail=$((fail + 1)); printf 'ПРОВАЛ %s: улика ушла в вывод сторожа\n' "$title"
            fi
            ;;
        esac
      done
    done
  fi
}

case_is 'чистое дерево' 0

case_is 'UUID в документе' 1 \
  "docs/notes.md	устройство: $uuid"
case_is 'UUID в отрендеренном конфиге' 1 \
  "deploy/config.json	{ \"id\": \"$uuid\" }"
case_is 'ссылка vless:// целиком' 1 \
  "README.md	ссылка: $vless"
case_is 'ключ REALITY рядом со словом Key' 1 \
  "notes.txt	PrivateKey: $key43"
# Исключение --exclude='*.example' СНЯТО (находка compliance): оно вырезало из
# проверки ровно тот коммитимый файл, который формой значений приглашает
# подставить настоящее. Прежняя приманка закрепляла слепое место как желаемое
# поведение, поэтому она перевёрнута.
case_is 'UUID в *.example — находка' 1 \
  "deploy/secrets.env.example	UUID_MAC=$uuid"
# Формы, в которых публичный ключ встречается на практике. Каждая — отдельный
# случай: образец со словом `Key` их НЕ ловил (находки reviewer и compliance).
case_is 'публичный ключ как Password: — так печатает x25519' 1 \
  "notes.txt	Password: $key43"
case_is 'публичный ключ как pbk= — так он стоит в ссылке' 1 \
  "docs/setup.md	параметры: &pbk=$key43&flow=vision"
case_is 'публичный ключ назван по-русски' 1 \
  "agent_docs/notes.md	публичный ключ REALITY: $key43"
case_is 'shortId в контексте' 1 \
  "docs/devices.md	shortId устройства: $shortid"
# Формы из профиля mihomo (bin/make-clash.sh): ключ и shortId там названы
# `public-key` и `short-id` — через дефис, а не как в выводе xray или в
# ссылке. Каждая форма отдельным случаем, по одной улике в файле: иначе
# красный код не отличал бы «сторож видит public-key» от «сторож видит UUID
# рядом».
case_is 'ключ как public-key: — форма профиля mihomo' 1 \
  "clash-mac.yaml	      public-key: $key43"
case_is 'shortId как short-id: — форма профиля mihomo' 1 \
  "clash-mac.yaml	      short-id: $shortid"
case_is 'собранный профиль mihomo с UUID' 1 \
  "clash-mac.yaml	proxies:\n  - name: vpn\n    uuid: $uuid\n"
# А шаблон БЕЗ значений — тот, что лежит в bin/make-clash.sh и в публичном
# репозитории, — находкой быть не должен: иначе держатель краснел бы на самом
# себе и его пришлось бы исключать из проверки, то есть выключить. Те же
# строки, что в скрипте, с %s вместо значений.
case_is 'шаблон профиля mihomo с %s не находка' 0 \
  "bin/make-clash.sh	    uuid: %s\n    reality-opts:\n      public-key: %s\n      short-id: %s\n"
case_is 'shortId как SHORTID_MAC=' 1 \
  "notes.md	SHORTID_MAC=$shortid"
# Держатель ветви vless://: идентификатор не подходит под форму UUID версий
# 1-5, поэтому альтернатива с UUID его не видит, и случай краснеет ТОЛЬКО
# из-за ветви vless://.
case_is 'ссылка vless:// с идентификатором вне формы UUID' 1 \
  "README.md	ссылка: $vless7"
# Ложных находок быть не должно: сторож, краснеющий на собственном дереве,
# пришлось бы выключить.
case_is 'digest образа не находка' 0 \
  "deploy/compose.yml	image: alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6"
case_is 'слово key рядом с digest не находка' 0 \
  "notes.md	key for image sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6"
case_is 'плейсхолдеры shortIds не находка' 0 \
  "deploy/tpl.json	\"shortIds\": [\"__SHORTID_MAC__\", \"__SHORTID_IPHONE__\"]"
case_is 'PNG под своим именем' 1 \
  "qr-mac.png	\\x89PNG\\r\\n\\x1a\\nпоследовательность"
case_is 'PNG под чужим именем' 1 \
  "qr-mac.bin	\\x89PNG\\r\\n\\x1a\\nпоследовательность"
case_is 'JPEG под чужим именем' 1 \
  "photo	\\xff\\xd8\\xff\\xe0какие-то байты"
case_is 'SVG под своим именем' 1 \
  "qr.svg	<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>"
# Формат-шаблон, собирающий ссылки (bin/make-link.sh), находкой быть не должен:
# иначе держатель краснел бы на самом себе и его пришлось бы исключать из
# проверки — то есть выключить.
case_is 'формат-шаблон vless://%s@ не находка' 0 \
  "bin/make.sh	printf 'vless://%s@%s:%s' \"\$id\" \"\$host\" \"\$port\""

# Настоящее дерево: сторож обязан быть зелёным на том, что в репозитории
# лежит сейчас. Иначе красный прогон на приманке ничего не значил бы — он
# краснел бы и без неё.
rc=0
out=$(bash "$guard" "$here/.." 2>&1) || rc=$?
if [ "$rc" = 0 ]; then
  pass=$((pass + 1)); echo 'ok   рабочее дерево репозитория чисто'
else
  fail=$((fail + 1)); printf 'ПРОВАЛ: сторож краснеет на самом репозитории (код %s)\n%s\n' "$rc" "$out"
fi

printf '\nитог: пройдено %s, провалено %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
