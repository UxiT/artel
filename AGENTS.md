# AGENTS.md

Этот файл — память проекта для кодовых агентов (Kimi Code, Claude Code и др.).
Держите его в синхроне с `CLAUDE.md`: правила сборки, архитектуры и ограничения
одинаковые, отличия отмечены ниже.

Artel — нативное macOS 15+ (arm64) SwiftUI-приложение для параллельной работы
с несколькими сессиями кодовых агентов (Claude Code, Kimi Code) и лёгкая доска задач:
задача — это промпт с вложениями, который бросают в сессию, по желанию — в отдельном
git worktree. Продукт-спека:
`docs/SPEC.md`; обзор и горячие клавиши: `README.md`. Строки UI, документация
и комментарии оператору — на русском.

## Build & test

Установлены только Command Line Tools — Xcode нет. Всё идёт через SwiftPM и скрипты:

```sh
scripts/build-app.sh             # release → build/Artel.app (собирает Artel, artel-hook, вкладывает tmux, ad-hoc подпись)
scripts/build-app.sh debug       # debug-сборка
scripts/build-app.sh --install   # + копия в /Applications (нужна, чтобы живые сессии подхватили новый artel-hook)
scripts/test.sh                  # юнит-тесты (swift-testing); оборачивает `swift test` с путями фреймворков CLT
scripts/test.sh --filter HistoryTests                 # один сьют / файл
scripts/test.sh --filter "TaskFileFormat/roundTrip"   # один тест
scripts/release.sh 0.2.0 [--notes notes.md] [--dry-run]   # релиз на GitHub + appcast Sparkle; разовая настройка — в шапке скрипта
```

Используйте `scripts/test.sh`, а не голый `swift test` — под CLT тот не находит
фреймворк Testing. Тесты покрывают только `ArtelCore`; у таргета приложения тестов нет.

Ограничения CLT, важные при добавлении кода и зависимостей:
- SwiftUI/Observation-макросы, требующие плагина Xcode, недоступны: ни `@Entry`,
  ни `#Preview`. Зависимости, которые их используют (например, Textual), не
  собираются — поэтому markdown-предпросмотр на MarkdownUI.
- Таргет `Artel` компилируется в Swift 5 language mode; `ArtelCore`/`ArtelHook` —
  в Swift 6. В Swift 5-режиме предпочитайте `NSRegularExpression`
  Swift-литералам `Regex` (lookbehind / голые литералы `/.../` не работают).

## Архитектура

Три SwiftPM-таргета:
- `ArtelCore` — вся тестируемая логика: модели (`Models.swift`, `TaskModel.swift`),
  управление tmux, команда запуска агента (`CodingAgent.swift`), журнал хук-событий
  и стейт-машина статусов сессий (`SessionActivity`/`SessionStatus.applying`),
  хранение задач, git worktree и diff, шаблоны промптов, discovery
  документов проекта, лимиты использования.
- `ArtelHook` (`artel-hook`) — обработчик хуков Claude Code и Kimi Code. Всегда завершается
  с кодом 0 и ничего не печатает; дописывает `events/<session>.jsonl` и стучит
  в приложение через unix-сокет.
- `Artel` — SwiftUI-приложение. `AppModel` (`@Observable`, разбит на
  `AppModel.swift`, `+Tasks`, `+NoTasks`, `+Workflow`) владеет всем состоянием; вьюхи в
  `Sources/Artel/Views`.

Поток сессии: приложение запускает агента внутри приватного tmux-сервера
(`tmux -L artel`) и показывает его через SwiftTerm: для Claude Code это
`claude --settings <hooks> --session-id <id>`, для Kimi Code — `kimi` с хуками из
управляемого блока `~/.kimi-code/config.toml`. Хуки → `artel-hook` → `events/*.jsonl` — источник истины о статусе
сессий (реплеится при запуске); сокет — только для живых обновлений. Сессии переживают
выход из приложения; пропавшая tmux-сессия поднимается командой resume агента
(`claude --resume` / `kimi --session <id>`). Агенты — через протокол `CodingAgent`
(`ClaudeCodeAgent`, `KimiCodeAgent`, реестр `CodingAgents`); модель по умолчанию хранится
на агента в `AppSettings.defaultModels`, агент по умолчанию — в `defaultAgentID`.

Задачи — файлы, а не состояние приложения: `<project>/.artel/tasks/<ID>-<slug>/`
держит `task.md` (frontmatter + тело = промпт), `history.jsonl` (append-only таймлайн),
`attachments/` и `logs/`. Статусы — `new` → `in-progress` (ставится при запуске) →
`done` (только оператор); цикла план/ревью/тестирование, замечаний и MCP-сервера нет —
промпт уходит первым сообщением, дальше всё в терминале. Старые task.md читаются:
`TaskStatus(stored:)` сводит прежние этапы к `in-progress`, `cancelled` — к `done`,
устаревшие ключи frontmatter убираются при перезаписи. Приложение перечитывает задачи
по fingerprint, внешние правки — штатные. Задача работает в рабочей копии проекта, если
в диалоге запуска не выбран worktree: тогда она получает `~/.artel/worktrees/<project>/<ID>`
на ветке `artel/<ID>-<slug>` (`.artel/` исключён через sparse-checkout) и сохраняет его для
следующих запусков. Artel ничего не мержит: при закрытии задачи можно удалить worktree и
уже слитую ветку. Агент получает доступ к папке задачи через `--add-dir`.
Проекту не обязательно быть git-репозиторием и иметь CLAUDE.md: `ProjectValidator` лишь
заставляет диалог добавления предложить `git init` и шаблон CLAUDE.md. Без git
(`Project.isGitRepository`, проверяется на лету) скрыты worktree, базовая ветка и коммит
`.artel/`, задачи работают в папке проекта.
Сессии без задачи архивируются в `<project>/.artel/no-task/<session-id>/`
(`NoTaskStore`): заголовок — по первому промпту, срок — 7 дней после обновления,
очистка при чтении/записи. Преобразование переносит архив в `tasks/` как закрытую
номерную задачу с историей и логами. `no-task/` и `tasks/*/logs/` не коммитятся.

Данные приложения: `~/Library/Application Support/Artel/` (`state.json`,
`events/`, сгенерированный `claude-settings.json`, `tmux.conf`, `bin/artel-hook`).

Самообновление — Sparkle (бинарный фреймворк из SwiftPM, `build-app.sh` кладёт его
в `Contents/Frameworks`). `SUFeedURL` — `appcast.xml` последнего GitHub-релиза
`UxiT/artel`. `scripts/release.sh` выставляет `CFBundleShortVersionString` и
`CFBundleVersion` (они равны), собирает, упаковывает в zip, подписывает zip EdDSA-ключом
из Keychain (`generate_appcast`), собирает DMG для первой установки (приложение + ссылка
на `/Applications`; Sparkle обновляет по zip) и публикует всё через `gh`. Апдейтер
(`Updater.swift`) проверяет обновления при каждом запуске (`checkForUpdatesInBackground`
сразу после старта) и раз в сутки, найденное показывает собственным диалогом Sparkle
(на русском благодаря региону разработки `ru`). Апдейтер выключен, пока `SUPublicEDKey`
пуст, вне .app-бандла и при `ARTEL_HOME` (если не задан `ARTEL_UPDATE_FEED`).

Раньше Artel назывался Aide. `LegacyAide` (ядро) и `LegacyMigration` (приложение)
обновляют установку Aide на месте: закрывают Aide, переносят `Application Support/Aide`
(оставляя симлинк для живых сессий), работают через tmux-сервер `aide`, пока он жив,
и переименовывают его сессии, читают папку задач `.aide/` проекта на месте
(`TaskStore.dirName`), понимают старые JSON-ключи, переменные `AIDE_*` в хуке и старый
блок в конфиге Kimi. Старые имена держите внутри этого слоя и не переименовывайте их
в остальном коде.

## Запуск и проверка UI

Извне UI жестами недоступен, поэтому проверка — через встроенные debug-хуки
(список шагов — в `Sources/Artel/DebugSnapshot.swift`):
- `ARTEL_HOME=<tmp dir>` — изолированный каталог данных (для второго/dev-экземпляра;
  не трогайте реальное состояние пользователя). Заодно задавайте
  `KIMI_CODE_HOME=<tmp dir>`, иначе экземпляр перепишет блок хуков в настоящем
  `~/.kimi-code/config.toml` на свой бинарник хука.
- `ARTEL_WORKTREES=<dir>` — переопределение корня worktree.
- `ARTEL_UPDATE_FEED=<URL appcast>` — включает апдейтер в экземпляре с `ARTEL_HOME` и
  направляет его на этот фид, чтобы увидеть диалог обновления. Sparkle принимает только
  http(s): тестовый appcast раздавайте через `python3 -m http.server --bind 127.0.0.1`.
  Запускайте копию приложения с другим `CFBundleIdentifier`, иначе Sparkle запишет своё
  состояние в настройки настоящего приложения.
- `ARTEL_SNAPSHOT=/path.png` — рендер главного окна (или открытого шита) в PNG
  каждые 3 с, без прав на запись экрана. Vibrancy/стекло тулбара рендерятся
  пустыми пятнами — известный артефакт, не баг.
- `ARTEL_DEBUG_SCRIPT='[{"section":"tasks"},{"open":"ARTEL-1"},{"preview":true},{"snapshot":"/path.png"}]'`
  — сценарий действий после старта (select, launch, setStatus, done, …);
  прогресс — в `$ARTEL_DEBUG_LOG`.

## Ограничения

- Лимиты подписки читаются из существующих логинов Claude Code (Keychain) и
  Kimi Code (`~/.kimi-code/credentials/`) — только чтение, никогда не писать.
  Не печатать и не логировать OAuth-токены. User-Agent остаётся generic
  (`Artel/<version>`); email пользователя в запросы не добавлять.
- Коммит `.artel/` в проектах пользователя — только по явному действию оператора.
- Artel под GPL-3.0 (из-за STTextView, который SwiftPM линкует статически). Новые
  зависимости должны быть совместимы с GPL-3.0 (MIT, BSD, ISC, Apache-2.0, LGPL…;
  не GPL-2.0-only и не проприетарные). `build-app.sh` копирует лицензию каждого
  пакета в `Contents/Resources/Licenses/`; для бинарника не из SwiftPM (как tmux,
  libevent) лицензию нужно положить туда же.

## Отличия от CLAUDE.md

- Этот файл читают агенты вроде Kimi Code; `CLAUDE.md` читает Claude Code. Для проектов
  внутри самого приложения он не обязателен: при добавлении Artel только предлагает шаблон
  (см. `ProjectValidator`).
- Дата-зависимости: даты в frontmatter задач — UTC ISO 8601.
