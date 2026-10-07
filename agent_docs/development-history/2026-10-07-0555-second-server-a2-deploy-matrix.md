# [2026-10-07 05:55] PR A-2: матрица выкатки из двух хостов, ключ хоста th2, выпуск маски th2 только по HTTP-01

Файл: `agent_docs/development-history/2026-10-07-0555-second-server-a2-deploy-matrix.md`

Исполняющий PR A-2 к ADR
[2026-10-05-2223](../adr/2026-10-05-2223-second-server-triplify-failover.md),
«Решения», п. 2 и «Ручные шаги», п. 6 — с поправками ADR
[2026-10-06-1054](../adr/2026-10-06-1054-agent-runs-th2-bootstrap-once.md)
(пользователь выкатки `ops`, пара REALITY th2 уже существует).

## Что сделано

- `.github/workflows/deploy.yml` — `strategy.matrix.include` из двух строк:
  `{host: th1, environment: production}` и
  `{host: th2, environment: production-th2}`; `fail-fast: false`,
  `max-parallel: 1`, резерв th1 первым. `environment:
  ${{ matrix.environment }}`, `HOST: ${{ matrix.host }}`. Имя хоста стояло
  переменной с PR A-1, поэтому в теле job'а поменялась одна строка — путь к
  ключу хоста.
- Ключ хоста стал файлом СВОЕГО хоста: `deploy/host-key.pub` →
  `deploy/hosts/th1/host-key.pub`, добавлен
  `deploy/hosts/th2/host-key.pub`. Содержимое th2 — вывод `ssh-keyscan -t
  ed25519 160.236.128.28`, отпечаток `SHA256:ebDvBDpkvV0LK3sjhbeVRMZgqkH0NFYRQ1SHCfY92cY`
  сверен владельцем на самой машине и с Mac (ADR `2026-10-05-2223`, «Ручные
  шаги», п. 3). В файле только ключ: имя сервера — секрет `SSH_HOST`, и
  строку `known_hosts` выкатка собирает из него.
- Шаг «Секреты выкатки заведены» печатает имя environment и хост, то есть
  при двух job'ах видно, который из них жалуется и где владельцу заводить
  секреты. Пустой environment краснит job первым шагом — молчаливого
  пропуска нет ни в одном исходе.
- Маска th2 выпускает сертификат **только по HTTP-01**: в Caddyfile добавлен
  `tls { issuer acme { disable_tlsalpn_challenge } }`. Причина — на этой
  машине Caddy на 443 не слушает вовсе (443 держит Xray), а TLS-ALPN-01
  приходит именно на 443 имени. Адаптер Caddyfile сам этот тип не выключает
  ни на каком порту сайта (`caddy v2.11.0`,
  `caddyconfig/httpcaddyfile/tlsapp.go`, `fillInGlobalACMEDefaults` — там
  трогается только `alternate_port`), то есть без строки certmagic пробовал
  бы его первым и жёг отдельный лимит отказов авторизации Let's Encrypt.
- Новая проверка 6 в `.github/scripts/mask-listener-guard.sh`: у КАЖДОГО
  ACME-issuer'а в выводе `caddy adapt`
  `challenges["tls-alpn"].disabled == true`; отсутствие явного issuer'а —
  такая же находка (тогда действуют умолчания). Приманки —
  четыре новых случая в `test/mask-listener-guard.test.sh` (было 16
  проверок, стало 20).
- `README.md` и `AGENTS.md` больше не говорят, что th2 в выкатку не включён:
  выкатка идёт на оба хоста, у каждого свой environment, свой ключ хоста и
  свой `secrets.env`.

## Чего в этом PR НЕТ намеренно

- **Секретов и обращений к серверам.** Ни `gh secret`, ни `gh api …
  environments` на запись, ни ssh. Environment `production-th2` и секреты
  VPN th2 заводит владелец — это границы 2 и 3 `AGENTS.md` и «Ручные шаги»
  ADR, п. 4 и 5.
- **Держателя формы матрицы.** Порядок строк, `max-parallel: 1` и
  `fail-fast: false` не держит ничто, кроме `actionlint` (он проверяет
  синтаксис, а не замысел) и ревью. Находка в бэклоге.
- **Правок наложений и держателей по хостам.** Они приехали PR A-1 и
  продолжают проверять оба наложения без изменений.

## Проверки

Прогнано локально: `actionlint` (чисто), `shellcheck $(git ls-files '*.sh')`
(чисто), все девять `test/*.test.sh` зелёные,
`bash .github/scripts/secrets-guard.sh .` чист.

Красная ветвь нового держателя — мутация строки 123
`mask-listener-guard.sh` (`select((.challenges["tls-alpn"].disabled? //
false) != true)` → `select(false)`, адресовано позицией): приманки упали,
«пройдено 17, провалено 3». Строка исполняемая: без мутации те же три
случая проходят.

`caddy adapt` и `xray run -test` локально не прогонялись — нет Docker на
машине агента; их гоняет CI тем же образом по тому же digest'у.

## Чего это не доказывает

- Что th2 выкатится. На момент PR в репозитории нет ни одного прогона
  выкатки на th2: environment `production-th2` пуст, и первый зелёный job
  возможен только после шагов владельца.
- Что сертификат `cdn2.zpq.ai` выпустится по HTTP-01. Держатель проверяет
  **конфигурацию**, а не выпуск; выпуск различит первый прогон выкатки
  (шаг «Снаружи отвечает маска на опубликованном адресе» без `-k` —
  200 только с настоящим сертификатом).
- Что REALITY проходит рукопожатие и что устройство подключается. Это живая
  проверка с Mac и iPhone (ADR `2026-10-05-2223`, «Ручные шаги», п. 7).

## Откат

Убрать строку th2 из `matrix.include` отдельным PR либо
`workflow_dispatch` прежним sha. th1 ни один из них не трогает: job'ы
независимы (`fail-fast: false`), и красный th2 его не отменяет.

## Связанные записи

- ADR [2026-10-05-2223](../adr/2026-10-05-2223-second-server-triplify-failover.md)
  — второй сервер целиком.
- ADR [2026-10-06-1054](../adr/2026-10-06-1054-agent-runs-th2-bootstrap-once.md)
  — поправки: `ops`, пара REALITY th2.
- Запись [2026-10-06-1054](2026-10-06-1054-second-server-a1-overlays-and-mask.md)
  — PR A-1, наложения и маска.
- Запись [2026-10-07-0516](2026-10-07-0516-bootstrap-th2-first-run-fixes.md)
  — первый живой прогон `bootstrap.sh` на th2.
