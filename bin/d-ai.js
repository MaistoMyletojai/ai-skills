#!/usr/bin/env node
'use strict'

const { execSync, spawnSync } = require('child_process')
const fs = require('fs')
const path = require('path')
const os = require('os')

const REPO_URL = 'https://github.com/MaistoMyletojai/ai-skills.git'
const CACHE_DIR = path.join(os.homedir(), '.d-ai', 'repo')
const SKILLS_SRC = path.join(CACHE_DIR, 'skills')
const SKILLS_DEST = path.join(os.homedir(), '.claude', 'skills')

const [, , command, ...args] = process.argv

const COMMANDS = {
  sync:   'Pull latest skills from GitHub and install to ~/.claude/skills/',
  list:   'List all available skills in the remote repo',
  status: 'Show which skills are installed and whether they are up to date',
  help:   'Show this help message',
}

// ─── Helpers ────────────────────────────────────────────────────────────────

function run(cmd, cwd) {
  return spawnSync(cmd, { shell: true, cwd, encoding: 'utf8' })
}

function ok(msg)   { console.log(`  \x1b[32m✓\x1b[0m ${msg}`) }
function err(msg)  { console.error(`  \x1b[31m✗\x1b[0m ${msg}`) }
function info(msg) { console.log(`  \x1b[36m·\x1b[0m ${msg}`) }
function bold(msg) { return `\x1b[1m${msg}\x1b[0m` }

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

// ─── Commands ────────────────────────────────────────────────────────────────

function cmdSync() {
  const target = args[0]  // optional: d-ai sync qa-ticket

  console.log(bold('\nd-ai sync'))
  ensureRepo()

  const all = availableSkills()
  if (all.length === 0) {
    err('No skills found in repository')
    process.exit(1)
  }

  const toInstall = target ? [target] : all

  if (target && !all.includes(target)) {
    err(`Skill "${target}" not found. Available: ${all.join(', ')}`)
    process.exit(1)
  }

  fs.mkdirSync(SKILLS_DEST, { recursive: true })

  for (const name of toInstall) {
    copySkill(name)
    ok(`${name}  →  ${SKILLS_DEST}/${name}`)
  }

  console.log(`\n  ${toInstall.length} skill(s) ready. Restart Claude Code to pick up changes.\n`)
}

function cmdList() {
  console.log(bold('\nd-ai list'))
  ensureRepo()

  const skills = availableSkills()
  if (skills.length === 0) {
    info('No skills in repository yet')
    return
  }

  console.log()
  for (const name of skills) {
    const skillMd = path.join(SKILLS_SRC, name, 'SKILL.md')
    let desc = ''
    if (fs.existsSync(skillMd)) {
      const lines = fs.readFileSync(skillMd, 'utf8').split('\n')
      const descLine = lines.find(l => l.startsWith('description:'))
      if (descLine) desc = descLine.replace('description:', '').trim()
    }
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
    info('Remote repo not cached yet — run `d-ai sync` first')
    if (installed.length > 0) {
      console.log()
      console.log('  Installed skills:')
      for (const name of installed) {
        console.log(`    ${name}`)
      }
    }
    console.log()
    return
  }

  const available = availableSkills()

  console.log()
  console.log(`  Remote skills  : ${available.length}`)
  console.log(`  Installed      : ${installed.length}`)
  console.log()

  for (const name of available) {
    const isInstalled = installed.includes(name)
    const tag = isInstalled ? '\x1b[32m✓ installed\x1b[0m' : '\x1b[33m· not installed\x1b[0m'
    console.log(`  ${name.padEnd(24)} ${tag}`)
  }

  const extra = installed.filter(n => !available.includes(n))
  for (const name of extra) {
    console.log(`  ${name.padEnd(24)} \x1b[90m· local only (not in repo)\x1b[0m`)
  }

  console.log()
}

function cmdHelp() {
  console.log(`
${bold('d-ai')} — DSERVE AI skill manager

${bold('USAGE')}
  d-ai <command> [options]

${bold('COMMANDS')}`)
  for (const [cmd, desc] of Object.entries(COMMANDS)) {
    console.log(`  ${cmd.padEnd(10)} ${desc}`)
  }
  console.log(`
${bold('EXAMPLES')}
  d-ai sync               Install / update all skills
  d-ai sync qa-ticket     Install / update one skill
  d-ai list               Show available skills + install status
  d-ai status             Show install status without pulling

${bold('INSTALL PATH')}
  ~/.claude/skills/   (Claude Code global skill directory)

${bold('REPO')}
  ${REPO_URL}
`)
}

// ─── Router ──────────────────────────────────────────────────────────────────

switch (command) {
  case 'sync':   cmdSync();   break
  case 'list':   cmdList();   break
  case 'status': cmdStatus(); break
  case 'help':
  case '--help':
  case '-h':
  case undefined: cmdHelp(); break
  default:
    err(`Unknown command: ${command}`)
    console.log('  Run `d-ai help` for usage.\n')
    process.exit(1)
}
