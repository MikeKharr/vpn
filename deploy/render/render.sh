#!/bin/sh
# Подстановка секретов в config.json Xray. Исполняется единицей `render`
# (закреплённый alpine) и шагом CI «Конфиг Xray проходит xray run -test» —
# один и тот же файл, поэтому проверенное в CI и есть выкаченное.
#
# Xray не читает переменные окружения, поэтому в репозитории живёт шаблон с
# плейсхолдерами `__ИМЯ__`, а значения приезжают из deploy/secrets.env
# (ADR 2026-10-03-0353, п. 6). Результат пишется в том на tmpfs: на диск
# сервера он не попадает и в git попасть не может.
#
# Почему sed -f, а не sed "s|…|$val|": аргументы процесса в контейнере видны
# на хосте через /proc/<pid>/cmdline, то есть `ps -ef` на сервере напечатал бы
# приватный ключ любому, у кого есть шелл. Программа sed лежит в том же
# tmpfs под umask 077 и удаляется сразу после подстановки.
#
# Коды отказа названы: 2 — нет значения, 3 — значение не той формы,
# 4 — в результате остался плейсхолдер. Тихого «отрендерили половину» нет:
# файл собирается рядом и переносится на место одним mv, поэтому
# healthcheck «файл на месте» значит «подстановка прошла целиком».
set -eu
umask 077

TEMPLATE="${TEMPLATE:-/template/config.json}"
OUT="${OUT:-/conf/config.json}"

VARS='REALITY_PRIVATE_KEY UUID_MAC UUID_IPHONE SHORTID_MAC SHORTID_IPHONE XRAY_TARGET'

die() { echo "render: $1" >&2; exit "$2"; }

missing=''
for name in $VARS; do
  eval "value=\${$name:-}"
  [ -n "$value" ] || missing="$missing $name"
done
if [ -n "$missing" ]; then
  die "в окружении нет значений:$missing — положите deploy/secrets.env скриптом deploy/put-secrets.sh" 2
fi

# Форма каждого значения проверяется здесь, а не у Xray: `xray run -test`
# примет и 4-символьный shortId, и UUID из одних нулей — конфиг валиден,
# а клиенты не подключаются. Сообщения не печатают сами значения.
check() {
  eval "value=\${$1:-}"
  printf '%s' "$value" | grep -Eq "$2" || die "значение $1 не той формы: ожидается $3" 3
}
check REALITY_PRIVATE_KEY '^[A-Za-z0-9_-]{43}$' '43 знака base64url — поле PrivateKey из вывода xray x25519'
check UUID_MAC '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$' 'UUID — вывод uuidgen'
check UUID_IPHONE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$' 'UUID — вывод uuidgen'
check SHORTID_MAC '^[0-9a-f]{8}$' '8 знаков hex в нижнем регистре — вывод openssl rand -hex 4'
check SHORTID_IPHONE '^[0-9a-f]{8}$' '8 знаков hex в нижнем регистре — вывод openssl rand -hex 4'
check XRAY_TARGET '^[A-Za-z0-9._-]+:[0-9]{1,5}$' 'хост:порт Caddy zpq-ai в сети edge, а именно zpq:443 — не caddy:443, под этим именем в edge живут два Caddy'

[ "$SHORTID_MAC" != "$SHORTID_IPHONE" ] || die 'SHORTID_MAC и SHORTID_IPHONE совпадают — отзыв одного устройства отозвал бы оба' 3
[ "$UUID_MAC" != "$UUID_IPHONE" ] || die 'UUID_MAC и UUID_IPHONE совпадают — отзыв одного устройства отозвал бы оба' 3

[ -r "$TEMPLATE" ] || die "шаблон $TEMPLATE не читается" 2

dir=$(dirname "$OUT")
mkdir -p "$dir"
program="$dir/.render.sed"
staged="$dir/.config.json"
# Программа sed и недособранный файл не должны переживать отказ.
trap 'rm -f "$program" "$staged"' EXIT INT TERM
: > "$program"
for name in $VARS; do
  eval "value=\${$name}"
  # Разделитель | безопасен: ни одно значение его содержать не может —
  # формы выше этого не допускают.
  printf 's|__%s__|%s|g\n' "$name" "$value" >> "$program"
done

sed -f "$program" "$TEMPLATE" > "$staged"
rm -f "$program"

if grep -q '__[A-Z0-9_]*__' "$staged"; then
  die "в результате остался плейсхолдер: $(grep -o '__[A-Z0-9_]*__' "$staged" | sort -u | tr '\n' ' ')" 4
fi

mv "$staged" "$OUT"
trap - EXIT INT TERM

# Права на результат. Каталог тома — 0755 root, иначе Xray (в образе
# User=65532) не вошёл бы в него вовсе; сам файл — 0400 и принадлежит тому же
# 65532, то есть читает его только процесс Xray. Без chown файл остался бы
# 0600 root (umask 077 выше), Xray получил бы «permission denied» и крутился
# бы в отказе с конфигом, который на вид на месте.
# Прогон CI идёт не от root и подменять владельца не может — это сказано в
# выводе, а не замолчано через `|| true`.
XRAY_UID="${XRAY_UID:-65532}"
if [ "$(id -u)" = 0 ]; then
  chown "$XRAY_UID:$XRAY_UID" "$OUT"
else
  echo "render: не root, владелец файла не меняется — так идёт только прогон CI" >&2
fi
chmod 400 "$OUT"

echo "render: $OUT собран ($(wc -c < "$OUT") байт), плейсхолдеров не осталось"
