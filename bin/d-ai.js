#!/usr/bin/env node
'use strict'

const { spawnSync } = require('child_process')
const fs = require('fs')
const path = require('path')
const os = require('os')

const REPO_URL = 'https://github.com/MaistoMyletojai/ai-skills.git'
const CACHE_DIR = path.join(os.homedir(), '.d-ai', 'repo')
const SKILLS_SRC = path.join(CACHE_DIR, 'skills')
const SKILLS_DEST = path.join(os.homedir(), '.claude', 'skills')

const [, , command, ...args] = process.argv

// ─── Helpers ────────────────────────────────────────────────────────────────

function run(cmd, cwd) {
  return spawnSync(cmd, { shell: true, cwd, encoding: 'utf8' })
}

function ok(msg)   { console.log(`  \x1b[32m✓\x1b[0m ${msg}`) }
function err(msg)  { console.error(`  \x1b[31m✗\x1b[0m ${msg}`) }
function info(msg) { console.log(`  \x1b[36m·\x1b[0m ${msg}`) }
function bold(msg) { return `\x1b[1m${msg}\x1b[0m` }
function warn(msg) { console.log(`  \x1b[33m!\x1b[0m ${msg}`) }

function ensureRepo() {
  fs.mkdirSync(path.dirname(CACHE_DIR), { recursive: true })
  if (!fs.existsSync(CACHE_DIR)) {
    info(`Cloning ${REPO_URL} ...`)
    const result = run(`git clone ${REPO_URL} "${CACHE_DIR}"`)
    if (result.status !== 0) {
      err('Clone failed: ' + result.stderr.trim())
      process.exit(1)
    }
    ok('Repository cloned')
  } else {
    info('Pulling latest changes ...')
    const result = run('git pull --ff-only', CACHE_DIR)
    if (result.status !== 0) {
      err('Pull failed: ' + result.stderr.trim())
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

function installedSkills() {
  if (!fs.existsSync(SKILLS_DEST)) return []
  return fs.readdirSync(SKILLS_DEST).filter(f =>
    fs.statSync(path.join(SKILLS_DEST, f)).isDirectory()
  )
}

function copySkill(name) {
  const src  = path.join(SKILLS_SRC, name)
  const dest = path.join(SKILLS_DEST, name)
  fs.rmSync(dest, { recursive: true, force: true })
  fs.cpSync(src, dest, { recursive: true })
}

function skillDesc(name) {
  const skillMd = path.join(SKILLS_SRC, name, 'SKILL.md')
  if (!fs.existsSync(skillMd)) return ''
  const lines = fs.readFileSync(skillMd, 'utf8').split('\n')
  const descLine = lines.find(l => l.startsWith('description:'))
  return descLine ? descLine.replace('description:', '').trim() : ''
}

// ─── Commands ────────────────────────────────────────────────────────────────

function cmdInstall() {
  const installAll = args[0] === '-a'
  const target = !installAll ? args[0] : null

  if (!installAll && !target) {
    err('Usage: d-ai install <skill-name>  |  d-ai install -a')
    process.exit(1)
  }

  console.log(bold('\nd-ai install'))
  ensureRepo()

  const available = availableSkills()

  if (installAll) {
    if (available.length === 0) {
      warn('No skills found in repository')
      return
    }
    fs.mkdirSync(SKILLS_DEST, { recursive: true })
    for (const name of available) {
      copySkill(name)
      ok(`${name}`)
    }
    console.log(`\n  ${available.length} skill(s) installed to ${SKILLS_DEST}\n`)
  } else {
    if (!available.includes(target)) {
      err(`Skill "${target}" not found in repo. Available: ${available.join(', ')}`)
      process.exit(1)
    }
    fs.mkdirSync(SKILLS_DEST, { recursive: true })
    copySkill(target)
    ok(`${target}  →  ${SKILLS_DEST}/${target}`)
    console.log(`\n  Restart Claude Code to pick up the new skill.\n`)
  }
}

function cmdSync() {
  console.log(bold('\nd-ai sync'))
  ensureRepo()

  const installed = installedSkills()
  const available = availableSkills()

  // Only update skills that are already installed locally
  const toUpdate = installed.filter(n => available.includes(n))
  const missing  = installed.filter(n => !available.includes(n))

  if (toUpdate.length === 0) {
    info('No installed skills to update.')
    info('Use `d-ai install <skill>` to install a skill first.')
    console.log()
    return
  }

  for (const name of toUpdate) {
    copySkill(name)
    ok(`${name}  updated`)
  }

  if (missing.length > 0) {
    console.log()
    for (const name of missing) {
      warn(`${name}  (installed locally but not found in repo — skipped)`)
    }
  }

  console.log(`\n  ${toUpdate.length} skill(s) updated. Restart Claude Code to pick up changes.\n`)
}

function cmdRemove() {
  const target = args[0]
  if (!target) {
    err('Usage: d-ai remove <skill-name>')
    process.exit(1)
  }

  console.log(bold('\nd-ai remove'))

  const dest = path.join(SKILLS_DEST, target)
  if (!fs.existsSync(dest)) {
    err(`Skill "${target}" is not installed.`)
    process.exit(1)
  }

  fs.rmSync(dest, { recursive: true, force: true })
  ok(`${target}  removed from ${SKILLS_DEST}`)
  console.log()
}

function cmdUpdate() {
  const target = args[0]
  if (!target) {
    err('Usage: d-ai update <skill-name>')
    process.exit(1)
  }

  console.log(bold('\nd-ai update'))

  // 1. Skill must be installed locally
  const localSkill = path.join(SKILLS_DEST, target)
  if (!fs.existsSync(localSkill)) {
    err(`Skill "${target}" is not installed locally (looked in ${localSkill})`)
    process.exit(1)
  }

  // 2. Ensure repo is cloned and up to date
  ensureRepo()

  // 3. Create a new branch
  const branch = `update/${target}-${Date.now()}`
  const gitBranch = run(`git checkout -b ${branch}`, CACHE_DIR)
  if (gitBranch.status !== 0) {
    err('Failed to create branch: ' + gitBranch.stderr.trim())
    process.exit(1)
  }
  info(`Branch: ${branch}`)

  // 4. Copy local skill into the repo
  const destSkill = path.join(SKILLS_SRC, target)
  fs.rmSync(destSkill, { recursive: true, force: true })
  fs.cpSync(localSkill, destSkill, { recursive: true })
  ok(`Copied ${localSkill}  →  ${destSkill}`)

  // 5. Commit
  run('git add -A', CACHE_DIR)
  const commit = run(`git commit -m "update(${target}): sync local changes"`, CACHE_DIR)
  if (commit.status !== 0) {
    // Check if there's nothing to commit
    if (commit.stdout.includes('nothing to commit')) {
      warn('No changes detected — local skill is identical to the repo version.')
      run('git checkout main', CACHE_DIR)
      console.log()
      return
    }
    err('Commit failed: ' + commit.stderr.trim())
    run('git checkout main', CACHE_DIR)
    process.exit(1)
  }
  ok('Changes committed')

  // 6. Push branch
  const push = run(`git push origin ${branch}`, CACHE_DIR)
  if (push.status !== 0) {
    err('Push failed: ' + push.stderr.trim())
    run('git checkout main', CACHE_DIR)
    process.exit(1)
  }
  ok(`Branch pushed: ${branch}`)

  // 7. Create PR — prefer `gh` CLI, fall back to browser URL
  const ghCheck = run('gh --version')
  let prUrl = null

  if (ghCheck.status === 0) {
    const prTitle = `update(${target}): sync local changes`
    const prBody  = `Local skill changes for \`${target}\` submitted via \`d-ai update\`.`
    const pr = run(
      `gh pr create --repo MaistoMyletojai/ai-skills --base main --head ${branch} --title "${prTitle}" --body "${prBody}"`,
      CACHE_DIR
    )
    if (pr.status === 0) {
      prUrl = pr.stdout.trim()
      ok(`PR created: ${prUrl}`)
    } else {
      warn('gh pr create failed — open the URL below to create manually')
    }
  }

  if (!prUrl) {
    const fallbackUrl = `https://github.com/MaistoMyletojai/ai-skills/compare/main...${encodeURIComponent(branch)}?expand=1`
    info(`Open to create PR: ${fallbackUrl}`)
  }

  // 8. Return to main in the cached repo
  run('git checkout main', CACHE_DIR)
  console.log()
}

function cmdList() {
  console.log(bold('\nd-ai list'))
  ensureRepo()

  const available = availableSkills()
  if (available.length === 0) {
    info('No skills in repository yet')
    return
  }

  console.log()
  for (const name of available) {
    const desc = skillDesc(name)
    const installed = fs.existsSync(path.join(SKILLS_DEST, name))
    const tag = installed ? '\x1b[32m[installed]\x1b[0m' : '\x1b[90m[not installed]\x1b[0m'
    console.log(`  ${bold(name.padEnd(20))} ${tag}${desc ? '  ' + desc : ''}`)
  }
  console.log()
}

function cmdStatus() {
  console.log(bold('\nd-ai status'))

  const installed = installedSkills()

  if (!fs.existsSync(CACHE_DIR)) {
    info('Remote repo not cached — run `d-ai sync` or `d-ai list` first')
    if (installed.length > 0) {
      console.log()
      for (const name of installed) console.log(`  ${name}  \x1b[32m[installed]\x1b[0m`)
    }
    console.log()
    return
  }

  const available = availableSkills()
  console.log()
  console.log(`  Remote  : ${available.length} skill(s)`)
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
  status            Show installed skills (no network)
  help              Show this help

${bold('EXAMPLES')}
  d-ai install qa-ticket    Install the qa-ticket skill
  d-ai install -a           Install every skill in the repo
  d-ai sync                 Update all currently installed skills
  d-ai update qa-ticket     Open a PR with your local changes to qa-ticket
  d-ai remove qa-ticket     Uninstall a skill
  d-ai list                 Browse available skills
  d-ai status               Check what is installed

${bold('PATHS')}
  Skills installed to : ~/.claude/skills/
  Repo cached at      : ~/.d-ai/repo/

${bold('REPO')}
  ${REPO_URL}
`)
}

// ─── Router ──────────────────────────────────────────────────────────────────

switch (command) {
  case 'install': cmdInstall(); break
  case 'sync':    cmdSync();    break
  case 'update':  cmdUpdate();  break
  case 'remove':  cmdRemove();  break
  case 'list':    cmdList();    break
  case 'status':  cmdStatus();  break
  case 'help':
  case '--help':
  case '-h':
  case undefined: cmdHelp(); break
  default:
    err(`Unknown command: ${command}`)
    console.log('  Run `d-ai help` for usage.\n')
    process.exit(1)
}
