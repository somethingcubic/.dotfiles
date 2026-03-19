#!/usr/bin/env node

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_FILE = fileURLToPath(import.meta.url);
const SCRIPT_DIR = path.dirname(SCRIPT_FILE);
const ROOT_DIR = path.resolve(SCRIPT_DIR, '..');
const DEFAULT_MANIFEST = path.join(ROOT_DIR, 'skills', 'sync-sources.json');
const DEFAULT_LOCKFILE = path.join(ROOT_DIR, 'skills', 'sync-lock.json');

function parseArgs(argv) {
  const options = {
    manifest: DEFAULT_MANIFEST,
    lockfile: DEFAULT_LOCKFILE,
    only: null,
    validate: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];

    if (arg === '--validate') {
      options.validate = true;
      continue;
    }

    if (arg === '--manifest') {
      options.manifest = resolveCliPath(argv[++i], '--manifest');
      continue;
    }

    if (arg === '--lockfile') {
      options.lockfile = resolveCliPath(argv[++i], '--lockfile');
      continue;
    }

    if (arg === '--only') {
      const value = argv[++i];
      if (!value) {
        throw new Error('Missing value for --only');
      }
      options.only = new Set(value.split(',').map(item => item.trim()).filter(Boolean));
      continue;
    }

    throw new Error(`Unknown argument: ${arg}`);
  }

  return options;
}

function resolveCliPath(value, flag) {
  if (!value) {
    throw new Error(`Missing value for ${flag}`);
  }
  return path.isAbsolute(value) ? value : path.resolve(ROOT_DIR, value);
}

function repoUrl(repo) {
  return repo.includes('://') ? repo : `https://github.com/${repo}.git`;
}

function run(command, args, options = {}) {
  try {
    return execFileSync(command, args, {
      cwd: options.cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
  } catch (error) {
    const stderr = error.stderr?.toString().trim();
    const stdout = error.stdout?.toString().trim();
    const detail = stderr || stdout || error.message;
    throw new Error(`Command failed: ${command} ${args.join(' ')}\n${detail}`);
  }
}

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (error) {
    throw new Error(`Failed to read JSON: ${filePath}\n${error.message}`);
  }
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function loadExistingLockfile(lockfilePath) {
  if (!fs.existsSync(lockfilePath)) {
    return new Map();
  }

  const data = readJson(lockfilePath);
  const sources = Array.isArray(data?.sources) ? data.sources : [];
  return new Map(sources
    .filter(entry => entry && typeof entry.name === 'string' && entry.name.trim())
    .map(entry => [entry.name.trim(), entry]));
}

function ensureRelativePath(label, value) {
  if (typeof value !== 'string' || !value.trim()) {
    throw new Error(`${label} must be a non-empty string`);
  }

  const normalized = path.posix.normalize(value.trim());
  if (path.posix.isAbsolute(normalized) || normalized === '.' || normalized === '..' || normalized.startsWith('../')) {
    throw new Error(`${label} must be a safe relative path: ${value}`);
  }

  return normalized;
}

function ensureProjectPath(relativePath) {
  const absolutePath = path.resolve(ROOT_DIR, relativePath);
  const relativeToRoot = path.relative(ROOT_DIR, absolutePath);
  if (relativeToRoot === '..' || relativeToRoot.startsWith(`..${path.sep}`)) {
    throw new Error(`Path escapes repository root: ${relativePath}`);
  }
  return absolutePath;
}

function normalizeManifest(manifestPath) {
  if (!fs.existsSync(manifestPath)) {
    throw new Error(`Manifest not found: ${manifestPath}`);
  }

  const data = readJson(manifestPath);
  const sources = Array.isArray(data) ? data : data.sources;
  if (!Array.isArray(sources) || sources.length === 0) {
    throw new Error(`Manifest must contain a non-empty sources array: ${manifestPath}`);
  }

  const seenNames = new Set();
  const seenTargets = new Set();

  return sources.map((entry, index) => {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
      throw new Error(`Manifest entry #${index + 1} must be an object`);
    }

    const name = typeof entry.name === 'string' ? entry.name.trim() : '';
    const repo = typeof entry.repo === 'string' ? entry.repo.trim() : '';
    const ref = typeof entry.ref === 'string' ? entry.ref.trim() : '';
    const source = ensureRelativePath(`sources[${index}].source`, entry.source);
    const target = ensureRelativePath(`sources[${index}].target`, entry.target);

    if (!name) {
      throw new Error(`sources[${index}].name must be a non-empty string`);
    }
    if (!repo) {
      throw new Error(`sources[${index}].repo must be a non-empty string`);
    }
    if (!ref) {
      throw new Error(`sources[${index}].ref must be a non-empty string`);
    }
    if (seenNames.has(name)) {
      throw new Error(`Duplicate source name: ${name}`);
    }
    if (seenTargets.has(target)) {
      throw new Error(`Duplicate target path: ${target}`);
    }

    seenNames.add(name);
    seenTargets.add(target);

    return { name, repo, ref, source, target };
  });
}

function filterSources(sources, onlyNames) {
  if (!onlyNames || onlyNames.size === 0) {
    return sources;
  }

  const filtered = sources.filter(source => onlyNames.has(source.name));
  const found = new Set(filtered.map(source => source.name));
  const missing = [...onlyNames].filter(name => !found.has(name));
  if (missing.length > 0) {
    throw new Error(`Unknown source name(s): ${missing.join(', ')}`);
  }
  return filtered;
}

function groupSources(sources) {
  const groups = new Map();

  for (const source of sources) {
    const key = `${source.repo}@@${source.ref}`;
    const group = groups.get(key) || { repo: source.repo, ref: source.ref, sources: [] };
    group.sources.push(source);
    groups.set(key, group);
  }

  return [...groups.values()];
}

function checkoutGroup(group, tempRoot) {
  const slug = `${group.repo}-${group.ref}`.replace(/[^a-zA-Z0-9._-]+/g, '-');
  const checkoutDir = path.join(tempRoot, slug);

  run('git', [
    'clone',
    '--quiet',
    '--depth', '1',
    '--filter=blob:none',
    '--sparse',
    '--branch', group.ref,
    repoUrl(group.repo),
    checkoutDir,
  ]);

  run('git', [
    '-C', checkoutDir,
    'sparse-checkout',
    'set',
    '--no-cone',
    ...group.sources.map(source => source.source),
  ]);

  return {
    checkoutDir,
    commit: run('git', ['-C', checkoutDir, 'rev-parse', 'HEAD']),
  };
}

function copyEntry(sourcePath, targetPath) {
  const stat = fs.statSync(sourcePath);
  fs.rmSync(targetPath, { recursive: true, force: true });
  fs.mkdirSync(path.dirname(targetPath), { recursive: true });

  if (stat.isDirectory()) {
    fs.cpSync(sourcePath, targetPath, { recursive: true });
    return;
  }

  fs.copyFileSync(sourcePath, targetPath);
}

function syncSource(entry, checkoutDir) {
  const sourcePath = path.join(checkoutDir, ...entry.source.split('/'));
  const targetPath = ensureProjectPath(entry.target);

  if (!fs.existsSync(sourcePath)) {
    throw new Error(`Source path not found in upstream repo: ${entry.repo}@${entry.ref}:${entry.source}`);
  }

  copyEntry(sourcePath, targetPath);
}

function buildLockfile(entries) {
  return {
    version: '1.0.0',
    generatedAt: new Date().toISOString(),
    sources: entries.map(entry => ({
      name: entry.name,
      repo: entry.repo,
      ref: entry.ref,
      source: entry.source,
      target: entry.target,
      commit: entry.commit,
    })),
  };
}

function mergeLockEntries(manifestSources, existingEntries, syncedEntries) {
  const syncedByName = new Map(syncedEntries.map(entry => [entry.name, entry]));

  return manifestSources.map(source => {
    if (syncedByName.has(source.name)) {
      return syncedByName.get(source.name);
    }

    const existing = existingEntries.get(source.name);
    if (existing) {
      return {
        ...source,
        commit: existing.commit,
      };
    }

    throw new Error(`Lockfile is missing commit for unsynced source: ${source.name}. Run a full sync without --only first.`);
  });
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const manifestSources = normalizeManifest(options.manifest);
  const sources = filterSources(manifestSources, options.only);

  if (options.validate) {
    console.log(`Validated ${manifestSources.length} mirrored skill source(s).`);
    return;
  }

  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'dotfiles-skill-sync-'));
  const existingEntries = loadExistingLockfile(options.lockfile);
  const synced = [];

  try {
    for (const group of groupSources(sources)) {
      const { checkoutDir, commit } = checkoutGroup(group, tempRoot);

      for (const source of group.sources) {
        syncSource(source, checkoutDir);
        synced.push({ ...source, commit });
        console.log(`Synced ${source.name}: ${source.repo}@${commit.slice(0, 12)} -> ${source.target}`);
      }
    }

    const lockEntries = options.only
      ? mergeLockEntries(manifestSources, existingEntries, synced)
      : synced;

    writeJson(options.lockfile, buildLockfile(lockEntries));
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
}

try {
  main();
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
