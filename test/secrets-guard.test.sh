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
key43="$(printf '%s' 'Qm9ndXNLZXlOb3RSZWFsbHlBS2V5QnV0NDNDaGFyc0xvbmc')"
key43="${key43:0:43}"
vless="$(printf 'vless://%s@cdn.zpq.ai:443?security=reality' "$uuid")"

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
  # Находка не должна печатать саму улику: репозиторий публичный.
  if [ "$rc" = 1 ]; then
    for spec in "$@"; do
      body="${spec#*	}"
      case "$body" in
        *"$uuid"*) if printf '%s' "$out" | grep -qF "$uuid"; then
                     fail=$((fail + 1)); printf 'ПРОВАЛ %s: UUID ушёл в вывод\n' "$title"
                   fi ;;
      esac
      case "$body" in
        *"$key43"*) if printf '%s' "$out" | grep -qF "$key43"; then
                      fail=$((fail + 1)); printf 'ПРОВАЛ %s: ключ ушёл в вывод\n' "$title"
                    fi ;;
      esac
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
case_is 'UUID в *.example не находка' 0 \
  "deploy/secrets.env.example	UUID_MAC=$uuid"
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
