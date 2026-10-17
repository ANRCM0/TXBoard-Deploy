import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const checker = resolve(dirname(fileURLToPath(import.meta.url)), '../check-docs.mjs');
function fixture(t, files) {
  const root = mkdtempSync(join(tmpdir(), 'deploy-docs-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const [name, content] of Object.entries(files)) {
    const path = join(root, name);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, content);
  }
  return (...args) => spawnSync(process.execPath, [checker, '--root', root, ...args], { encoding: 'utf8' });
}

test('empty documentation set explicitly skips validation', (t) => {
  const run = fixture(t, {});
  assert.equal(run('--has-docs').stdout.trim(), 'false');
  const result = run();
  assert.equal(result.status, 0);
  assert.match(result.stdout, /^SKIP:/);
  assert.doesNotMatch(result.stdout, /paths OK/);
});

test('partial documentation is discovered without root or node README', (t) => {
  const run = fixture(t, { 'docs/topic.md': '# Topic\n' });
  assert.equal(run('--has-docs').stdout.trim(), 'true');
  assert.equal(run().status, 0);
  assert.match(run().stdout, /1 Markdown files/);
});

test('broken first-party links fail even outside the old input directories', (t) => {
  const run = fixture(t, { 'gateway/guide.md': '[missing](missing.md)\n' });
  assert.equal(run('--has-docs').stdout.trim(), 'true');
  const result = run();
  assert.equal(result.status, 1);
  assert.match(result.stderr, /broken link missing.md/);
});

test('valid local links pass and third-party documentation is excluded', (t) => {
  const run = fixture(t, {
    'docs/topic.md': '[target](../gateway/guide.md)\n',
    'gateway/guide.md': '# Guide\n',
    'node_modules/sample/README.md': '[broken](missing.md)\n',
  });
  const result = run();
  assert.equal(result.status, 0);
  assert.match(result.stdout, /2 Markdown files, 1 relative links checked/);
});
