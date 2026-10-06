#!/usr/bin/env bash
# Приманки сторожа страницы маски (.github/scripts/mask-page-guard.sh).
#
# Красный сторож без приманок не отличим от сторожа, который краснеет всегда;
# зелёный — от сторожа, который не ловит ничего. Каждая приманка ниже — это
# правка, после которой страница по-прежнему отдаётся, выглядит нормально и
# проходит выкатку, а имя при этом либо открыто роботам, либо само себя
# называет.
#
# Приманки собираются в temp-каталоге прогона: настоящие файлы
# deploy/hosts/th2/cdn/ не портятся, и сторож гоняется на копии.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root="$here/.."
guard="$root/.github/scripts/mask-page-guard.sh"
src="$root/deploy/hosts/th2/cdn"
[ -r "$guard" ] || { echo "нет $guard"; exit 2; }
[ -d "$src" ] || { echo "нет $src"; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

# $1 — заголовок, $2 — ожидаемый код, $3 — ожидаемый кусок текста
# (пусто — не проверяется), далее — команды порчи копии (исполняются в
# каталоге копии).
case_is() {
  local title="$1" want="$2" needle="$3"; shift 3
  local dir="$tmp/case" rc=0 out
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -R "$src/." "$dir/"
  local before after cmd
  before=$(find "$dir" -type f -exec cat {} + | shasum | awk '{print $1}')
  for cmd in "$@"; do
    ( cd "$dir" && eval "$cmd" )
  done
  after=$(find "$dir" -type f -exec cat {} + | shasum | awk '{print $1}')
  # Приманка, не изменившая каталог, проверяет пустоту — это та же ошибка,
  # что мутация по текстовому совпадению, которая не нашла, что портить.
  if [ "$#" -gt 0 ] && [ "$before" = "$after" ]; then
    fail=$((fail + 1)); printf 'ПРОВАЛ %s: приманка ничего не изменила в каталоге\n' "$title"; return
  fi
  out=$(bash "$guard" "$dir" 2>&1) || rc=$?
  if [ "$rc" = "$want" ] && { [ -z "$needle" ] || printf '%s' "$out" | grep -qF -- "$needle"; }; then
    pass=$((pass + 1)); printf 'ok   %s (код %s)\n' "$title" "$rc"
  else
    fail=$((fail + 1)); printf 'ПРОВАЛ %s: ждали код %s и текст «%s», получили код %s\n%s\n' \
      "$title" "$want" "$needle" "$rc" "$out"
  fi
}

case_is 'настоящая страница маски th2' 0 'ничего не выдаёт'

# Комментарий в отдаваемом файле — ровно тот дефект, который гейты zpq-ai
# нашли в первой редакции страницы th1.
case_is 'HTML-комментарий в странице' 1 'HTML-комментарий' \
  "printf '%s\n' '<!-- страница для зонда -->' >> index.html"

# Слова по одному: каждое ловится своей ветвью образца, и общий «любое слово»
# скрыл бы, что какое-то из них выпало.
case_is 'слово vpn в странице'      1 'называет назначение' "sed -i.bak 's/Nothing to browse/VPN node/' index.html && rm -f index.html.bak"
case_is 'слово xray в странице'     1 'называет назначение' "sed -i.bak 's/Nothing to browse/xray here/' index.html && rm -f index.html.bak"
case_is 'слово reality в странице'  1 'называет назначение' "sed -i.bak 's/Nothing to browse/reality target/' index.html && rm -f index.html.bak"
case_is 'внутренний порт 8444'      1 'внутренний порт' "sed -i.bak 's/Nothing to browse/port 8444/' index.html && rm -f index.html.bak"
case_is 'внутренний порт 8443'      1 'внутренний порт' "sed -i.bak 's/Nothing to browse/port 8443/' index.html && rm -f index.html.bak"
case_is 'слово «маска» по-русски'   1 'называет назначение' "sed -i.bak 's/Nothing to browse/это маска/' index.html && rm -f index.html.bak"
case_is 'имя провайдера'            1 'провайдера' "sed -i.bak 's/Nothing to browse/Triplify cloud/' index.html && rm -f index.html.bak"
# Слово в соседнем файле, а не в index.html: сторож обязан смотреть ВСЕ файлы
# каталога — Caddy отдаёт любой из них.
case_is 'слово в соседнем файле' 1 'называет назначение' \
  "printf '%s\n' 'reality' > extra.txt"

# Метка build-id: без неё проверка выкатки не отличит нашу страницу от чужого
# 200 — то есть покраснеет на проде, когда всё в порядке, или промолчит, когда
# отвечает не наш Caddy.
case_is 'метка build-id снята' 1 'cdn2-zpq-ai-static' \
  "sed -i.bak '/build-id/d' index.html && rm -f index.html.bak"

# Страница, скопированная с th1 и не поправленная: по форме безупречна, а
# называет имя, которого на этом адресе нет.
case_is 'на странице имя чужого хоста' 1 'ДРУГОГО хоста' \
  "sed -i.bak 's/cdn2\\.zpq\\.ai/cdn.zpq.ai/g' index.html && rm -f index.html.bak"

# robots.txt — первый из двух носителей требования владельца.
case_is 'robots.txt удалён'            1 'нет' 'rm -f robots.txt'
case_is 'robots.txt без Disallow'      1 'Disallow' "printf 'User-agent: *\n' > robots.txt"
case_is 'Disallow не на корень'        1 'Disallow' "printf 'User-agent: *\nDisallow: /private\n' > robots.txt"
case_is 'robots.txt без User-agent'    1 'User-agent' "printf 'Disallow: /\n' > robots.txt"

# index.html вообще нет: Caddy отдал бы листинг каталога или 404 — зонд
# увидел бы не хост статики.
case_is 'index.html удалён' 1 'нет' 'rm -f index.html'

echo '--- аргументы ---'
rc=0; out=$(bash "$guard" 2>&1) || rc=$?
if [ "$rc" = 2 ]; then
  pass=$((pass + 1)); echo 'ok   без аргумента — код 2'
else
  fail=$((fail + 1)); printf 'ПРОВАЛ без аргумента: код %s\n%s\n' "$rc" "$out"
fi
rc=0; out=$(bash "$guard" "$tmp/нет-такого" 2>&1) || rc=$?
if [ "$rc" = 2 ]; then
  pass=$((pass + 1)); echo 'ok   нет каталога — код 2'
else
  fail=$((fail + 1)); printf 'ПРОВАЛ нет каталога: код %s\n%s\n' "$rc" "$out"
fi
mkdir -p "$tmp/пусто"
rc=0; out=$(bash "$guard" "$tmp/пусто" 2>&1) || rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -qF 'пуст'; then
  pass=$((pass + 1)); echo 'ok   пустой каталог — код 2'
else
  fail=$((fail + 1)); printf 'ПРОВАЛ пустой каталог: код %s\n%s\n' "$rc" "$out"
fi

printf '\nитог: пройдено %s, провалено %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
