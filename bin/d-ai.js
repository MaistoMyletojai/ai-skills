#!/usr/bin/env node
'use strict'

const { spawnSync } = require('child_process')
const fs   = require('fs')
const path = require('path')
const os   = require('os')
const readline = require('readline')

const REPO_URL  = 'https://github.com/MaistoMyletojai/ai-skills.git'
const CACHE_DIR = path.join(os.homedir(), '.d-ai', 'repo')
const SKILLS_SRC = path.join(CACHE_DIR, 'skills')

const IS_WINDOWS = process.platform === 'win32'
const IS_MAC     = process.platform === 'darwin'

const [, , command, ...args] = process.argv

// ─── Output helpers ──────────────────────────────────────────────────────────

function ok(msg)   { console.log(`  \x1b[32m✓\x1b[0m ${msg}`) }
function fail(msg) { console.error(`  \x1b[31m✗\x1b[0m ${msg}`) }
function info(msg) { console.log(`  \x1b[36m·\x1b[0m ${msg}`) }
function warn(msg) { console.log(`  \x1b[33m!\x1b[0m ${msg}`) }
function bold(msg) { return `\x1b[1m${msg}\x1b[0m` }
function dim(msg)  { return `\x1b[90m${msg}\x1b[0m` }

// ─── Async input ─────────────────────────────────────────────────────────────

function ask(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout })
  return new Promise(resolve =>
    rl.question(`  ${question}: `, answer => { rl.close(); resolve(answer.trim()) })
  )
}

async function confirm(question) {
  const answer = await ask(`${question} [y/N]`)
  return answer.toLowerCase() === 'y'
}

// ─── Shell ───────────────────────────────────────────────────────────────────

function run(cmd, cwd) {
  return spawnSync(cmd, { shell: true, cwd, encoding: 'utf8' })
}

// ─── .claude location ────────────────────────────────────────────────────────

// Candidate locations, ordered by preference
function claudeCandidates() {
  const home = os.homedir()
  const candidates = [path.join(home, '.claude')]

  // Windows: also check AppData\Local\Claude and AppData\Roaming\Claude
  if (IS_WINDOWS) {
    if (process.env.LOCALAPPDATA)
      candidates.push(path.join(process.env.LOCALAPPDATA, 'Claude'))
    if (process.env.APPDATA)
      candidates.push(path.join(process.env.APPDATA, 'Claude'))
  }

  return candidates
}

async function resolveSkillsDest() {
  const candidates = claudeCandidates()
  const existing   = candidates.filter(p => fs.existsSync(p))

  if (existing.length === 1) {
    return path.join(existing[0], 'skills')
  }

  if (existing.length > 1) {
    console.log()
    warn('Found multiple .claude directories:')
    existing.forEach((p, i) => console.log(`    ${i + 1}) ${p}`))
    const choice = await ask('Which one to use? (enter number)')
    const idx = parseInt(choice, 10) - 1
    if (isNaN(idx) || idx < 0 || idx >= existing.length) {
      fail('Invalid choice.')
      process.exit(1)
    }
    return path.join(existing[idx], 'skills')
  }

  // None found — ask user
  console.log()
  warn(`.claude directory not found in default location(s):`)
  candidates.forEach(p => console.log(dim(`    ${p}`)))

  const defaultPath = candidates[0]
  const useDefault  = await confirm(`Create it at ${defaultPath}?`)
  if (useDefault) {
    fs.mkdirSync(path.join(defaultPath, 'skills'), { recursive: true })
    ok(`Created ${defaultPath}`)
    return path.join(defaultPath, 'skills')
  }

  const custom = await ask('Enter the full path to your .claude directory')
  if (!custom) {
    fail('No path provided.')
    process.exit(1)
  }
  const resolved = path.resolve(custom)
  fs.mkdirSync(path.join(resolved, 'skills'), { recursive: true })
  return path.join(resolved, 'skills')
}

// ─── gh CLI checks ───────────────────────────────────────────────────────────

function installGhHint() {
  console.log()
  warn('The `gh` CLI is required for this command.')
  if (IS_MAC)          info('Install:  brew install gh')
  else if (IS_WINDOWS) info('Install:  winget install GitHub.cli')
  else                 info('Install:  https://cli.github.com/manual/installation')
  console.log()
}

async function ensureGh() {
  const version = run('gh --version')
  if (version.status !== 0) {
    installGhHint()
    return false
  }

  const auth = run('gh auth status')
  if (auth.status !== 0) {
    console.log()
    warn('You are not logged in to GitHub.')
    info('Run:  gh auth login')
    console.log()
    const doLogin = await confirm('Run `gh auth login` now?')
    if (doLogin) {
      spawnSync('gh', ['auth', 'login'], { shell: true, stdio: 'inherit' })
      const recheck = run('gh auth status')
      if (recheck.status !== 0) {
        fail('Still not authenticated. Please run `gh auth login` manually.')
        return false
      }
      ok('Authenticated')
    } else {
      return false
    }
  }

  return true
}

// ─── Repo helpers ─────────────────────────────────────────────────────────────

async function ensureRepo() {
  const ghReady = await ensureGh()
  if (!ghReady) {
    fail('GitHub access is required. Please set up the gh CLI and try again.')
    process.exit(1)
  }

  fs.mkdirSync(path.dirname(CACHE_DIR), { recursive: true })
  if (!fs.existsSync(CACHE_DIR)) {
    info(`Cloning ${REPO_URL} ...`)
    const result = run(`git clone ${REPO_URL} "${CACHE_DIR}"`)
    if (result.status !== 0) {
      fail('Clone failed: ' + result.stderr.trim())
      process.exit(1)
    }
    ok('Repository cloned')
  } else {
    info('Pulling latest changes ...')
    const result = run('git pull --ff-only', CACHE_DIR)
    if (result.status !== 0) {
      fail('Pull failed: ' + result.stderr.trim())
      process.exit(1)
    }
    const summary = result.stdout.trim()
    if (summary === 'Already up to date.') {
      info('Already up to date')
    } else {
      ok(summary)
    }
  }
}

function availableSkills() {
  if (!fs.existsSync(SKILLS_SRC)) return []
  return fs.readdirSync(SKILLS_SRC).filter(f =>
    fs.statSync(path.join(SKILLS_SRC, f)).isDirectory()
  )
}

function installedSkills(dest) {
  if (!fs.existsSync(dest)) return []
  return fs.readdirSync(dest).filter(f =>
    fs.statSync(path.join(dest, f)).isDirectory()
  )
}

function copySkill(name, dest) {
  const src = path.join(SKILLS_SRC, name)
  const to  = path.join(dest, name)
  fs.rmSync(to, { recursive: true, force: true })
  fs.cpSync(src, to, { recursive: true })
}

function skillDesc(name) {
  const skillMd = path.join(SKILLS_SRC, name, 'SKILL.md')
  if (!fs.existsSync(skillMd)) return ''
  const lines = fs.readFileSync(skillMd, 'utf8').split('\n')
  const line  = lines.find(l => l.startsWith('description:'))
  return line ? line.replace('description:', '').trim() : ''
}

// ─── Commands ────────────────────────────────────────────────────────────────

async function cmdInstall() {
  const installAll = args[0] === '-a'
  const target     = !installAll ? args[0] : null

  if (!installAll && !target) {
    fail('Usage: d-ai install <skill-name>  |  d-ai install -a')
    process.exit(1)
  }

  console.log(bold('\nd-ai install'))
  await ensureRepo()

  const available = availableSkills()
  const dest = await resolveSkillsDest()
  fs.mkdirSync(dest, { recursive: true })

  if (installAll) {
    if (available.length === 0) { warn('No skills in repository.'); return }
    for (const name of available) {
      copySkill(name, dest)
      ok(name)
    }
    console.log(`\n  ${available.length} skill(s) installed to ${dest}\n`)
  } else {
    if (!available.includes(target)) {
      fail(`Skill "${target}" not found. Available: ${available.join(', ')}`)
      process.exit(1)
    }
    copySkill(target, dest)
    ok(`${target}  →  ${dest}${path.sep}${target}`)
    console.log(`\n  Restart Claude Code to pick up the new skill.\n`)
  }
}

async function cmdSync() {
  console.log(bold('\nd-ai sync'))
  await ensureRepo()

  const dest      = await resolveSkillsDest()
  const installed = installedSkills(dest)
  const available = availableSkills()
  const toUpdate  = installed.filter(n => available.includes(n))
  const missing   = installed.filter(n => !available.includes(n))

  if (toUpdate.length === 0) {
    info('No installed skills to update.')
    info('Use `d-ai install <skill>` to install a skill first.')
    console.log()
    return
  }

  for (const name of toUpdate) {
    copySkill(name, dest)
    ok(`${name}  updated`)
  }

  if (missing.length > 0) {
    console.log()
    for (const name of missing) warn(`${name}  (local only — not in repo, skipped)`)
  }

  console.log(`\n  ${toUpdate.length} skill(s) updated. Restart Claude Code to pick up changes.\n`)
}

async function cmdUpdate() {
  const target = args[0]
  if (!target) {
    fail('Usage: d-ai update <skill-name>')
    process.exit(1)
  }

  console.log(bold('\nd-ai update'))

  // Locate local skill
  const dest       = await resolveSkillsDest()
  const localSkill = path.join(dest, target)
  if (!fs.existsSync(localSkill)) {
    fail(`Skill "${target}" is not installed locally (looked in ${localSkill})`)
    process.exit(1)
  }

  await ensureRepo()

  const branch = `update/${target}-${Date.now()}`
  const gitBranch = run(`git checkout -b ${branch}`, CACHE_DIR)
  if (gitBranch.status !== 0) {
    fail('Failed to create branch: ' + gitBranch.stderr.trim())
    process.exit(1)
  }
  info(`Branch: ${branch}`)

  const destSkill = path.join(SKILLS_SRC, target)
  fs.rmSync(destSkill, { recursive: true, force: true })
  fs.cpSync(localSkill, destSkill, { recursive: true })
  ok(`Copied ${localSkill}  →  ${destSkill}`)

  run('git add -A', CACHE_DIR)
  const commit = run(`git commit -m "update(${target}): sync local changes"`, CACHE_DIR)
  if (commit.status !== 0) {
    if (commit.stdout.includes('nothing to commit') || commit.stderr.includes('nothing to commit')) {
      warn('No changes detected — local skill is identical to the repo version.')
      run('git checkout main', CACHE_DIR)
      console.log()
      return
    }
    fail('Commit failed: ' + commit.stderr.trim())
    run('git checkout main', CACHE_DIR)
    process.exit(1)
  }
  ok('Changes committed')

  const push = run(`git push origin ${branch}`, CACHE_DIR)
  if (push.status !== 0) {
    fail('Push failed: ' + push.stderr.trim())
    run('git checkout main', CACHE_DIR)
    process.exit(1)
  }
  ok(`Branch pushed: ${branch}`)

  const prTitle = `update(${target}): sync local changes`
  const prBody  = `Local skill changes for \`${target}\` submitted via \`d-ai update\`.`
  const pr = run(
    `gh pr create --repo MaistoMyletojai/ai-skills --base main --head "${branch}" --title "${prTitle}" --body "${prBody}"`,
    CACHE_DIR
  )
  if (pr.status === 0) {
    ok(`PR created: ${pr.stdout.trim()}`)
  } else {
    warn('PR creation failed. Open this URL to create manually:')
    info(`https://github.com/MaistoMyletojai/ai-skills/compare/main...${encodeURIComponent(branch)}?expand=1`)
  }

  run('git checkout main', CACHE_DIR)
  console.log()
}

async function cmdRemove() {
  const target = args[0]
  if (!target) {
    fail('Usage: d-ai remove <skill-name>')
    process.exit(1)
  }

  console.log(bold('\nd-ai remove'))

  const dest = await resolveSkillsDest()
  const to   = path.join(dest, target)
  if (!fs.existsSync(to)) {
    fail(`Skill "${target}" is not installed.`)
    process.exit(1)
  }

  fs.rmSync(to, { recursive: true, force: true })
  ok(`${target}  removed from ${dest}`)
  console.log()
}

async function cmdList() {
  console.log(bold('\nd-ai list'))
  await ensureRepo()

  const available = availableSkills()
  if (available.length === 0) { info('No skills in repository yet'); return }

  const dest      = await resolveSkillsDest()
  const installed = installedSkills(dest)

  console.log()
  for (const name of available) {
    const desc = skillDesc(name)
    const tag  = installed.includes(name)
      ? '\x1b[32m[installed]\x1b[0m'
      : '\x1b[90m[not installed]\x1b[0m'
    console.log(`  ${bold(name.padEnd(20))} ${tag}${desc ? '  ' + dim(desc) : ''}`)
  }
  console.log()
}

async function cmdStatus() {
  console.log(bold('\nd-ai status'))

  const dest      = await resolveSkillsDest()
  const installed = installedSkills(dest)

  if (!fs.existsSync(CACHE_DIR)) {
    info('Remote repo not cached — run `d-ai list` or `d-ai sync` first')
    if (installed.length > 0) {
      console.log()
      for (const name of installed) console.log(`  ${name}  \x1b[32m[installed]\x1b[0m`)
    }
    console.log()
    return
  }

  const available = availableSkills()
  console.log()
  console.log(`  Platform  : ${IS_MAC ? 'macOS' : IS_WINDOWS ? 'Windows' : 'Linux'}`)
  console.log(`  .claude   : ${path.dirname(dest)}`)
  console.log(`  Remote    : ${available.length} skill(s)`)
  console.log(`  Installed : ${installed.length} skill(s)`)
  console.log()

  for (const name of available) {
    const tag = installed.includes(name)
      ? '\x1b[32m✓ installed\x1b[0m'
      : '\x1b[90m· not installed\x1b[0m'
    console.log(`  ${name.padEnd(24)} ${tag}`)
  }

  for (const name of installed.filter(n => !available.includes(n))) {
    console.log(`  ${name.padEnd(24)} \x1b[90m· local only\x1b[0m`)
  }
  console.log()
}

function cmdHelp() {
  console.log(`
${bold('d-ai')} — DSERVE AI skill manager

${bold('USAGE')}
  d-ai <command> [options]

${bold('COMMANDS')}
  install <skill>   Install a skill from the repo
  install -a        Install all skills from the repo
  sync              Pull latest and update already-installed skills
  update <skill>    Push your local changes to a PR in the repo
  remove <skill>    Remove an installed skill
  list              Show all available skills in the repo
  status            Show installed skills and environment info
  help              Show this help

${bold('EXAMPLES')}
  d-ai install qa-ticket    Install the qa-ticket skill
  d-ai install -a           Install every skill in the repo
  d-ai sync                 Update all currently installed skills
  d-ai update qa-ticket     Open a PR with your local changes to qa-ticket
  d-ai remove qa-ticket     Uninstall a skill
  d-ai list                 Browse available skills
  d-ai status               Check what is installed

${bold('REQUIREMENTS')}
  git   — must be on PATH
  gh    — GitHub CLI (only needed for d-ai update)

${bold('REPO')}
  ${REPO_URL}
`)
}

// ─── Main ────────────────────────────────────────────────────────────────────

;(async () => {
  switch (command) {
    case 'install': await cmdInstall(); break
    case 'sync':    await cmdSync();    break
    case 'update':  await cmdUpdate();  break
    case 'remove':  await cmdRemove();  break
    case 'list':    await cmdList();    break
    case 'status':  await cmdStatus();  break
    case 'help':
    case '--help':
    case '-h':
    case undefined: cmdHelp(); break
    default:
      fail(`Unknown command: ${command}`)
      console.log('  Run `d-ai help` for usage.\n')
      process.exit(1)
  }
})()
