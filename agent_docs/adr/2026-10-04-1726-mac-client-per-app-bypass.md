# [2026-10-04 17:26] Клиент на Mac: Clash Verge Rev ради обхода VPN одним приложением (Яндекс Браузер)

Файл: `agent_docs/adr/2026-10-04-1726-mac-client-per-app-bypass.md`

## Статус

**Принято владельцем 2026-10-05** (предложено 2026-10-04; ответы на
развилки — «Решения владельцу»). Дополняет ADR
[2026-10-03-0353](2026-10-03-0353-vless-reality-personal-vpn.md), п. 4 —
только клиент на **Mac**. iPhone остаётся на Happ. Сервер, ядро, ключи,
UUID и shortId не меняются: пара значений Mac переезжает из Happ в новый
клиент. На момент принятия ничего не установлено и не запускалось — все
утверждения ниже помечены как проверенные по исходнику,
документированные или непроверенные (раздел «Проверено лично»).
Исполняющие PR: `bin/make-clash.sh` (раздел «Как секреты попадают в
YAML») и ссылка в README — отдельно, классы A и C.

## Решение

**На Mac — Clash Verge Rev (GPL-3.0, ядро mihomo), режим TUN через
службу, правило по пути процесса на бандл `/Applications/Yandex.app/`.**
Яндекс Браузер со всеми helper-процессами идёт мимо туннеля, остальное —
через VPN, включая UDP; DNS системы перехватывается ядром и уходит
через туннель, как сегодня.

### Профиль mihomo (локальный файл в Verge; плейсхолдеры — три значения
Mac из менеджера паролей)

```yaml
mode: rule
find-process-mode: strict

proxies:
  - name: vpn
    type: vless
    server: cdn.zpq.ai
    port: 443
    uuid: <UUID_MAC>
    flow: xtls-rprx-vision
    udp: true
    packet-encoding: xudp
    tls: true
    servername: cdn.zpq.ai
    client-fingerprint: chrome
    reality-opts:
      public-key: <ПУБЛИЧНЫЙ_КЛЮЧ_REALITY>
      short-id: <SHORT_ID_MAC>
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
  - PROCESS-PATH-REGEX,^/Applications/Yandex\.app/,DIRECT
  - DOMAIN-SUFFIX,zpq.ai,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - IP-CIDR6,fe80::/10,DIRECT,no-resolve
  - MATCH,PROXY
```

Что здесь несущее и почему:

- `PROCESS-PATH-REGEX` по бандлу, а не `PROCESS-NAME`: сетевой трафик
  Chromium идёт из helper-процессов. В бандле на этом Mac (листинг
  2026-10-04, версия 26.8.3.1016) четыре исполняемых helper'а — `Yandex
  Helper`, `Yandex Helper (GPU)`, `Yandex Helper (Renderer)`, `Yandex
  Helper (Alerts)` — все под
  `/Applications/Yandex.app/Contents/Frameworks/…/Helpers/`. Одно
  правило по пути накрывает их и главный процесс; имена с пробелами и
  скобками не участвуют. В mihomo регулярное выражение применяется к
  полному пути процесса без учёта регистра (`rules/common/process.go`,
  v1.19.32).
- `support-x25519mlkem768: true` обязателен: без него mihomo **вырезает**
  ML-KEM из ClientHello (`component/tls/reality.go`, v1.19.32,
  `BuildRemovedX25519MLKEM768HandshakeState`), а Xray ≥ 26.9.8 такой
  ClientHello отвергает (ADR `2026-10-03-0353`, п. 2). Умолчание — `false`.
- `client-fingerprint: chrome`: в `metacubex/utls` v1.8.8 (пин mihomo
  v1.19.32) `HelloChrome_Auto = HelloChrome_133`, и только Chrome-профили
  несут `X25519MLKEM768` первым key share перед `X25519` — ровно порядок,
  которого требует сервер. `HelloFirefox_Auto = HelloFirefox_120` и
  `HelloSafari_Auto = HelloSafari_16_0` ML-KEM не несут.
- `enhanced-mode: redir-host`, не fake-ip: Fake DNS в Happ ломал
  разрешение имён (запись [2026-10-04-0710](../development-history/2026-10-04-0710-dns-leak-mac.md));
  в Verge при `redir-host` код не трогает `dns` профиля и **не меняет
  системный DNS Mac** (`src-tauri/src/enhance/tun.rs`: ветка подмены
  DNS выполняется только для fake-ip), то есть сегодняшний `1.1.1.1` в
  Wi-Fi остаётся; открытая регрессия fake-ip на macOS (#8141) не
  затрагивает.
- `nameserver … #PROXY`: по умолчанию mihomo шлёт DNS-запросы напрямую —
  это и была бы утечка имён оператору. Суффикс `#<группа>` отправляет их
  через туннель (документация DNS). `proxy-server-nameserver` при этом
  обязателен — иначе имя самого сервера не разрешить (документация:
  «鸡蛋问题»).
- Перехват DNS: в настройках TUN Verge поле DNS Hijack должно содержать
  `any:53` — тогда любой резолвер системы попадает в ядро и уходит через
  `nameserver`. Запросы к адресам локальной сети на macOS не
  перехватываются (документация TUN mihomo), поэтому Wi-Fi DNS Mac
  остаётся публичным `1.1.1.1`, как сегодня.
- `find-process-mode: strict` (умолчание): поиск процесса делается лениво
  при первом правиле `PROCESS-*` (`tunnel/tunnel.go`, `rules/common/process.go`).
  На macOS процесс находится по `net.inet.{tcp,udp}.pcblist_n` и
  `proc_pidpath` (`component/process/process_darwin.go`) — TCP и UDP,
  то есть и QUIC браузера.

### Как секреты попадают в YAML

Та же дисциплина, что у `bin/make-link.sh` (ADR `2026-10-03-0353`, п. 5):
три значения Mac — UUID, публичный ключ REALITY, shortId — не попадают ни
в репозиторий, ни в команду, ни в список процессов, ни в вывод
терминала. Планируемый помощник — **`bin/make-clash.sh`**, отдельным PR
(путь `bin/` — не защищённый, но скрипт работает с секретами, поэтому
класс A с гейтом `compliance`):

- Запуск владельцем на Mac: `bash bin/make-clash.sh`. Значения вводятся
  скрытым `read -rs` с проверкой формы (UUID, 43 знака base64url, 8 hex)
  — как `ask` в `make-link.sh`.
- YAML собирается из шаблона выше **встроенным `printf` в файл**: ни
  одно значение не уходит аргументом внешнему процессу (`sed`, `yq`,
  `qrencode`) — аргументы видны в `ps` процессам того же пользователя.
  В stdout печатается только путь к файлу.
- Файл: `~/Library/Application Support/vpn/clash-mac.yaml`, каталог
  `0700`, файл `0600` (`umask 077`), вне репозитория — `.gitignore`
  здесь не участвует и не нужен. Verge импортирует его как локальный
  профиль («New profile → local → выбрать файл») и хранит **свою копию**
  в каталоге приложения — она живёт по правам клиента, как ссылка у
  Happ; после импорта исходник можно удалить (`rm -P`).
- Шаблон без значений — часть скрипта, то есть в репозитории он
  публичен, как `deploy/config.template.json`; сторож секретов
  проверяет его наравне со всем остальным (`AGENTS.md`, граница 1).
- Чего скрипт не делает: не ходит на сервер, не читает буфер обмена, не
  запускает Verge, не трогает приватный ключ REALITY.

До появления скрипта YAML можно собрать руками в редакторе — но не в
терминале через `echo`/`cat <<EOF` с подстановкой: это и есть путь
значений в историю shell.

### Настройки Verge (вне профиля)

1. Установка: `brew install --cask clash-verge-rev` (cask 2.5.7, ставит
   `Clash Verge.app`) или DMG `aarch64` из релиза v2.5.7. macOS ≥ 12.
2. Settings → Service Mode → установить (пароль администратора один раз;
   служба `clash-verge-service` запускает ядро с правами root — так TUN
   поднимается без пароля при каждом включении).
3. Settings → Tun Mode: включить; в настройках TUN — DNS Hijack `any:53`,
   stack оставить умолчание Verge (gVisor). Профиль выше — локальный
   («New profile» → local), DNS Overwrite для этого профиля **выключить**
   (переключатель хранится на профиль).
4. Файрвол macOS: разрешить `verge-mihomo`, если спросит.
5. Happ на Mac — отключить, но не удалять (откат). Два TUN одновременно
   не запускать.

### Проверка на Mac (ожидаемые результаты)

```zsh
open -a Yandex https://api.ipify.org     # адрес оператора, НЕ 45.91.134.19
open -a Safari https://api.ipify.org     # 45.91.134.19
curl -s https://api.ipify.org; echo      # 45.91.134.19
curl -s -o /dev/null -w '%{http_code}\n' https://zpq.ai   # 200, в Connections — DIRECT
sntp time.cloudflare.com                 # ответ есть (UDP 123 через туннель)
dig TXT o-o.myaddr.l.google.com @1.1.1.1 +short   # адрес сети Cloudflare, не оператора
```

В Verge → Connections: соединения с процессом `Yandex Helper*` — правило
`PROCESS-PATH-REGEX`, цепочка `DIRECT`; `curl`, Safari —
`MATCH → PROXY → vpn`; `time.cloudflare.com:123` UDP — `PROXY`.
Проверка `dig @1.1.1.1 whoami.cloudflare TXT CH +notcp` из записи
[2026-10-04-0513](../development-history/2026-10-04-0513-udp-xray-tun.md)
при перехвате `any:53` отвечает ядро mihomo; пройдёт ли через него класс
CH — не проверено: пустой ответ здесь — не признак утечки, признак
утечки — адрес оператора в ответе Google.

### Откат к Happ

Verge: Tun Mode выключить → Settings → Uninstall Service → выйти.
`brew uninstall --cask clash-verge-rev` (при желании `--zap`). Открыть
Happ, подключиться, прогнать проверки из записей
[2026-10-04-0513](../development-history/2026-10-04-0513-udp-xray-tun.md)
и [2026-10-04-0710](../development-history/2026-10-04-0710-dns-leak-mac.md).
Сервер и iPhone откат не затрагивает.

## Контекст

Потребность владельца 2026-10-04: на Mac одно приложение — Яндекс
Браузер — должно ходить мимо VPN целиком, остальное — через VPN с UDP и
DNS как сегодня. Happ из Mac App Store этого не умеет: режима прокси нет,
а правила в его интерфейсе — домены и IP. Задача свелась к выбору
клиента на Mac с правилами по процессу, который при этом проходит
рукопожатие с Xray 26.9.30 (`chrome` + `X25519MLKEM768`, ADR
`2026-10-03-0353`, п. 3).

## Обоснование

Clash Verge Rev — единственный из рассмотренных, у кого одновременно:
(1) правила по процессу на macOS, работающие в TUN, потому что ядро
стоит службой root, а не в песочнице NetworkExtension; (2) REALITY-клиент
с явным переключателем ML-KEM и Chrome-отпечатком нужного порядка;
(3) живой проект (релиз 2026-10-02, 149 тыс. звёзд, cask в Homebrew,
подпись и нотаризация Apple в `release.yml`). Все клиенты на
NetworkExtension — Happ, OneXray, SFM из App Store, Stash iOS —
документированно или по сути песочницы не видят чужих процессов; все
клиенты на sing-box не проходят рукопожатие (#4520 открыт).

## Проверено лично (2026-10-04)

- **Бандл Яндекс Браузера** на этом Mac: `ls`/`find` по
  `/Applications/Yandex.app` — главный исполняемый файл `Yandex`,
  четыре helper-приложения, пути выше; `CFBundleIdentifier`
  `ru.yandex.desktop.yandex-browser`, версия 26.8.3.1016.
- **Xray-core, исходник:** `common/net/find_process_darwin.go`
  (`//go:build darwin && !ios`, `kern.proc.all`), `find_process_ios.go`
  (заглушка). Коммиты: `987290ba` 2026-07-08 «`process` supports macOS as
  well» (#6447), `5b1b4105` 2026-07-26 «Exclude iOS» (#6524), `8b419d83`
  2026-08-12 (#6557). **Документация Xray (EN и ZH) устарела:** «仅支持
  Windows 和 Linux» — в ядре с v26.7.11 поле работает и на macOS. Что это
  даёт и чего не даёт — «Альтернативы», первый пункт.
- **mihomo v1.19.32** (релиз 2026-09-30): `go.mod` — `metacubex/utls
  v1.8.8`, `metacubex/sing-tun v0.4.27`; `adapter/outbound/reality.go` —
  поле `support-x25519mlkem768`; `component/tls/reality.go` — удаление
  ML-KEM при `false`, `utls.UClient(conn, uConfig, fingerprint)`;
  `tunnel/tunnel.go` — режимы `always/strict/off`, в `strict` поиск
  отложен до правила; `rules/common/process.go` — `regexp2` с
  `IgnoreCase` по `metadata.ProcessPath`; `component/process/process_darwin.go`
  — `pcblist_n` для TCP и UDP, `proc_pidpath`.
- **metacubex/utls v1.8.8**: `u_common.go` — `HelloChrome_Auto =
  HelloChrome_133`, `HelloFirefox_Auto = HelloFirefox_120`,
  `HelloSafari_Auto = HelloSafari_16_0`; `u_parrots.go` — `X25519MLKEM768`
  только в `HelloChrome_131`, `HelloChrome_133` и `HelloChrome_115_PQ_PSK`;
  в `HelloChrome_133` порядок `SupportedCurves` и `KeyShare`: GREASE,
  `X25519MLKEM768`, `X25519`.
- **Позиция mihomo** (Issue #3193, закрыт 2026-09-10, мейнтейнер
  wwqgtxx): «we will not consider compatibility with xray versions
  v26.7.11 and later», то же в документации `reality-opts`; обновление
  utls — только по релизам upstream.
- **Clash Verge Rev**: GPL-3.0, 149 145 звёзд, v2.5.7 2026-10-02,
  cask `clash-verge-rev` 2.5.7 (`brew info`, не установлен);
  `.github/workflows/release.yml` — `APPLE_CERTIFICATE`,
  `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID`;
  `scripts/prebuild.mjs` берёт последний релиз mihomo на момент сборки
  (в 2.5.6 — v1.19.31 по #8141); `src-tauri/src/enhance/tun.rs` — логика
  fake-ip/системного DNS выше (в коде `114.114.114.114`, в FAQ —
  `223.6.6.6`: документация отстаёт от кода); строки интерфейса
  `src/locales/en/settings.json` — «Tun Mode», «Tun Stack», «DNS
  Overwrite» («saved separately for each profile»), «Uninstall Service».
  Открытые macOS-регрессии: #7963 (сон/пробуждение с TUN теряет маршрут
  и DNS, 2.5.2), #7821 (переключатель TUN включён, а `tun.enable` false,
  2.5.2, macOS 26.6.1), #8141 (fake-ip после выключения TUN, 2.5.6),
  #8001 (несколько интерфейсов), #8029/#8069 (служба после 2.5.5),
  #7825 (Windows: `PROCESS-NAME` с пробелом не матчится, `ProcessPath`
  работает — ещё довод за путь).
- **sing-box**: документация Apple — `process_name`/`process_path`
  «Only supported in the macOS standalone and iOS jailbreak versions»;
  `route/platform_searcher.go` — на платформах с NetworkExtension поиск
  делегируется платформе; #4520 открыт, в changelog до 1.15.0-alpha.10
  (2026-10-03) правки ML-KEM нет; `go.mod` 1.14.2 — utls v1.8.7.
- **Stash**: wiki — правила процессов «не поддерживаются на iOS/tvOS из-за
  Network Extension», на macOS есть; REALITY с macOS 4.3+. В тайском Mac
  App Store по запросу «Stash» клиента нет (iTunes Search API,
  `country=th`, 2026-10-04).
- **Surge**: VLESS не поддерживает (мосты `surge-vless-bridge`,
  `fuck-surge` через sing-box/SOCKS5).
- **Happ** (`happ.su`, dev-docs): JSON-конфиг «passed exactly as is» в
  ядро, при этом правила и настройки интерфейса Happ не применяются;
  в TH Mac App Store v5.9.0 (2026-09-22). **OneXray** (документация
  custom routing): «Do not write … process conditions».

Неподтверждённым остаётся всё, что собрано по документации поставщика:

- что сборка Verge 2.5.7 действительно подписана и нотаризована
  (секреты в workflow есть; DMG не скачивался);
- что рукопожатие mihomo `chrome` + `support-x25519mlkem768: true` с Xray
  26.9.30 проходит — по обсуждению #3193 и отчётам в чужих трекерах
  (Karing #1952, sing-box-lx #22); живого подключения не было;
- что `#PROXY` в `nameserver` принимает именно группу, а не только
  встроенные имена; что `any:53` стоит в настройках TUN Verge по
  умолчанию;
- что при `redir-host` правило `DOMAIN-SUFFIX,zpq.ai` матчится без
  включённого `sniffer` (ядро хранит соответствие IP → имя из своих
  ответов DNS — по документации режима);
- что `proc_pidpath` из службы root видит helper'ы Яндекса (ожидаемо:
  root), и что `open -a Yandex` открывает ссылку в уже запущенном
  браузере;
- какой helper несёт сетевой сервис Chromium — правило по пути делает
  это неважным.

## Последствия

Положительные:

- Яндекс мимо VPN, остальное — как сегодня: UDP через XUDP, DNS через
  туннель, `zpq.ai` и приватные сети напрямую. Сервер не трогается,
  ключи не меняются, iPhone не замечает.
- Открытый клиент с воспроизводимой сборкой вместо закрытого; профиль —
  текстовый файл, который можно сверить глазами.

Отрицательные — и честные:

- **Два ядра на двух устройствах.** Mac — mihomo, iPhone — Xray (Happ).
  Любая смена версии Xray на сервере теперь проверяется двумя клиентами,
  и у mihomo объявленная позиция — совместимость с Xray ≥ 26.7.11 не
  обещана. Следующий сдвиг REALITY на сервере может оставить Mac без VPN
  без исправления со стороны mihomo; защита одна — не поднимать дайджест
  образа Xray, не проверив Mac.
- **Отпечаток намертво `chrome`** на Mac (в утилите mihomo ML-KEM есть
  только у Chrome-профилей) — тот самый, что режут на части мобильных
  сетей (ADR `2026-10-03-0353`, п. 3).
- **Служба root и TUN вне App Store.** Ядро работает с правами root и
  переписывает маршруты и DNS; открытые регрессии macOS (#7963 сон,
  #7821 ложный переключатель) — реальные, не теоретические. Чинится
  перезапуском службы; при #7821 признак — `curl` показывает адрес
  оператора.
- **Имена, которые ищет Яндекс, уходят через туннель** (резолвер —
  `mDNSResponder`, не процесс браузера), а адреса — напрямую. Это не «как
  без VPN»: сервер и Cloudflare видят имена сайтов браузера; оператор —
  только адреса. Полный обход требует `direct-nameserver` (решение 2).
- **Процесс ищется по source-порту** в таблицах ядра; гонка между SYN и
  закрытием сокета даёт редкие промахи — тогда соединение Яндекса уйдёт
  в `MATCH → PROXY`, а не упадёт.
- **Второй сборщик секретов.** `bin/make-link.sh` этот формат не
  собирает; появляется `bin/make-clash.sh` с той же дисциплиной — ещё один
  файл, который держит границу «секреты не в репозитории» руками автора и
  ревью, а не CI.
- **Больше поверхность:** GUI на Tauri, автообновление, служба,
  обновляемое ядро — всё это новые движущиеся части на машине владельца.

## Решения владельцу

Решено владельцем 2026-10-05; варианты оставлены, чтобы было видно, между
чем выбирали.

1. **Клиент на Mac — (а) Clash Verge Rev.** Отклонены: (б) проба Happ с
   JSON-конфигом и правилом `process` («Альтернативы», п. 1) — исход
   непредсказуем из-за песочницы NetworkExtension; (в) оставить Happ и
   менять привычку (второй браузер через VPN).
2. **DNS для прямых соединений Яндекса — (а) как в профиле:** имена через
   туннель, адреса напрямую. Отклонено: (б) `direct-nameserver:
   [77.88.8.8]`/`[system]` — имена всех прямых соединений, включая
   `zpq.ai`, уходили бы оператору.
3. **Версия ядра на Mac — (а) обновления Verge принимаются как есть,
   автообновление включено.** Отклонено: (б) ручной подъём версий после
   проверки. **Принятый этим риск, названный прямо:** обновление Verge
   (а с ним ядра mihomo) или подъём дайджеста Xray на сервере может
   **молча** сломать Mac — mihomo совместимость с Xray ≥ 26.7.11 не
   обещает (#3193), а признаков в интерфейсе может не быть (ср. #7821).
   Обнаружение — только команды из «Проверка на Mac»: `curl -s
   https://api.ipify.org` с адресом оператора вместо `45.91.134.19` —
   признак поломки. Откат — «Откат к Happ»: Happ остаётся установленным и
   не удаляется именно ради этого. После каждого подъёма Xray в
   `deploy/compose.yml` проверка Mac — шаг владельца, CI её не заменит.
4. **README — (а) отдельным PR класса C после приёмки:** шаги 7–8 про Happ
   остаются для iPhone, для Mac добавляется ссылка на этот ADR.

## Альтернативы рассмотрены

- **Happ с полным JSON-конфигом Xray и правилом `process`.** В ядре
  поле на macOS есть с v26.7.11 (исходник, выше), Happ передаёт JSON в
  ядро как есть. Не выбрано основным: ядро Happ закрыто и его версия не
  названа; сборка из App Store — NetworkExtension в песочнице, где
  sing-box и Stash документированно не видят чужих процессов, а Xray
  читает `kern.proc.all` и файловые дескрипторы чужих процессов —
  вероятнее всего, песочница это запретит; при JSON-режиме весь роутинг
  (zpq, приватные сети, DNS) переезжает в JSON и интерфейс Happ не
  участвует. Оставлено как проба (решение 1б): исход виден за один
  запуск, и при успехе этот ADR отзывается.
- **sing-box standalone (cask `sfm` 1.14.2).** Правила процессов есть
  (standalone), но #4520 открыт: с Xray ≥ 26.9.8 не подключается.
- **SFM/SFI из App Store, Hiddify, Karing.** NetworkExtension без
  правил процессов и/или sing-box с той же поломкой.
- **OneXray.** Документация запрещает `process` в custom routing;
  NetworkExtension.
- **Stash (macOS).** Правила процессов на macOS есть, REALITY есть, но
  закрытый код, цена, в TH Mac App Store не найден, ML-KEM не заявлен.
- **Surge.** VLESS нет.
- **FlClash, Clash Party (бывш. Mihomo Party), Sparkle, ClashX Meta.**
  То же ядро mihomo, та же конфигурация; не выбраны из-за меньшей
  зрелости службы TUN на macOS или лицензии (ClashX Meta — AGPL);
  запасной путь, если Verge разочарует: профиль переносится без правок.
- **mihomo или Xray из Homebrew без GUI.** Xray без TUN-inbound требует
  tun2socks; mihomo CLI — тот же результат, что Verge, без интерфейса для
  включения/выключения и просмотра соединений.
- **Режим системного прокси вместо TUN** (Яндекс с `--no-proxy-server`).
  UDP через системный прокси не ходит (документация Verge) — нарушает
  требование.
- **Второй пользователь macOS для Яндекса / маршруты по UID.** Правил по
  UID на macOS ни у mihomo, ни у sing-box нет (`user` — только Linux).

## Связанные записи

- `agent_docs/adr/2026-10-03-0353-vless-reality-personal-vpn.md`, п. 2–4.
- `agent_docs/development-history/2026-10-04-0513-udp-xray-tun.md`,
  `2026-10-04-0646-zpq-direct-verified.md`, `2026-10-04-0710-dns-leak-mac.md`
  — проверки, которые повторяются после перехода.
- Источники: `https://xtls.github.io/en/config/routing.html`;
  `github.com/XTLS/Xray-core` — `common/net/find_process_darwin.go`,
  коммиты #6447, #6524, #6557; `https://wiki.metacubex.one/config/proxies/tls/`,
  `…/config/dns/`, `…/en/config/rules/`, `…/en/config/inbound/tun/`;
  `github.com/MetaCubeX/mihomo` v1.19.32 и Issue #3193;
  `github.com/MetaCubeX/utls` v1.8.8; `github.com/clash-verge-rev/clash-verge-rev`
  v2.5.7, `release.yml`, `src-tauri/src/enhance/tun.rs`, Issues #7963,
  #7821, #8141, #7825, #6495; `https://www.clashverge.dev/guide/term.html`,
  `…/faq/macos.html`; `https://sing-box.sagernet.org/clients/apple/features/`,
  `github.com/SagerNet/sing-box` #4520; `https://stash.wiki/en/rules/rule-types`;
  `https://www.happ.su/main/dev-docs/examples-of-links-and-parameters`;
  `https://onexray.com/docs/configuration/custom-routing/`.
