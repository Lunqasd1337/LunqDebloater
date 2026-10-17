'use strict';
// Окно над LunqDebloater.ps1: собирает параметры, запускает скрипт и показывает его события.
// Скрипт сам проверяет систему и делает всю работу, поэтому здесь нет своей логики сборки.

const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const dialog = window.__TAURI__.dialog;

const $ = (id) => document.getElementById(id);
const LABEL_PATTERN = /^[A-Za-z0-9_-]{1,32}$/;
const DEFAULT_LABEL = 'LUNQ_WIN11';

const state = {
  lang: 'ru',
  info: null,
  fatal: null,
  iso: '',
  isoTicket: 0,
  loadingEditions: false,
  editions: [],
  editionsError: '',
  index: 0,
  output: '',
  outputCustom: false,
  categories: new Map(),
  updatesDir: '',
  driversDir: '',
  inputs: { updates: 0, drivers: 0, apps: 0, scripts: 0 },
  opts: {
    unattend: true, localAccount: false, bypass: false,
    updates: true, cleanup: false, updatesToSetup: false,
    drivers: true, driversToSetup: false,
    apps: true, scripts: true
  },
  run: null
};

// ---------- Тексты ----------

function t(key, ...args) {
  const table = LUNQ_STRINGS[state.lang] || LUNQ_STRINGS.ru;
  const text = table[key] ?? LUNQ_STRINGS.ru[key] ?? key;
  return text.replace(/\{(\d+)\}/g, (match, i) => (args[i] ?? ''));
}

function local(value) {
  // Name и Description профиля пишутся на двух языках: { "ru": "...", "en": "..." }.
  if (value == null) return '';
  if (typeof value === 'string') return value;
  return value[state.lang] ?? value.ru ?? value.en ?? '';
}

function duration(seconds) {
  const total = Math.max(0, Math.round(seconds || 0));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  if (h > 0) return t('time.hm', h, String(m).padStart(2, '0'));
  if (m > 0) return t('time.m', m);
  return t('time.s', total);
}

function errorText(error) {
  // Rust отдаёт коды для своих ошибок, а текст ошибок скрипта уже на нужном языке.
  const text = String(error ?? '');
  if (text === 'NO_SCRIPT') return t('err.noScript');
  if (text === 'ALREADY_RUNNING') return t('err.alreadyRunning');
  const failed = text.match(/^SCRIPT_FAILED (-?\d+)\n?([\s\S]*)$/);
  if (failed) return [t('fin.noAnswer', failed[1]), failed[2]].filter(Boolean).join('\n\n');
  return text;
}

function applyLanguage() {
  document.documentElement.lang = state.lang;
  for (const node of document.querySelectorAll('[data-t]')) node.textContent = t(node.dataset.t);
  for (const button of document.querySelectorAll('[data-lang]')) {
    button.classList.toggle('active', button.dataset.lang === state.lang);
  }
  renderSetup();
}

// ---------- Мелкие элементы ----------

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function toggle({ checked, disabled, name, hint, onChange, nested }) {
  const row = el('label', 'toggle' + (nested ? ' nested' : '') + (disabled ? ' disabled' : ''));
  const input = el('input');
  input.type = 'checkbox';
  input.checked = !!checked && !disabled;
  input.disabled = !!disabled;
  input.addEventListener('change', () => onChange(input.checked));
  const text = el('span', 'text');
  text.append(el('span', 'name', name));
  if (hint) text.append(el('span', 'hint', hint));
  row.append(input, el('span', 'switch'), text);
  return row;
}

function buttonLink(text, onClick) {
  const button = el('button', 'link', text);
  button.type = 'button';
  button.addEventListener('click', onClick);
  return button;
}

function show(screen) {
  for (const id of ['setup', 'progress', 'finish']) $(id).classList.toggle('hidden', id !== screen);
  // Язык меняется только до сборки: сообщения скрипта приходят на том, с которым он запущен.
  document.querySelector('.lang').classList.toggle('hidden', screen !== 'setup');
}

function setHidden(id, hidden) {
  $(id).classList.toggle('hidden', hidden);
}

function joinPath(dir, name) {
  return dir.replace(/[\\/]+$/, '') + '\\' + name;
}

function defaultOutput(iso) {
  // Как в скрипте: рядом с исходным ISO, с _Lunq в имени.
  const cut = Math.max(iso.lastIndexOf('\\'), iso.lastIndexOf('/'));
  const dir = iso.slice(0, cut);
  const name = iso.slice(cut + 1).replace(/\.[^.]*$/, '');
  return joinPath(dir, name + '_Lunq.iso');
}

// ---------- Экран настройки ----------

function renderSetup() {
  if (state.fatal != null) {
    // Без скрипта или профиля окну нечего показать: объясняем, что не так.
    const raw = String(state.fatal);
    $('fatal').textContent = raw === 'NO_SCRIPT' ? t('err.noScript') : t('err.profile', raw);
    setHidden('fatal', false);
  }
  $('version').textContent = state.info ? state.info.version : '';

  // 1. ISO и редакция.
  $('pickIso').textContent = state.iso ? t('iso.pickOther') : t('iso.pick');
  $('pickIso').disabled = !state.info;
  $('isoPath').textContent = state.iso || t('iso.none');
  $('isoPath').classList.toggle('muted', !state.iso);
  const select = $('edition');
  select.replaceChildren();
  for (const item of state.editions) {
    const option = el('option', null, item.name);
    option.value = String(item.index);
    option.selected = item.index === state.index;
    select.append(option);
  }
  setHidden('editionRow', state.editions.length === 0);
  select.disabled = state.editions.length < 2;
  const isoState = $('isoState');
  isoState.className = 'state';
  if (state.loadingEditions) {
    isoState.classList.add('busy');
    isoState.textContent = t('iso.reading');
  } else if (state.editionsError) {
    isoState.classList.add('error');
    isoState.textContent = t('iso.readFailed') + ': ' + state.editionsError;
  } else {
    isoState.classList.add('hidden');
  }

  // 2. Категории профиля.
  const box = $('categories');
  box.replaceChildren();
  if (state.info) {
    $('profileText').textContent = local(state.info.profile.Description);
    for (const category of state.info.profile.Categories || []) {
      box.append(toggle({
        checked: state.categories.get(category.Id),
        name: local(category.Name),
        hint: local(category.Description),
        onChange: (value) => { state.categories.set(category.Id, value); updateStart(); }
      }));
    }
  }

  // 3. Готовый образ и файл ответов.
  $('outPath').textContent = state.output || '—';
  $('outPath').classList.toggle('muted', !state.output);
  $('pickOut').disabled = !state.iso;
  const opts = state.opts;
  const setupBox = $('setupOptions');
  setupBox.replaceChildren(
    toggle({ checked: opts.unattend, name: t('opt.unattend'), hint: t('opt.unattendHint'),
      onChange: (v) => { opts.unattend = v; renderSetup(); } }),
    toggle({ nested: true, checked: opts.localAccount, disabled: !opts.unattend, name: t('opt.localAccount'), hint: t('opt.localAccountHint'),
      onChange: (v) => { opts.localAccount = v; } }),
    toggle({ nested: true, checked: opts.bypass, disabled: !opts.unattend, name: t('opt.bypass'), hint: t('opt.bypassHint'),
      onChange: (v) => { opts.bypass = v; } })
  );

  renderMore();
  updateStart();
}

function folderRow(text, dir, onPick) {
  const row = el('div', 'folder-row');
  row.append(el('span', 'hint', text));
  const links = el('span', 'links');
  links.append(
    buttonLink(t('common.open'), () => invoke('open_path', { path: dir }).catch(() => {})),
    buttonLink(t('common.folder'), onPick)
  );
  row.append(links);
  return row;
}

function renderMore() {
  const opts = state.opts;
  const inputs = state.inputs;
  const box = $('moreOptions');
  box.replaceChildren();
  if (!state.info) return;
  const config = state.info.configDir;

  const hasUpdates = inputs.updates > 0;
  box.append(toggle({ checked: opts.updates, disabled: !hasUpdates, name: t('more.updates'),
    onChange: (v) => { opts.updates = v; renderMore(); } }));
  box.append(folderRow(hasUpdates ? t('more.updatesFound', inputs.updates, state.updatesDir) : t('more.updatesEmpty', state.updatesDir),
    state.updatesDir, () => pickFolder('updatesDir')));
  if (hasUpdates && opts.updates) {
    box.append(
      toggle({ nested: true, checked: opts.cleanup, name: t('more.cleanup'), hint: t('more.cleanupHint'), onChange: (v) => { opts.cleanup = v; } }),
      toggle({ nested: true, checked: opts.updatesToSetup, name: t('more.updatesToSetup'), hint: t('more.updatesToSetupHint'), onChange: (v) => { opts.updatesToSetup = v; } })
    );
  }

  const hasDrivers = inputs.drivers > 0;
  box.append(toggle({ checked: opts.drivers, disabled: !hasDrivers, name: t('more.drivers'),
    onChange: (v) => { opts.drivers = v; renderMore(); } }));
  box.append(folderRow(hasDrivers ? t('more.driversFound', inputs.drivers, state.driversDir) : t('more.driversEmpty', state.driversDir),
    state.driversDir, () => pickFolder('driversDir')));
  if (hasDrivers && opts.drivers) {
    box.append(toggle({ nested: true, checked: opts.driversToSetup, name: t('more.driversToSetup'), hint: t('more.driversToSetupHint'),
      onChange: (v) => { opts.driversToSetup = v; } }));
  }

  box.append(toggle({ checked: opts.apps, disabled: inputs.apps === 0, name: t('more.apps'),
    hint: inputs.apps > 0 ? t('more.appsFound', inputs.apps) : t('more.appsEmpty', joinPath(config, 'Apps.txt')),
    onChange: (v) => { opts.apps = v; } }));
  box.append(toggle({ checked: opts.scripts, disabled: inputs.scripts === 0, name: t('more.scripts'),
    hint: inputs.scripts > 0 ? t('more.scriptsFound', inputs.scripts) : t('more.scriptsEmpty', joinPath(config, 'Scripts')),
    onChange: (v) => { opts.scripts = v; } }));
}

function updateStart() {
  let hint = '';
  let ready = false;
  if (!state.info) hint = '';
  else if (!state.iso) hint = t('hint.needIso');
  else if (state.loadingEditions) hint = t('iso.reading');
  else if (state.editionsError) hint = t('hint.isoError');
  else if (!state.index) hint = t('hint.needEdition');
  else if (!LABEL_PATTERN.test($('label').value.trim())) hint = t('hint.badLabel');
  else { ready = true; hint = t('hint.ready'); }
  $('setupHint').textContent = hint;
  $('start').disabled = !ready;
}

async function scanInputs() {
  if (!state.info) return;
  state.inputs = await invoke('scan_inputs', {
    updates: state.updatesDir, drivers: state.driversDir, configDir: state.info.configDir
  }).catch(() => ({ updates: 0, drivers: 0, apps: 0, scripts: 0 }));
  renderMore();
}

async function pickFolder(key) {
  const picked = await dialog.open({ directory: true, multiple: false, defaultPath: state[key] });
  if (!picked) return;
  state[key] = picked;
  // Нашлись файлы в новой папке: включаем её, иначе выбор выглядел бы ничего не изменившим.
  if (key === 'updatesDir') state.opts.updates = true;
  if (key === 'driversDir') state.opts.drivers = true;
  await scanInputs();
}

async function pickIso() {
  const picked = await dialog.open({ multiple: false, directory: false, filters: [{ name: t('iso.filter'), extensions: ['iso'] }] });
  if (!picked) return;
  state.iso = picked;
  if (!state.outputCustom) state.output = defaultOutput(picked);
  state.editions = [];
  state.index = 0;
  state.editionsError = '';
  state.loadingEditions = true;
  renderSetup();
  // Пока читается этот ISO, пользователь мог выбрать другой: устаревший ответ отбрасываем.
  const ticket = ++state.isoTicket;
  try {
    const items = await invoke('list_editions', { iso: picked, language: state.lang });
    if (ticket !== state.isoTicket) return;
    state.editions = Array.isArray(items) ? items : [];
    // Чаще всего ставят Pro: она и выбрана заранее, остальные в списке.
    const pro = state.editions.find((item) => / Pro$/i.test(item.name));
    state.index = (pro || state.editions[0] || { index: 0 }).index;
  } catch (error) {
    if (ticket !== state.isoTicket) return;
    state.editionsError = errorText(error);
  } finally {
    if (ticket === state.isoTicket) {
      state.loadingEditions = false;
      renderSetup();
    }
  }
}

async function pickOutput() {
  const picked = await dialog.save({ defaultPath: state.output, filters: [{ name: t('iso.filter'), extensions: ['iso'] }] });
  if (!picked) return;
  state.output = /\.iso$/i.test(picked) ? picked : picked + '.iso';
  state.outputCustom = true;
  renderSetup();
}

async function pickWorkDir() {
  const picked = await dialog.open({ directory: true, multiple: false, defaultPath: $('workDir').value });
  if (picked) $('workDir').value = picked;
}

function scriptArgs(force) {
  // Параметры LunqDebloater.ps1. Всё, что не выбрано явно, скрипт берёт по умолчанию.
  const opts = state.opts;
  const inputs = state.inputs;
  const info = state.info;
  const args = ['-IsoPath', state.iso, '-Index', String(state.index), '-OutputIso', state.output, '-Language', state.lang];
  const workDir = $('workDir').value.trim();
  if (workDir && workDir !== info.workDir) args.push('-WorkDir', workDir);

  const skip = [];
  const include = [];
  for (const category of info.profile.Categories || []) {
    const on = !!state.categories.get(category.Id);
    if (category.Enabled && !on) skip.push(category.Id);
    if (!category.Enabled && on) include.push(category.Id);
  }
  if (skip.length) args.push('-SkipCategory', skip.join(','));
  if (include.length) args.push('-IncludeCategory', include.join(','));

  if (inputs.updates > 0 && opts.updates) {
    if (state.updatesDir !== joinPath(info.configDir, 'Updates')) args.push('-UpdatesPath', state.updatesDir);
    if (opts.cleanup) args.push('-CleanupComponents');
    if (opts.updatesToSetup) args.push('-UpdatesToSetup');
  } else {
    args.push('-SkipUpdates');
  }
  if (inputs.drivers > 0 && opts.drivers) {
    if (state.driversDir !== joinPath(info.configDir, 'Drivers')) args.push('-DriversPath', state.driversDir);
    if (opts.driversToSetup) args.push('-DriversToSetup');
  } else {
    args.push('-SkipDrivers');
  }
  if (!(inputs.apps > 0 && opts.apps)) args.push('-SkipApps');
  if (!(inputs.scripts > 0 && opts.scripts)) args.push('-SkipScripts');

  if (opts.unattend) {
    args.push('-Unattend');
    if (opts.localAccount) args.push('-LocalAccount');
    if (opts.bypass) args.push('-BypassRequirements');
  }
  const label = $('label').value.trim();
  if (label !== DEFAULT_LABEL) args.push('-Label', label);
  if (force) args.push('-Force');
  return args;
}

// ---------- Сборка ----------

async function startBuild() {
  let force = false;
  if (await invoke('path_exists', { path: state.output })) {
    const replace = await dialog.ask(t('overwrite.ask', state.output), {
      title: 'LunqDebloater', kind: 'warning', okLabel: t('overwrite.ok'), cancelLabel: t('common.cancel')
    });
    if (!replace) return;
    force = true;
  }
  const opts = state.opts;
  state.run = {
    started: Date.now(),
    total: 0,
    log: '',
    lines: [],
    warnings: [],
    failedChecks: [],
    results: [],
    error: null,
    done: null,
    exit: null,
    // Для подсказки про Rufus в итоге: в образе будет файл ответов или команды первого входа.
    firstLogon: opts.unattend || (state.inputs.apps > 0 && opts.apps) || (state.inputs.scripts > 0 && opts.scripts),
    timer: setInterval(tick, 1000)
  };
  $('stepList').replaceChildren();
  $('log').textContent = '';
  $('progStep').textContent = '';
  $('progTitle').textContent = t('prog.preparing');
  $('progHint').textContent = '';
  $('progBar').style.width = '0%';
  $('progBar').classList.add('pulse');
  $('progWarn').textContent = '';
  $('progLog').disabled = true;
  tick();
  show('progress');
  try {
    await invoke('start_build', { args: scriptArgs(force) });
  } catch (error) {
    state.run.exit = { code: null, stderr: errorText(error) };
    finish();
  }
}

function tick() {
  if (!state.run) return;
  $('progElapsed').textContent = t('prog.elapsed', duration((Date.now() - state.run.started) / 1000));
}

function addLine(text) {
  const run = state.run;
  if (!run || text == null || text === '') return;
  run.lines.push(String(text));
  // В окне хватает последних строк, полный вывод есть в логе.
  if (run.lines.length > 1500) run.lines.splice(0, run.lines.length - 1500);
  const log = $('log');
  const stick = log.scrollTop + log.clientHeight >= log.scrollHeight - 8;
  log.textContent = run.lines.join('\n');
  if (stick) log.scrollTop = log.scrollHeight;
}

function stepItem(index) {
  return $('stepList').querySelector(`li[data-index="${index}"]`);
}

function onEvent(event) {
  const run = state.run;
  if (!run || run.done) return;
  switch (event.type) {
    case 'log':
      run.log = event.path || '';
      $('progLog').disabled = !run.log;
      break;
    case 'section':
      addLine('');
      addLine('— ' + event.text + ' —');
      if (!run.total) $('progTitle').textContent = event.text;
      break;
    case 'step': {
      addLine('==> ' + event.text);
      if (!event.total) break;
      run.total = event.total;
      $('progStep').textContent = t('prog.step', event.index, event.total);
      $('progTitle').textContent = event.text;
      $('progHint').textContent = event.hint || '';
      $('progBar').style.width = `${Math.max(2, ((event.index - 1) / event.total) * 100)}%`;
      const item = el('li', 'current');
      item.dataset.index = String(event.index);
      item.append(el('span', 'mark'), el('span', 'name', event.text), el('span', 'time'));
      $('stepList').append(item);
      item.scrollIntoView({ block: 'nearest' });
      break;
    }
    case 'stepEnd': {
      const item = stepItem(event.index);
      if (item) {
        item.className = event.ok ? 'ok' : 'fail';
        item.querySelector('.time').textContent = duration(event.seconds);
      }
      if (run.total) $('progBar').style.width = `${(event.index / run.total) * 100}%`;
      break;
    }
    case 'check': {
      const mark = { ok: '[OK]', warn: '[!]', fail: '[X]' }[event.status] || '';
      addLine(`${mark} ${event.text}`);
      if (event.hint) addLine('    ' + event.hint);
      if (event.status === 'fail') run.failedChecks.push(event);
      if (event.status === 'warn') run.warnings.push(event.text);
      break;
    }
    case 'info':
      addLine(event.text);
      break;
    case 'warning':
      addLine('[!] ' + event.text);
      run.warnings.push(event.text);
      break;
    case 'result':
      run.results.push(event);
      break;
    case 'error':
      run.error = event;
      addLine('[X] ' + event.text);
      break;
    case 'done':
      run.done = event;
      finish();
      break;
    default:
      break;
  }
  $('progWarn').textContent = run.warnings.length ? t('prog.warnings', run.warnings.length) : '';
}

function onExit(payload) {
  const run = state.run;
  if (!run) return;
  run.exit = payload;
  // Обычно итог уже пришёл событием done. Если нет, скрипт упал раньше, чем смог о нём сообщить.
  if (!run.done) finish();
}

// ---------- Итог ----------

function finish() {
  const run = state.run;
  if (!run || run.finished) return;
  run.finished = true;
  clearInterval(run.timer);
  const done = run.done || {};
  const ok = !!done.ok && !!done.iso;

  $('finIcon').className = 'big-icon ' + (ok ? 'ok' : 'fail');
  $('finTitle').textContent = ok ? t('fin.okTitle') : t('fin.failTitle');
  let text;
  if (ok) text = t('fin.okText', duration(done.seconds));
  else if (run.error) text = run.error.text;
  else if (run.exit && run.exit.stderr && run.exit.code == null) text = run.exit.stderr;
  else text = t('fin.noAnswer', run.exit ? run.exit.code : '?');
  $('finText').textContent = text;
  if (!ok) $('finText').classList.remove('muted');
  else $('finText').classList.add('muted');

  $('finPath').textContent = ok ? done.iso : '';
  setHidden('finPath', !ok);
  setHidden('finShow', !ok);
  const log = done.log || run.log;
  setHidden('finLog', !log);
  setHidden('finReport', !done.bugReport);
  setHidden('finReportHint', !done.bugReport);
  $('finShow').onclick = () => invoke('reveal', { path: done.iso }).catch(() => {});
  $('finLog').onclick = () => invoke('open_path', { path: log }).catch(() => {});
  $('finReport').onclick = () => invoke('reveal', { path: done.bugReport }).catch(() => {});

  // Что дальше: только после удачной сборки.
  const next = $('finNext');
  next.replaceChildren();
  if (ok) {
    next.append(el('p', null, t('fin.next')));
    if (run.firstLogon) next.append(el('p', 'muted small', t('fin.rufus')));
  } else {
    next.append(el('p', 'muted', t('fin.failText')));
    if (run.error && Array.isArray(run.error.where)) {
      for (const line of run.error.where) next.append(el('p', 'muted small mono', line));
    }
  }
  setHidden('finNext', false);

  // Проверки, которые остановили сборку, с подсказками, что сделать.
  const checks = $('finChecks');
  checks.replaceChildren();
  if (!ok && run.failedChecks.length) {
    checks.append(el('h3', null, t('fin.checks')));
    for (const check of run.failedChecks) {
      const item = el('div', 'issue');
      item.append(el('div', null, check.text));
      if (check.hint) item.append(el('div', 'muted small', check.hint));
      checks.append(item);
    }
  }
  setHidden('finChecks', checks.childElementCount === 0);

  const results = $('finResults');
  results.replaceChildren();
  if (run.results.length) {
    results.append(el('h3', null, t('fin.results')));
    for (const result of run.results) {
      const item = el('div', 'result');
      item.append(el('div', 'name', result.title || result.kind));
      // Summary есть не у всех шагов: у остальных итог по счётчикам.
      const counts = [];
      if (Array.isArray(result.done) && result.done.length) counts.push(t('fin.done', result.done.length));
      if (Array.isArray(result.skipped) && result.skipped.length) counts.push(t('fin.skipped', result.skipped.length));
      const summary = result.summary || counts.join(', ');
      if (summary) item.append(el('div', 'muted small', summary));
      const failed = Array.isArray(result.failed) ? result.failed : [];
      if (failed.length) item.append(el('div', 'error small', t('fin.failed', failed.join(', '))));
      results.append(item);
    }
  }
  setHidden('finResults', results.childElementCount === 0);

  const list = $('finWarningsList');
  list.replaceChildren(...run.warnings.map((text) => el('li', null, text)));
  $('finWarningsTitle').textContent = t('fin.warnings', run.warnings.length);
  setHidden('finWarnings', run.warnings.length === 0);

  const stderr = run.exit && run.exit.stderr ? run.exit.stderr : '';
  $('finStderr').textContent = [run.lines.slice(-200).join('\n'), stderr].filter(Boolean).join('\n\n');
  setHidden('finDetails', !$('finStderr').textContent);
  $('again').textContent = ok ? t('fin.again') : t('fin.back');

  show('finish');
}

// ---------- Запуск окна ----------

async function init() {
  let saved = null;
  try { saved = localStorage.getItem('lang'); } catch (e) { saved = null; }
  state.lang = saved === 'ru' || saved === 'en' ? saved : ((navigator.language || '').toLowerCase().startsWith('ru') ? 'ru' : 'en');

  for (const button of document.querySelectorAll('[data-lang]')) {
    button.addEventListener('click', () => {
      state.lang = button.dataset.lang;
      try { localStorage.setItem('lang', state.lang); } catch (e) { /* только удобство */ }
      applyLanguage();
      renderMore();
    });
  }
  $('pickIso').addEventListener('click', pickIso);
  $('pickOut').addEventListener('click', pickOutput);
  $('pickWorkDir').addEventListener('click', pickWorkDir);
  $('edition').addEventListener('change', (e) => { state.index = Number(e.target.value); updateStart(); });
  $('label').addEventListener('input', updateStart);
  $('start').addEventListener('click', startBuild);
  $('progLog').addEventListener('click', () => { if (state.run && state.run.log) invoke('open_path', { path: state.run.log }).catch(() => {}); });
  $('again').addEventListener('click', () => { state.run = null; show('setup'); renderSetup(); scanInputs(); });

  await listen('lunq-event', (e) => onEvent(e.payload));
  await listen('lunq-exit', (e) => onExit(e.payload));
  await listen('lunq-close-requested', async () => {
    const close = await dialog.ask(t('close.ask'), {
      title: 'LunqDebloater', kind: 'warning', okLabel: t('close.ok'), cancelLabel: t('close.cancel')
    });
    if (close) invoke('close_anyway');
  });

  try {
    state.info = await invoke('app_info');
    for (const category of state.info.profile.Categories || []) state.categories.set(category.Id, !!category.Enabled);
    state.updatesDir = joinPath(state.info.configDir, 'Updates');
    state.driversDir = joinPath(state.info.configDir, 'Drivers');
    $('label').value = DEFAULT_LABEL;
    $('workDir').value = state.info.workDir;
  } catch (error) {
    state.fatal = error;
  }
  applyLanguage();
  await scanInputs();
}

init();
