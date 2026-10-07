# [2026-10-07 08:37] Выкатка только из `main`; дополнение к ADR 2026-10-06-1054

Файл: `agent_docs/development-history/2026-10-07-0837-deploy-only-from-main-adr-addendum.md`

## Что сделано

- **Environment `production` и `production-th2`: выкатка только из ветки
  `main`.** Решение владельца 2026-10-07 по предложению `compliance` (ревью
  PR #23). До этого у обоих было `deployment_branch_policy: null`, то есть
  `workflow_dispatch` с любой ветки получил бы настоящие `SSH_KEY` и взял
  `deploy.yml` этой ветки мимо ревью. Выставлено настройкой GitHub
  (`custom_branch_policies: true`, политика `branch:main`), сверено чтением
  API: у обоих `branch:main`, секреты `SSH_HOST`, `SSH_KEY`, `SSH_USER` на
  месте. Откат `workflow_dispatch` прежним sha с `main` не затронут.
- **Дополнение к ADR 2026-10-06-1054** с действующей формой запуска
  `bootstrap.sh` (решение владельца: «Дополнение к ADR»). Пункт бэклога
  «блок команд запуска устарел» закрыт; README ссылается на дополнение.
- **`ignoreip` на th2 применён** владельцем через консоль провайдера:
  строка `ignoreip = 127.0.0.1/8 ::1 45.91.134.19` дописана в
  `/etc/fail2ban/jail.local`, `systemctl restart fail2ban`,
  `fail2ban-client get sshd ignoreip` → `127.0.0.0/8`, `::1`,
  `45.91.134.19`. Пункт «не применён» из записи 2026-10-07-0622 закрыт.

## Граница

Ветка `main` на стороне GitHub по-прежнему не защищена (запрет прямого
push держит только `AGENTS.md`), поэтому правило environment закрывает путь
«ручной запуск с чужой ветки», но не «push в `main` мимо PR».
