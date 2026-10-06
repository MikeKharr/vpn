#!/usr/bin/env bash
# Карта хостов bin/make-link.sh: какой адрес и какое имя попадают в ссылку.
#
# Зачем это проверять механически. Ссылка, собранная с ИМЕНЕМ ОДНОГО хоста и
# АДРЕСОМ ДРУГОГО, по форме безупречна: Happ её примет, профиль появится,
# ошибки не будет. REALITY просто не найдёт `sni` в `serverNames` того
# сервера, и устройство не подключится — а виноватым будет выглядеть сервер.
# Та же цена у перепутанного `fallback`: ссылка th2 с адресом 45.91.134.19
# ведёт на РЕЗЕРВ, и владелец, думая, что проверяет основной, проверял бы
# не его.
#
# Значения фиктивные и рождаются в прогоне. СОБРАННЫЕ ССЫЛКИ НЕ ПЕЧАТАЮТСЯ
# НИ ПРИ КАКОМ ИСХОДЕ: готовая ссылка — секрет того же веса, что UUID
# (bin/make-link.sh), и журнал Actions публичен. Печатаются только имя
# проверки и то, что не совпало, — кусками без значений.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../bin/make-link.sh"
[ -r "$script" ] || { echo "нет $script"; exit 2; }

pass=0
fail=0

fake_key() { openssl rand 32 | openssl base64 -A | tr '+/' '-_' | tr -d '='; }
fake_uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
fake_sid() { openssl rand -hex 4; }

# Запуск скрипта с фиктивными значениями на stdin. Вывод возвращается в
# переменной вызывающему, который смотрит в него только grep'ом.
run() {
  local dev="$1" host="$2"
  printf '%s\n%s\n%s\n' "$(fake_key)" "$(fake_uuid)" "$(fake_sid)" \
    | bash "$script" "$dev" "$host" 2>&1 || true
}

# $1 — заголовок, $2 — вывод, далее — куски, которые ОБЯЗАНЫ быть.
has_all() {
  local title="$1" out="$2"; shift 2
  local missing='' needle
  for needle in "$@"; do
    printf '%s' "$out" | grep -qF -- "$needle" || missing="$missing «${needle}»"
  done
  if [ -z "$missing" ]; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$title"
  else
    fail=$((fail + 1)); printf 'ПРОВАЛ %s: в выводе нет кусков:%s\n' "$title" "$missing"
  fi
}

# $1 — заголовок, $2 — вывод, далее — куски, которых быть НЕ ДОЛЖНО.
has_none() {
  local title="$1" out="$2"; shift 2
  local present='' needle
  for needle in "$@"; do
    printf '%s' "$out" | grep -qF -- "$needle" && present="$present «${needle}»"
  done
  if [ -z "$present" ]; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$title"
  else
    fail=$((fail + 1)); printf 'ПРОВАЛ %s: в выводе есть лишние куски:%s\n' "$title" "$present"
  fi
}

out_th2=$(run mac th2)
has_all 'th2: рабочая ссылка идёт ИМЕНЕМ cdn2.zpq.ai' "$out_th2" \
  '@cdn2.zpq.ai:443?' 'sni=cdn2.zpq.ai'
has_all 'th2: запасная ссылка идёт АДРЕСОМ 160.236.128.28 с тем же sni' "$out_th2" \
  '@160.236.128.28:443?'
has_all 'th2: подпись профиля несёт хост' "$out_th2" '#mac-th2' '#mac-th2-ip'
# Главная улика: в ссылках th2 не должно быть НИ ОДНОГО следа th1 — ни имени
# cdn.zpq.ai в `sni`, ни адресов первой машины.
has_none 'th2: ни имени, ни адресов th1' "$out_th2" \
  'sni=cdn.zpq.ai' '45.91.134.19' '45.91.134.23'

out_th1=$(run iphone th1)
has_all 'th1: рабочая ссылка идёт ИМЕНЕМ cdn.zpq.ai' "$out_th1" \
  '@cdn.zpq.ai:443?' 'sni=cdn.zpq.ai'
has_all 'th1: запасная ссылка идёт ПРЕЖНИМ адресом 45.91.134.19 (вход через sni)' "$out_th1" \
  '@45.91.134.19:443?'
has_all 'th1: подпись профиля несёт хост' "$out_th1" '#iphone-th1' '#iphone-th1-ip'
has_none 'th1: ни имени, ни адреса th2' "$out_th1" \
  'sni=cdn2.zpq.ai' '160.236.128.28'

# Неизвестный хост — отказ, а не ссылка «куда-нибудь»: умолчания у хоста нет
# намеренно, потому что ключ REALITY у серверов разный.
rc=0
out=$(printf '%s\n%s\n%s\n' "$(fake_key)" "$(fake_uuid)" "$(fake_sid)" \
       | bash "$script" mac th3 2>&1) || rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -qF 'Неизвестный хост' \
   && ! printf '%s' "$out" | grep -qF 'vless://'; then
  pass=$((pass + 1)); printf 'ok   неизвестный хост: отказ, ссылка не собрана (код %s)\n' "$rc"
else
  fail=$((fail + 1)); printf 'ПРОВАЛ неизвестный хост: ждали код 1 и отказ без ссылки, получили код %s\n' "$rc"
fi

# Пустой хост при пустом stdin — тоже отказ, а не th1 по умолчанию.
rc=0
out=$(printf '' | bash "$script" mac 2>&1) || rc=$?
if [ "$rc" = 1 ] && ! printf '%s' "$out" | grep -qF 'vless://'; then
  pass=$((pass + 1)); printf 'ok   хост не задан: отказ, ссылка не собрана (код %s)\n' "$rc"
else
  fail=$((fail + 1)); printf 'ПРОВАЛ хост не задан: ждали код 1 без ссылки, получили код %s\n' "$rc"
fi

printf '\nитог: %d прошло, %d провалилось\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
