#!/usr/bin/env node
// Interactive build helper for Furl: node scripts/build.mjs
// Zero dependencies — this repo has no package.json, so the prompts are
// hand-rolled.
//
//   Build & install (dev) · Build only · Release (version step → notarized
//   build → notes / commit / tag → GitHub Release) · Verify installed app
//
// node scripts/build.mjs --verify runs the verify checks non-interactively.
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

process.chdir(path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));

// --- constants (keep in sync with scripts/bi.sh / scripts/release.sh) ----------
const PBXPROJ = 'Furl.xcodeproj/project.pbxproj';
const APP_INSTALLED = '/Applications/Furl.app';
const TAP_REPO = 'julianbaker/homebrew-tap';
const CASK_PATH = 'Casks/furl.rb';
const DEV_CERT_SHA = '31D11F430CF35482F4807A25F58C511B5CA1A35A';
const DEV_KEYCHAIN = path.join(os.homedir(), 'Library/Keychains/dryice-signing.keychain-db');
const LOGIN_KEYCHAIN = path.join(os.homedir(), 'Library/Keychains/login.keychain-db');
const NOTES_DIR = 'docs/release-notes';
const NOTES_NEXT = path.join(NOTES_DIR, 'NEXT.md');

const bold = (s) => `\x1b[1m${s}\x1b[0m`;
const dim = (s) => `\x1b[2m${s}\x1b[0m`;
const cyan = (s) => `\x1b[36m${s}\x1b[0m`;
const green = (s) => `\x1b[32m${s}\x1b[0m`;
const red = (s) => `\x1b[31m${s}\x1b[0m`;
const stripAnsi = (s) => s.replace(/\x1b\[[0-9;]*m/g, '');

// Menu lines must never wrap: select()'s redraw moves the cursor up by logical
// line count, and a wrapped line desyncs it. Clamped lines lose their styling.
function fit(line) {
  const width = process.stdout.columns || 80;
  if (stripAnsi(line).length < width) return line;
  return `${stripAnsi(line).slice(0, width - 2)}…`;
}

function sh(cmd, args, { allowFail = false, env = process.env } = {}) {
  const r = spawnSync(cmd, args, { stdio: 'inherit', env });
  if (r.status !== 0 && !allowFail) {
    console.error(`\n${cmd} ${args.join(' ')} failed (exit ${r.status ?? 'killed'})`);
    process.exit(r.status ?? 1);
  }
  return r.status ?? 0;
}

function step(title, fn) {
  console.log(`\n${bold(cyan(`==> ${title}`))}`);
  const t = Date.now();
  fn();
  console.log(dim(`    done in ${Math.round((Date.now() - t) / 1000)}s`));
}

// --- minimal prompts (no deps) --------------------------------------------------

function requireTTY() {
  if (!process.stdin.isTTY) {
    console.error('Interactive terminal required (or use --verify).');
    process.exit(1);
  }
}

function withRawKeys(handler) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, escapeCodeTimeout: 50 });
    readline.emitKeypressEvents(process.stdin, rl);
    process.stdin.setRawMode(true);
    const done = (value) => {
      process.stdin.off('keypress', onKey);
      process.stdin.setRawMode(false);
      rl.close();
      resolve(value);
    };
    const onKey = (str, key) => {
      if (key?.ctrl && key.name === 'c') {
        process.stdout.write('\x1b[?25h\nBye.\n');
        process.exit(0);
      }
      handler(str, key, done);
    };
    process.stdin.on('keypress', onKey);
  });
}

async function select({ message, choices }) {
  requireTTY();
  let idx = 0;
  let lines = 0;
  const draw = () => {
    if (lines) process.stdout.write(`\x1b[${lines}A\x1b[J`);
    const out = [bold(message)];
    choices.forEach((c, i) => {
      out.push(i === idx ? `${cyan('❯')} ${bold(c.name)}` : `  ${c.name}`);
    });
    out.push(dim(`  ${choices[idx].description ?? ''}`));
    const fitted = out.map(fit);
    lines = fitted.length;
    process.stdout.write(fitted.join('\n') + '\n');
  };
  process.stdout.write('\x1b[?25l');
  draw();
  return withRawKeys((str, key, done) => {
    if (key?.name === 'up' || str === 'k') idx = (idx + choices.length - 1) % choices.length;
    else if (key?.name === 'down' || str === 'j') idx = (idx + 1) % choices.length;
    else if (key?.name === 'return') {
      process.stdout.write('\x1b[?25h\n');
      return done(choices[idx].value);
    } else return;
    draw();
  });
}

async function confirm({ message, def = true }) {
  requireTTY();
  process.stdout.write(`${bold(message)} ${dim(def ? '(Y/n)' : '(y/N)')} `);
  return withRawKeys((str, key, done) => {
    if (str === 'y' || str === 'Y') { process.stdout.write('y\n'); done(true); }
    else if (str === 'n' || str === 'N') { process.stdout.write('n\n'); done(false); }
    else if (key?.name === 'return') { process.stdout.write(`${def ? 'y' : 'n'}\n`); done(def); }
  });
}

async function input({ message }) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const answer = await new Promise((r) => rl.question(`${bold(message)} `, r));
  rl.close();
  return answer.trim();
}

// --- project facts ---------------------------------------------------------------

function projectVersion() {
  const pbx = fs.readFileSync(PBXPROJ, 'utf8');
  return {
    version: pbx.match(/MARKETING_VERSION = ([^;]+);/)?.[1] ?? '?',
    build: pbx.match(/CURRENT_PROJECT_VERSION = ([^;]+);/)?.[1] ?? '?',
  };
}

// The only version write in any flow — reached solely via an explicit bump.
function writeProjectVersion(version) {
  const pbx = fs.readFileSync(PBXPROJ, 'utf8');
  fs.writeFileSync(PBXPROJ, pbx.replace(/MARKETING_VERSION = [^;]+;/g, `MARKETING_VERSION = ${version};`));
}

async function pickReleaseVersion(current) {
  const m = current.match(/^(\d+)\.(\d+)\.(\d+)$/);
  const choices = [{
    name: `Ship ${current} (current)`,
    value: null,
    description: 'No version change — releases the version exactly as committed.',
  }];
  if (m) {
    const [, maj, min, pat] = m.map(Number);
    choices.push(
      { name: `Bump patch → ${maj}.${min}.${pat + 1}`, value: `${maj}.${min}.${pat + 1}`, description: 'Fixes only.' },
      { name: `Bump minor → ${maj}.${min + 1}.0`, value: `${maj}.${min + 1}.0`, description: 'New functionality.' },
      { name: `Bump major → ${maj + 1}.0.0`, value: `${maj + 1}.0.0`, description: 'Breaking / headline changes.' },
    );
  }
  choices.push({ name: 'Custom…', value: 'custom', description: 'Type a version yourself.' });
  let picked = await select({ message: `Version to ship ${dim(`(current ${current})`)}`, choices });
  while (picked === 'custom') {
    picked = await input({ message: 'Version (x.y.z):' });
    if (!/^\d+\.\d+\.\d+$/.test(picked)) { console.log(red('  not x.y.z — try again')); picked = 'custom'; }
  }
  return picked; // null = ship current
}

// --- GitHub Releases (the upload leg of the release flow) -------------------------

function gh(args) {
  return spawnSync('gh', args, { encoding: 'utf8' });
}

function ghReady() {
  try { execFileSync('gh', ['--version'], { stdio: 'ignore' }); } catch { return { ok: false, why: 'gh not installed (brew install gh)' }; }
  if (spawnSync('gh', ['auth', 'status'], { stdio: 'ignore' }).status !== 0) return { ok: false, why: 'gh not authenticated (gh auth login)' };
  return { ok: true };
}

function ghRepoVisibility() {
  const r = gh(['repo', 'view', '--json', 'visibility', '-q', '.visibility']);
  return r.status === 0 ? r.stdout.trim() : null;
}

function ghReleaseExists(tag) {
  return spawnSync('gh', ['release', 'view', tag], { stdio: 'ignore' }).status === 0;
}

// Regenerated whole on every release; the tap file is not hand-edited.
function caskContents(version, sha256) {
  return `cask "furl" do
  version "${version}"
  sha256 "${sha256}" # updated by Furl's release pipeline

  url "https://github.com/julianbaker/Furl/releases/download/v#{version}/Furl-#{version}.zip"
  name "Furl"
  desc "Menu bar utility that makes off-screen overflow items reachable (Accessibility-only)"
  homepage "https://github.com/julianbaker/Furl"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Furl.app"

  zap trash: [
    "~/Library/Preferences/design.julianbaker.Furl.plist",
  ]
end
`;
}

// Brew can only fetch release assets from a PUBLIC repo, so the cask update is
// skipped (with a note) while Furl is private. Failures here never kill the
// release — the zip and GitHub Release already exist.
function updateHomebrewCask(version, zip) {
  const visibility = ghRepoVisibility();
  if (visibility !== 'PUBLIC') {
    console.log(dim(`Cask not updated: Furl repo is ${visibility ?? 'unknown'} — brew can't download its release assets yet.`));
    return;
  }
  const sha256 = execFileSync('shasum', ['-a', '256', zip], { encoding: 'utf8' }).split(' ')[0];
  const content = Buffer.from(caskContents(version, sha256)).toString('base64');
  const existing = gh(['api', `repos/${TAP_REPO}/contents/${CASK_PATH}`, '--jq', '.sha']);
  const args = [
    'api', '-X', 'PUT', `repos/${TAP_REPO}/contents/${CASK_PATH}`,
    '-f', `message=furl ${version}`,
    '-f', `content=${content}`,
  ];
  if (existing.status === 0) args.push('-f', `sha=${existing.stdout.trim()}`);
  const r = gh(args);
  if (r.status === 0) {
    console.log(green(`Cask updated: brew upgrade will now serve ${version}.`));
  } else {
    console.log(red(`Cask update failed (release itself is fine): ${(r.stderr || '').trim().slice(0, 200)}`));
    console.log(dim(`Update ${TAP_REPO}/${CASK_PATH} manually: version ${version}, sha256 ${sha256}`));
  }
}

async function publishGitHubRelease({ version, zip, notesFile, mode }) {
  const tag = `v${version}`;
  step('Pushing branch + tag to origin', () => sh('git', ['push', 'origin', 'HEAD', '--follow-tags']));
  if (ghReleaseExists(tag)) {
    // Same-version re-release: replace the asset and refresh the notes.
    step(`Release ${tag} already exists — replacing asset`, () => {
      sh('gh', ['release', 'upload', tag, zip, '--clobber']);
      if (notesFile) sh('gh', ['release', 'edit', tag, '--notes-file', notesFile], { allowFail: true });
    });
    console.log(green(`Updated existing release ${tag} with the new artifact.`));
  } else {
    step(`Creating GitHub Release ${tag}${mode === 'draft' ? ' (draft)' : ''}`, () => {
      const args = ['release', 'create', tag, zip, '--title', `Furl ${version}`];
      if (notesFile) args.push('--notes-file', notesFile);
      else args.push('--generate-notes');
      if (mode === 'draft') args.push('--draft');
      sh('gh', args);
    });
    console.log(green(`${mode === 'draft' ? 'Draft release' : 'Release'} ${tag} created with ${path.basename(zip)} attached.`));
  }
  // Draft assets aren't downloadable, so the cask only updates on real publishes.
  if (mode !== 'draft') updateHomebrewCask(version, zip);
}

// --- keychains (fail fast, before any slow build) ---------------------------------

function canSignWith(identity, keychain) {
  const probe = path.join(os.tmpdir(), `furl-codesign-probe-${process.pid}`);
  fs.copyFileSync('/bin/ls', probe);
  try {
    const args = ['--force', '--sign', identity, ...(keychain ? ['--keychain', keychain] : []), probe];
    execFileSync('codesign', args, { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  } finally {
    fs.rmSync(probe, { force: true });
  }
}

function ensureDevKeychain() {
  if (canSignWith(DEV_CERT_SHA, DEV_KEYCHAIN)) return;
  console.log(`\n${bold('Signing keychain is locked')} ${dim('(typical over SSH / after reboot)')}.`);
  console.log(dim(`Unlocking ${DEV_KEYCHAIN} — enter its password.`));
  sh('security', ['unlock-keychain', DEV_KEYCHAIN]);
  if (!canSignWith(DEV_CERT_SHA, DEV_KEYCHAIN)) {
    console.error(
      'Unlocked, but codesign still cannot use the key.\n' +
      'If this keychain is a COPY, that is the cause (key ACLs do not survive a copy\n' +
      '— errSecInternalComponent). Use the original keychain.',
    );
    process.exit(1);
  }
}

function developerIDIdentity() {
  try {
    const out = execFileSync('security', ['find-identity', '-v', '-p', 'codesigning'], { encoding: 'utf8' });
    return out.split('\n').find((l) => l.includes('Developer ID Application'))?.match(/\b([0-9A-F]{40})\b/)?.[1] ?? null;
  } catch {
    return null;
  }
}

function ensureReleaseSigning() {
  const identity = developerIDIdentity();
  if (!identity) {
    // Cloud signing (ASC API key) cannot mint Developer ID certs — Apple
    // gates that cert type to the Account Holder ("Cloud signing permission
    // error" at export). A local cert is a one-time setup:
    // Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID
    // Application.
    console.log(`\n${bold(red('No "Developer ID Application" certificate in the keychain.'))}`);
    console.log('One-time setup: Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸');
    console.log('Developer ID Application. Then re-run this flow.');
    process.exit(1);
  }
  if (canSignWith(identity, null)) return;
  console.log(`\n${bold('Login keychain is locked')} — codesign would fail at the end of the archive.`);
  console.log(dim('Enter your Mac login password to unlock it for this session.'));
  sh('security', ['unlock-keychain', LOGIN_KEYCHAIN]);
  if (!canSignWith(identity, null)) {
    console.error('Keychain unlocked but codesign still cannot use the Developer ID key.');
    process.exit(1);
  }
}

// --- flows: dev build & install ---------------------------------------------------

async function runDevInstall() {
  const flavor = await select({
    message: 'How clean a build do you need?',
    choices: [
      {
        name: 'Standard (incremental)',
        value: {},
        description: 'Fastest. Right choice after normal code changes.',
      },
      {
        name: 'Clean (delete build/DerivedData)',
        value: { derivedData: true },
        description: 'Full recompile + fresh SPM resolution. For inexplicable staleness.',
      },
    ],
  });
  ensureDevKeychain();
  if (flavor.derivedData) {
    step('Deleting build/DerivedData', () => fs.rmSync('build/DerivedData', { recursive: true, force: true }));
  }
  const t0 = Date.now();
  sh('./scripts/bi.sh', []);
  const total = Math.round((Date.now() - t0) / 1000);
  console.log(`\n${green(bold(`Done in ${Math.floor(total / 60)}m ${total % 60}s.`))}`);
}

// --- flows: build only -------------------------------------------------------------

function runBuildOnly() {
  step('Building (Release, ad-hoc — nothing installed)', () => {
    sh('xcodebuild', [
      '-project', 'Furl.xcodeproj', '-scheme', 'Furl', '-configuration', 'Release',
      '-derivedDataPath', 'build/DerivedData',
      'CODE_SIGN_IDENTITY=-', 'DEVELOPMENT_TEAM=', 'build', '-quiet',
    ]);
  });
  console.log(green('Compiles clean.'));
}

// --- flows: release ----------------------------------------------------------------

function latestArchivedNotes() {
  if (!fs.existsSync(NOTES_DIR)) return null;
  const latest = fs.readdirSync(NOTES_DIR)
    .filter((f) => /^v.+\.md$/.test(f))
    .map((f) => ({ f, mtime: fs.statSync(path.join(NOTES_DIR, f)).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime)[0];
  return latest ? { file: latest.f, text: fs.readFileSync(path.join(NOTES_DIR, latest.f), 'utf8') } : null;
}

function openInEditor(file) {
  const [cmd, ...args] = (process.env.EDITOR || process.env.VISUAL || 'vi').split(' ');
  const r = spawnSync(cmd, [...args, file], { stdio: 'inherit' });
  if (r.status !== 0) console.log(dim(`(${cmd} exited with ${r.status ?? 'a signal'} — using the file as-is)`));
}

function printNotes(text) {
  console.log(dim('  ┌─────'));
  for (const line of text.split('\n')) console.log(`  ${dim('│')} ${line}`);
  console.log(dim('  └─────'));
}

async function resolveReleaseNotes() {
  fs.mkdirSync(NOTES_DIR, { recursive: true });
  while (true) {
    const pending = fs.existsSync(NOTES_NEXT) ? fs.readFileSync(NOTES_NEXT, 'utf8').trim() : '';
    if (pending) {
      console.log(`\n${bold(`Pending release notes (${NOTES_NEXT}):`)}`);
      printNotes(pending);
      const action = await select({
        message: 'Use these notes?',
        choices: [
          { name: 'Yes, use them', value: 'use' },
          { name: 'Edit first', value: 'edit', description: `Opens ${NOTES_NEXT} in $EDITOR, then re-confirms` },
          { name: 'Type different notes here instead', value: 'cli' },
          { name: 'No notes for this release', value: 'none' },
        ],
      });
      if (action === 'use') return pending;
      if (action === 'none') return '';
      if (action === 'cli') return input({ message: 'Release notes:' });
      openInEditor(NOTES_NEXT);
      continue;
    }
    const prior = latestArchivedNotes();
    const how = await select({
      message: `No pending release notes (${NOTES_NEXT}). Compose them how?`,
      choices: [
        {
          name: `Create it${prior ? ` pre-filled from ${prior.file}` : ''} and edit now`,
          value: 'file',
          description: 'Opens $EDITOR; you confirm the contents before anything is released.',
        },
        { name: 'Type them here', value: 'cli' },
        { name: 'No notes for this release', value: 'none' },
      ],
    });
    if (how === 'none') return '';
    if (how === 'cli') return input({ message: 'Release notes:' });
    fs.writeFileSync(NOTES_NEXT, prior ? prior.text : 'Bug fixes and improvements.\n');
    openInEditor(NOTES_NEXT);
  }
}

function archiveReleaseNotes(notes, version) {
  const stamp = new Date().toISOString().slice(0, 10);
  let file = path.join(NOTES_DIR, `v${version}-${stamp}.md`);
  for (let n = 2; fs.existsSync(file); n++) file = path.join(NOTES_DIR, `v${version}-${stamp}.${n}.md`);
  fs.writeFileSync(file, notes.endsWith('\n') ? notes : `${notes}\n`);
  fs.rmSync(NOTES_NEXT, { force: true });
  console.log(green(`Release notes saved to ${file}.`));
  return file;
}

// Local commit + tag only; pushing happens solely in the GitHub step.
function commitAndTagRelease(notes, mode, version, extraPaths = []) {
  if (mode === 'none') {
    console.log(dim('Skipping auto-commit/tag as requested.'));
    return;
  }
  const tag = `v${version}`;
  const title = `Release Furl ${version}`;
  const message = notes ? `${title}\n\n${notes}` : title;
  step(`Committing release and tagging ${tag}`, () => {
    if (mode === 'all') {
      sh('git', ['add', '-A']);
      if (spawnSync('git', ['diff', '--cached', '--quiet']).status !== 0) {
        sh('git', ['commit', '-m', message]);
      } else {
        console.log(dim('    nothing to commit — tagging HEAD'));
      }
    } else {
      const paths = [NOTES_DIR, ...extraPaths];
      const dirty = execFileSync('git', ['status', '--porcelain', '--', ...paths], { encoding: 'utf8' }).trim();
      if (dirty) {
        sh('git', ['add', '--', ...paths]);
        sh('git', ['commit', '-m', message, '--', ...paths]);
      } else {
        console.log(dim('    nothing to commit (release files unchanged) — tagging HEAD'));
      }
    }
    if (sh('git', ['tag', '-a', tag, '-m', message], { allowFail: true }) !== 0) {
      console.log(`${dim('    tag')} ${tag} ${dim('already exists — left as-is (same-version re-release)')}`);
    }
  });
  console.log(green(`Tagged ${tag}.`));
}

async function runRelease() {
  // The archive builds from the WORKING TREE: uncommitted changes ship in the
  // binary, while the release tag would point at code that lacks them.
  let commitMode = 'release-files';
  const dirty = execFileSync('git', ['status', '--porcelain'], { encoding: 'utf8' }).trim();
  if (dirty) {
    const lines = dirty.split('\n');
    console.log(`\n${bold('Uncommitted changes — these WILL be in the released binary:')}`);
    for (const l of lines.slice(0, 10)) console.log(dim(`  ${l}`));
    if (lines.length > 10) console.log(dim(`  …and ${lines.length - 10} more`));
    commitMode = await select({
      message: 'How should the post-release commit handle them?',
      choices: [
        {
          name: 'Roll them into the release commit',
          value: 'all',
          description: 'git add -A — the tagged commit matches the shipped binary exactly.',
        },
        {
          name: 'Keep them out — commit only the release files',
          value: 'release-files',
          description: 'docs/release-notes (+ the project file on a version bump). In-progress work stays uncommitted (but is still in the binary).',
        },
        { name: 'Skip the auto-commit and tag', value: 'none', description: 'Build + notarize only; commit and tag yourself later.' },
        { name: 'Cancel — let me commit first', value: 'cancel' },
      ],
    });
    if (commitMode === 'cancel') return console.log('Cancelled.');
  }

  const current = projectVersion();
  const bumpTo = await pickReleaseVersion(current.version);
  const version = bumpTo ?? current.version;

  const notes = await resolveReleaseNotes();
  const [firstLine, ...rest] = notes.split('\n');
  const notesSummary = notes ? `"${firstLine}${rest.length ? '…' : ''}"` : 'no notes';

  // Asked up front so one confirm runs the whole pipeline unattended.
  const ghState = ghReady();
  const visibility = ghState.ok ? ghRepoVisibility() : null;
  let ghMode = 'skip';
  if (ghState.ok) {
    ghMode = await select({
      message: 'Publish to GitHub Releases?',
      choices: [
        { name: 'Publish', value: 'publish', description: `Pushes branch + tag, creates the release with the zip attached, updates the brew cask${visibility ? ` (repo is ${visibility})` : ''}.` },
        { name: 'Create as draft', value: 'draft', description: 'Same, but the release stays a draft until you publish it on GitHub.' },
        { name: 'Skip — build only', value: 'skip', description: 'No push, nothing leaves this machine.' },
      ],
    });
  } else {
    console.log(dim(`\nGitHub Release step unavailable: ${ghState.why}. Building only.`));
  }

  console.log(`\n${bold('Plan')}`);
  console.log(`  • Release ${bold(`Furl ${version} (build ${current.build})`)}${bumpTo ? ` — version bump ${current.version} → ${bumpTo}, written to the project` : ' — version ships as-is'}`);
  console.log(`  • Archive → Developer ID export → notarize → staple → zip ${dim(`(${notesSummary})`)}`);
  const commitDesc = {
    all: `commit ALL changes, tag v${version}`,
    'release-files': `commit release files, tag v${version}`,
    none: 'no commit/tag (skipped by choice)',
  }[commitMode];
  console.log(dim(`  • After: archive notes, ${commitDesc}.`));
  console.log(dim(`  • GitHub: ${{ publish: `push + create release v${version}${visibility ? ` on the ${visibility} repo` : ''}`, draft: `push + create DRAFT release v${version}`, skip: 'skipped — nothing leaves this machine' }[ghMode]}`));
  if (!(await confirm({ message: 'Proceed?' }))) return console.log('Cancelled.');

  ensureReleaseSigning();
  if (bumpTo) step(`Setting MARKETING_VERSION = ${bumpTo}`, () => writeProjectVersion(bumpTo));
  sh('./scripts/release.sh', []);
  const notesFile = notes ? archiveReleaseNotes(notes, version) : null;
  commitAndTagRelease(notes, commitMode, version, bumpTo ? [PBXPROJ] : []);
  const zip = `.release/Furl-${version}.zip`;
  if (ghMode !== 'skip') await publishGitHubRelease({ version, zip, notesFile, mode: ghMode });
  console.log(`\n${green(bold(`Done — ${zip} is signed, notarized, and stapled${ghMode !== 'skip' ? ' and on GitHub' : ''}.`))}`);
}

// --- flows: verify installed app -----------------------------------------------------

function runVerify() {
  if (!fs.existsSync(APP_INSTALLED)) {
    console.log(`${red('✗')} ${APP_INSTALLED} not installed.`);
    return;
  }
  const check = (label, cmd, args) => {
    const r = spawnSync(cmd, args, { encoding: 'utf8' });
    const out = `${r.stdout ?? ''}${r.stderr ?? ''}`.trim();
    console.log(`${r.status === 0 ? green('✓') : red('✗')} ${bold(label)}`);
    for (const line of out.split('\n').filter(Boolean).slice(0, 6)) console.log(dim(`    ${line}`));
  };
  console.log(`${bold('Installed app:')} ${APP_INSTALLED}\n`);
  check('Signature valid', 'codesign', ['--verify', '--strict', APP_INSTALLED]);
  const authority = spawnSync('codesign', ['-dvv', APP_INSTALLED], { encoding: 'utf8' });
  for (const line of (authority.stderr ?? '').split('\n').filter((l) => /^(Authority|TeamIdentifier|Identifier)=/.test(l))) {
    console.log(dim(`    ${line}`));
  }
  check('Gatekeeper assessment', 'spctl', ['--assess', '--type', 'execute', APP_INSTALLED]);
  check('Notarization ticket stapled', 'xcrun', ['stapler', 'validate', APP_INSTALLED]);
  const running = spawnSync('pgrep', ['-x', 'Furl']).status === 0;
  console.log(`${running ? green('✓') : dim('·')} ${bold(running ? 'Running' : 'Not running')}`);
  console.log(dim('\nNote: dev builds (bi.sh) are self-signed — Gatekeeper/staple checks fail for'));
  console.log(dim('them by design. Those checks matter for release builds.'));
}

// --- main -----------------------------------------------------------------------------

async function main() {
  if (process.argv.includes('--verify')) return runVerify();

  const { version, build } = projectVersion();
  console.log(dim(`Furl ${version} (build ${build})`));
  const action = await select({
    message: 'What do you want to do?',
    choices: [
      { name: 'Build & install (dev)', value: runDevInstall, description: 'Build, re-sign with the stable local cert, install /Applications, relaunch (scripts/bi.sh)' },
      { name: 'Build only', value: runBuildOnly, description: 'Compile check — nothing installed' },
      { name: 'Release (Developer ID + notarize → GitHub)', value: runRelease, description: 'Version step (ship-as-is or bump) → release.sh → notes, commit + tag → GitHub Release with the zip attached.' },
      { name: 'Verify installed app', value: runVerify, description: 'Signature, Gatekeeper, notarization staple, running state' },
    ],
  });
  await action();
}

main().catch((err) => {
  console.error(err?.message ?? err);
  process.exit(1);
});
