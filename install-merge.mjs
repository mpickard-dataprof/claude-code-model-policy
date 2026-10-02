#!/usr/bin/env node
// Merge the model-policy hooks into one config dir's settings.json.
// Idempotent: re-running makes no further change. Existing hooks are preserved.
//
// usage: node install-merge.mjs <config-dir> <hooks-dir>

import { readFileSync, writeFileSync, copyFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const [configDir, hooksDir] = process.argv.slice(2);
if (!configDir || !hooksDir) {
  console.error('usage: install-merge.mjs <config-dir> <hooks-dir>');
  process.exit(2);
}

const settingsPath = join(configDir, 'settings.json');
const RUNNER = join(hooksDir, 'run.sh');

// Each entry: [event, matcher | null, script]
const WANTED = [
  ['SessionStart', null, join(hooksDir, 'brief.mjs')],
  ['PreToolUse', 'Agent|Workflow|Bash', join(hooksDir, 'gate.mjs')],
  ['SubagentStop', null, join(hooksDir, 'log.mjs')],
];

// Hooks are invoked through run.sh so node is located the same way on every
// machine, rather than depending on the launching shell's PATH.
const commandFor = (script) => `"${RUNNER}" "${script}"`;

let settings = {};
if (existsSync(settingsPath)) {
  try {
    settings = JSON.parse(readFileSync(settingsPath, 'utf8'));
  } catch (e) {
    console.error(`  ! ${settingsPath} is not valid JSON — skipping this dir (${e.message})`);
    process.exit(1);
  }
} else {
  console.error(`  ! no settings.json in ${configDir} — creating one`);
}

if (typeof settings !== 'object' || settings === null || Array.isArray(settings)) {
  console.error(`  ! ${settingsPath} is not a JSON object — skipping`);
  process.exit(1);
}

settings.hooks = settings.hooks && typeof settings.hooks === 'object' ? settings.hooks : {};

let added = 0;
let present = 0;
let migrated = 0;

for (const [event, matcher, script] of WANTED) {
  const command = commandFor(script);
  const list = Array.isArray(settings.hooks[event]) ? settings.hooks[event] : [];

  // Match on the script path, so a registration written by an older version of
  // this installer (or hand-edited) is recognised and upgraded in place rather
  // than duplicated.
  let found = false;
  for (let gi = 0; gi < list.length; gi++) {
    const group = list[gi];
    if (!Array.isArray(group?.hooks)) continue;
    for (const h of group.hooks) {
      if (typeof h?.command !== 'string' || !h.command.includes(script)) continue;
      found = true;
      if (h.command === command) { present++; } else { h.command = command; migrated++; }
      // Do not widen a group shared with a user's hook. Older installers rewrote
      // the whole group's matcher, silently changing which calls that hook sees.
      const want = matcher ?? undefined;
      if ((group.matcher ?? undefined) !== want) {
        const others = group.hooks.some((x) => x !== h && !String(x?.command || '').includes(script));
        if (others) {
          group.hooks = group.hooks.filter((x) => x !== h);
          const entry = { hooks: [h] };
          if (want !== undefined) entry.matcher = want;
          list.push(entry);
        } else if (want === undefined) delete group.matcher; else group.matcher = want;
        migrated++;
      }
    }
  }

  settings.hooks[event] = list;
  if (found) continue;

  const entry = { hooks: [{ type: 'command', command }] };
  if (matcher) entry.matcher = matcher;
  list.push(entry);
  added++;
}

if (added === 0 && migrated === 0) {
  console.log(`  = ${configDir}  already registered (${present}/3)`);
  process.exit(0);
}

if (existsSync(settingsPath)) {
  copyFileSync(settingsPath, `${settingsPath}.model-policy.bak`);
}
writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
const bits = [];
if (added) bits.push(`registered ${added}`);
if (migrated) bits.push(`upgraded ${migrated} to the node launcher`);
if (present) bits.push(`${present} unchanged`);
console.log(`  + ${configDir}  ${bits.join(', ')}`);
