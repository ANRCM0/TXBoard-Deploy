#!/usr/bin/env node
// Dependency-free local Markdown relative-path validation.
// Scope intentionally stays on public-facing docs; external URLs, anchor IDs,
// reference-style links and generated paths require human review.
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, extname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const inputs = ['README.md', 'docs'];
const files = [];
const errors = [];
let checked = 0;

function collect(relative) {
  const abs = resolve(root, relative);
  if (!existsSync(abs)) {
    errors.push(`Missing documentation input: ${relative}`);
    return;
  }
  if (statSync(abs).isDirectory()) {
    for (const child of readdirSync(abs)) {
      collect(join(relative, child));
    }
  } else if (extname(abs) === '.md') {
    files.push(abs);
  }
}

for (const entry of inputs) collect(entry);

for (const file of files) {
  const source = readFileSync(file, 'utf8');
  const lines = source.split(/\r?\n/);
  let fenced = false;
  let fenceChar = '';
  let fenceLength = 0;

  lines.forEach((line, i) => {
    const opening = line.match(/^\s*(```+|~~~+)/);
    if (opening) {
      const marker = opening[1];
      if (!fenced) {
        fenced = true;
        fenceChar = marker[0];
        fenceLength = marker.length;
      } else if (marker[0] === fenceChar && marker.length >= fenceLength) {
        fenced = false;
      }
      return;
    }
    if (fenced) return;

    // Remove inline code to avoid treating sample Markdown as real links.
    const prose = line.replace(/`[^\x60\n]+`/g, '');
    for (const match of prose.matchAll(/!?\[[^\]\n]*\]\(([^)]+)\)/g)) {
      let target = match[1].trim();
      if (target.startsWith('<')) {
        const pos = target.indexOf('>');
        target = pos > -1 ? target.slice(1, pos) : target;
      } else {
        target = target.split(/\s+["']/)[0];
      }
      if (!target || /^(?:[a-z][a-z0-9+.-]*:|#|\/\/)/i.test(target) || target.startsWith('/')) continue;

      const noFragment = target.split('#')[0].split('?')[0];
      if (!noFragment) continue;
      let decoded;
      try { decoded = decodeURIComponent(noFragment); }
      catch {
        errors.push(`${file}:${i + 1}: invalid URL encoding: ${target}`);
        continue;
      }
      const dest = resolve(dirname(file), decoded);
      if (existsSync(dest)) {
        checked += 1;
        continue;
      }
      const fallback = join(dest, 'README.md');
      if (existsSync(fallback)) {
        checked += 1;
        continue;
      }
      errors.push(`${file.slice(root.length + 1)}:${i + 1}: broken link ${target}`);
    }
  });
}

if (errors.length) {
  for (const error of errors) console.error(error);
  console.error(`Documentation check failed: ${errors.length} issue(s).`);
  process.exitCode = 1;
} else {
  console.log(`Documentation paths OK: ${files.length} Markdown files, ${checked} relative links checked.`);
}
