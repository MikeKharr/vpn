# [2026-10-07 11:52] «TH mobile» реализован: fallback на обоих TCP-входах, второй профиль из той же сборки, эксперимент снят

Файл: `agent_docs/development-history/2026-10-07-1152-th-mobile-fallback-443-implemented.md`

Исполнение принятого ADR
[2026-10-07-1123](../adr/2026-10-07-1123-th-mobile-profile-xhttp-fallback-443.md)
целиком, одним PR класса A. Повод и замер — запись
[2026-10-07-1124](2026-10-07-1124-xhttp-experiment-result-mobile.md); эксперимент
шага 2 ADR `0920` (PR #28, запись
[2026-10-07-1017](2026-10-07-1017-xhttp-experiment-th1.md)) этим PR **снят**.

## Что сделано

1. **`deploy/config.template.json` — три inbound, одна форма входа наружу.**
   `vless-443` вернулся к `tcp` + REALITY + Vision с
   `tcpSettings.acceptProxyProtocol: true`; `vless-8443` не изменился ни в одном
   своём свойстве; у обоих появился один `fallbacks` —
   `[{"dest": "127.0.0.1:8445"}]`, без `name`, `alpn`, `path` и **без `xver`**.
   Третий inbound `vless-xhttp` — `listen: "127.0.0.1"`, порт 8445,
   `network: "xhttp"`, `security: "none"`, те же два клиента без `flow`,
   `xhttpSettings` ровно те, что были у эксперимента.
2. **`bin/make-happ-json.sh` собирает два файла из одного ввода.**
   `happ-failover.json` — байт в байт прежний (сверено `cmp` с выходом версии из
   `origin/main` на тех же фиктивных значениях, sha256
   `8ddc994b…f76e4e` у обоих); `happ-mobile.json`, `remarks: "TH mobile"` —
   `th2-xhttp` на `160.236.128.28:443` и `th1-xhttp` на `45.91.134.23:443`,
   `network: xhttp`, `security: reality`, без `flow`, `mode: stream-up`,
   `xmux` не задан; балансировщик, `observatory`, `dns`, `inbounds` и правила —
   те же. Общая часть двух профилей собирается одной функцией `cfg_for`, а не
   двумя копиями. Контракт stdout: две строки, failover первой.
3. **Эксперимент снят.** `bin/make-happ-xhttp-test.sh`,
   `test/make-happ-xhttp-test.test.sh` и шаг `ci.yml` «Тестовый профиль XHTTP
   собирается…» удалены; держатели переехали в `test/make-happ-json.test.sh`.
   Предупреждения «пока стоит эксперимент» сняты из `bin/make-link.sh` (шапка и
   `fallback_why`) и из README, «Откат»: запасные ссылки th1 и откат A-записью
   без PR снова работают.
4. **Держатели.** `test/render.test.sh`: три inbound `[443, 8443, 8445]`, оба
   TCP-входа проверяются именным циклом (`network == tcp`,
   **`security == reality`**, `acceptProxyProtocol` `true`/`false`, Vision у всех
   клиентов, `fallbacks` полным равенством, отсутствие `xver`, отсутствие
   `sockopt` и `xhttpSettings`); у `vless-xhttp` — `listen` строго `127.0.0.1`,
   `security: none`, нет `realitySettings`/`sockopt`/`tcpSettings`/`fallbacks`,
   нет `flow`, `mode: auto`, `xPaddingBytes: 100-3000`, `path` с `/`.
   `test/make-happ-json.test.sh`: полное равенство **каждого** из двух профилей,
   `path`/`xPaddingBytes` «TH mobile» берутся из inbound `vless-xhttp` шаблона,
   под `HOME` четыре файла, права и права-при-рождении у обоих, `xray run -test`
   на обоих, положительный контроль сверки на каждый профиль.
   Прогон: 16 проверок в `render.test.sh`, 44 в `make-happ-json.test.sh`.
5. **Находка compliance к PR #28 закрыта:** `security == "reality"` у TCP-входов
   теперь держит прогон. До этого `security: "none"` на входе наружу отдавал бы
   VLESS открытым текстом, а `xray run -test` такой конфиг принимает молча.

## Что проверено живьём, и чем это закрывает «неподтверждённое» ADR

Бинарь Xray `26.9.30` для darwin/arm64 скачан с релиза и сверен с его же
`.dgst`: sha256 `4b363bd924df5bf09f87bd445755ff8e5742b9a8a0480cda261061416c3c7dce`,
файл `.dgst` побайтово совпал со скачанным из релиза. То есть прогон шёл **той
же версией ядра, что стоит на сервере** (образ в `deploy/compose.yml`), а не
26.3.27, как петля при подготовке ADR.

- **Этап 1, вход без PROXY protocol.** Один TCP-вход с REALITY + Vision и
  `fallbacks` на XHTTP-inbound `security: none` на петле. Vision-клиент: 1 МБ —
  `1000000 байт, код 200`. XHTTP-клиент **через тот же вход**: `1000000 байт,
  код 200`. Журнал сервера: `fallback starts > invalid request version`,
  `realName = www.cloudflare.com`, `realAlpn = ` (пусто), ни одного `Warning`
  кроме старта и штатного про не-443. Клиент: «XHTTP is dialing … mode
  stream-up, HTTP version 2».
- **Этап 2, вход С PROXY protocol v2.** Тот же стенд с
  `tcpSettings.acceptProxyProtocol: true`, перед ним — подставной `sni`:
  30-строчный TCP-ретранслятор, который дописывает заголовок PROXY v2 первым
  делом. Vision: `1000000 байт, 200`; XHTTP: `1000000 байт, 200`. Журнал:
  `accepting PROXY protocol` на старте и тот же `fallback starts`. **Это
  закрывает второй пункт «неподтверждённого» ADR** — fallback на входе с PROXY
  protocol живьём.
- **Контроль, различающий гипотезы.** Тот же стенд, единственное отличие —
  `"xver": 2` у fallback. XHTTP-клиент: `0 байт, код 000`, журнал сервера —
  `fallback ends > failed to fallback request payload > broken pipe`. То есть
  отсутствие `xver` **несущее**, а не косметика: ядро дописало бы заголовок
  PROXY в соединение к `dest` (`inbound.go:437-489`), а `vless-xhttp` его не
  ждёт. Без этого контроля «xver не нужен» было бы утверждением, которое нечем
  отличить от «xver безразличен».
- `xray run -test` образом 26.9.30 на отрендеренном шаблоне с **обоими**
  наложениями (`MASK_NAME`/`XRAY_TARGET` th1 и th2) — «Configuration OK» на
  обоих; на `happ-mobile.json` — «Configuration OK».
- Сверено по исходнику тега `v26.9.30` (скачан архивом, sha256
  `85162fa61eb6d1adc9199afff7b41299e69dedd094907e9c56ef665c236b3ef0`), все
  ссылки ADR подтверждены на месте: `proxy/vless/inbound/inbound.go:308` («fallback
  directly», порог `firstLen < 18`), `:318`, `:328` (ветвь `*reality.Conn`),
  `:383` («not h2c»), `:437` (`fb.Xver != 0`), `:492`;
  `proxy/vless/encoding/encoding.go:130`; `infra/conf/vless.go:158`, `:199`,
  `:210`; `transport/internet/splithttp/hub.go:104`, `:535`, `:559`, `:563`;
  `splithttp/dialer.go:82-84` (при REALITY версия HTTP — «2», безусловно);
  `transport/internet/system_listener.go:169-171`;
  `transport/internet/tcp/hub.go:40` (при `network: tcp` флаг из `tcpSettings`
  переносится в `SocketSettings` — почему PROXY protocol вернулся в
  `tcpSettings`, а не остался в `sockopt`).

## Чего этот PR не проверяет и проверить не может

- **Проходит ли XHTTP на `160.236.128.28:443` и `45.91.134.23:443` с мобильной
  сети.** Эксперимент ходил через `45.91.134.19` и единицу `sni`. На проводе
  транспорт тот же, но живьём эти два адреса с XHTTP с мобильной не ходили —
  это шаги 4–5 «Ручных шагов» ADR, руки владельца.
- **Рукопожатие REALITY и работу Happ.** `xray run -test` не поднимает
  слушателей; версия ядра Happ Desktop нигде не названа.
- **Поведение зондов observatory поверх XHTTP** — только живым использованием.
- Петля шла на `127.0.0.1` с мишенью `www.cloudflare.com`; настоящий `target`
  (`zpq:8444` / `mask:8444`) и настоящая маска в прогоне не участвовали.

## Мутации

17 мутаций, каждая адресована образцом содержимого (не номером строки), с
md5-контролем «правка не no-op» и проверкой, что тронута исполняемая строка, а
не комментарий. Все 17 красные; дерево после прогона совпало с исходным по md5.
Полный вывод — в описании PR, раздел «Красная ветвь».

## Уроки

- **Шим в проверке умел видеть права только последнего аргумента `chmod`.**
  `chmod 600 "$OUT" "$OUT_MOBILE"` — одна команда на два файла, и держатель
  «родился 0600» у первого из них молча исчез бы. Нашлось не разбором, а
  красным прогоном: мутация тут не понадобилась, покраснело сразу. Урок общий:
  шим, который разбирает аргументы «последний — это файл», перестаёт работать
  в тот день, когда файлов становится два.
- **Контроль с `xver: 2` стоил пяти минут и превратил «по исходнику не нужен» в
  наблюдение.** Пункт «нужен ли `xver`» в задаче был поставлен как вопрос, и
  честный ответ на него требовал прогона, при котором ответ был бы другим.
- Обратные кавычки в комментариях внутри `python3 -c '…'` краснят `shellcheck`
  как SC2016: в одинарных кавычках они для него подстановка команды. В
  комментариях этого блока их теперь нет.
