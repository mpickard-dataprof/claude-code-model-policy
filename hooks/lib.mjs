// Shared helpers for the tiered model-selection hooks.
// Every export is written to fail soft: callers must still guard, but nothing
// in here throws on malformed input.

import {
  readFileSync, writeFileSync, appendFileSync, statSync, renameSync,
  mkdirSync, readdirSync, unlinkSync, openSync, readSync, closeSync,
} from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
export const POLICY_PATH = join(ROOT, 'policy.json');

// The test suite must never touch the real ledger: it is the only record of how
// past spawns were routed and what they cost, and the tuning skill reads nothing
// else. test.sh previously deleted it outright — 267 rows of evidence lost to a
// routine `bash test.sh`.
export const LEDGER_PATH = process.env.MODEL_POLICY_LEDGER || join(ROOT, 'ledger.jsonl');
export const SESSIONS_DIR = process.env.MODEL_POLICY_SESSIONS || join(ROOT, 'sessions');

const DEFAULT_TIER_ORDER = ['haiku', 'sonnet', 'opus', 'fable'];

/** Read all of stdin as text. Resolves to '' if nothing arrives. */
export function readStdin() {
  return new Promise((resolve) => {
    let buf = '';
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      // Resolving is not enough: `.on('data')` puts stdin in flowing mode, and that
      // active handle keeps the event loop alive until the writer closes the pipe.
      // Without this the timeout below is inert and the hook hangs until Claude
      // Code's own timeout rather than the 2s intended here.
      //
      // BOTH calls are required, and pause() alone measurably does not work:
      // pause() stops the flow, unref() releases libuv's reference so the loop can
      // drain and the process can exit.
      try { process.stdin.pause(); } catch { /* ignore */ }
      try { process.stdin.unref?.(); } catch { /* ignore */ }
      resolve(buf);
    };
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (c) => { buf += c; });
    process.stdin.on('end', finish);
    process.stdin.on('error', finish);
    // Never hang a tool call on a stuck pipe.
    setTimeout(finish, 2000).unref?.();
  });
}

export function parseJson(text, fallback = null) {
  try { return JSON.parse(text); } catch { return fallback; }
}

export function loadPolicy() {
  try {
    const p = JSON.parse(readFileSync(POLICY_PATH, 'utf8'));
    if (!p || typeof p !== 'object') return null;
    if (!Array.isArray(p.tierOrder) || p.tierOrder.length === 0) p.tierOrder = DEFAULT_TIER_ORDER;
    return p;
  } catch {
    return null; // invalid or missing policy -> caller leaves the model unset
  }
}

/**
 * Map any model string Claude Code might use onto a tier name.
 * Handles aliases ("opus"), full ids ("claude-opus-5"), and the 1M suffix.
 * Returns null for 'default'/'inherit'/unknown, which means "do not clamp".
 */
export function normalizeModel(model) {
  if (typeof model !== 'string') return null;
  const m = model.toLowerCase();
  if (!m || m === 'default' || m === 'inherit') return null;
  if (m.includes('haiku')) return 'haiku';
  if (m.includes('sonnet')) return 'sonnet';
  if (m.includes('opus')) return 'opus';
  if (m.includes('fable') || m.includes('mythos')) return 'fable';
  return null;
}

export function tierIndex(tier, order) {
  const i = (order || DEFAULT_TIER_ORDER).indexOf(tier);
  return i === -1 ? null : i;
}

/** Cheaper of two tiers. Unknown/null operands are ignored rather than fatal. */
export function minTier(a, b, order) {
  const ia = tierIndex(a, order);
  const ib = tierIndex(b, order);
  if (ia === null) return b ?? a;
  if (ib === null) return a;
  return ia <= ib ? a : b;
}

function compile(patterns) {
  const out = [];
  for (const p of patterns || []) {
    try { out.push(new RegExp(p, 'i')); } catch { /* skip bad pattern, keep the rest */ }
  }
  return out;
}

/**
 * Step a tier down to the nearest one this account can actually use.
 *
 * Tiers are not universally available — `fable` in particular requires specific
 * access. Routing a spawn to a model the account cannot use fails it outright,
 * which is a fail-open violation caused purely by configuration. So any tier
 * listed in `disabledTiers` falls back to the next cheaper enabled tier.
 *
 * Returns { tier, fellBack } so the caller can record the substitution: a silent
 * fallback would make the ledger claim a tier that never ran.
 */
export function availableTier(tier, policy) {
  const disabled = Array.isArray(policy?.disabledTiers) ? policy.disabledTiers : [];
  if (!disabled.length || !disabled.includes(tier)) return { tier, fellBack: null };

  const order = policy.tierOrder || DEFAULT_TIER_ORDER;
  const i = tierIndex(tier, order);
  if (i === null) return { tier, fellBack: null };

  // Walk down to cheaper tiers first; they are always the safer substitution.
  for (let j = i - 1; j >= 0; j--) {
    if (!disabled.includes(order[j])) return { tier: order[j], fellBack: `${tier}->${order[j]}` };
  }
  // Everything cheaper is disabled too — try upward rather than return an unusable tier.
  for (let j = i + 1; j < order.length; j++) {
    if (!disabled.includes(order[j])) return { tier: order[j], fellBack: `${tier}->${order[j]}` };
  }
  return { tier, fellBack: null }; // every tier disabled: nonsense config, change nothing
}

/**
 * Resolve the tier for one Agent spawn.
 * Returns { tier, rule } where `rule` explains the decision for the ledger.
 *
 * Order: explicit tag (authoritative, no clamps)
 *        -> agentTypes table
 *        -> catch-all prompt scoring
 *        -> clamp to the agent definition's own declared model
 *        -> clamp to requested model
 *        -> clamp to session model
 */
export function resolveTier(toolInput, policy, sessionTier) {
  const order = policy.tierOrder;
  const desc = String(toolInput?.description ?? '');
  const ov = policy.overrides || {};

  // Layer 3a: explicit tags win outright. They are a deliberate cost decision,
  // so they intentionally bypass the downward clamps below.
  if (ov.cheapTag && desc.includes(ov.cheapTag)) {
    const a = availableTier(ov.cheapTier || 'haiku', policy);
    return { tier: a.tier, rule: 'tag:cheap' + (a.fellBack ? `+unavailable:${a.fellBack}` : '') };
  }
  if (ov.hardTag && desc.includes(ov.hardTag)) {
    // The commonest first-run failure: [hard] routes to fable on an account with
    // no fable access, and the spawn dies. Fall back rather than fail.
    const a = availableTier(ov.hardTier || 'opus', policy);
    return { tier: a.tier, rule: 'tag:hard' + (a.fellBack ? `+unavailable:${a.fellBack}` : '') };
  }

  const type = String(toolInput?.subagent_type ?? '');
  let tier;
  let rule;

  // Layer 1: fixed table.
  if (policy.agentTypes && Object.prototype.hasOwnProperty.call(policy.agentTypes, type)) {
    tier = policy.agentTypes[type];
    rule = `table:${type}`;
  } else {
    // Layer 2: score the prompt for catch-all agent types.
    const c = policy.catchAll || {};
    const prompt = String(toolInput?.prompt ?? '');
    const expensive = compile(c.expensive?.patterns);
    const cheap = compile(c.cheap?.patterns);
    const hitExpensive = expensive.some((re) => re.test(prompt));
    const longPrompt = prompt.length >= (c.expensive?.minChars ?? Infinity);
    const hitCheap = cheap.some((re) => re.test(prompt));
    const shortPrompt = prompt.length <= (c.cheap?.maxChars ?? 0);

    if (hitExpensive || longPrompt) {
      tier = 'opus';
      rule = hitExpensive ? 'score:expensive-verb' : 'score:long-prompt';
    } else if (hitCheap && shortPrompt) {
      tier = 'haiku';
      rule = 'score:mechanical';
    } else {
      tier = c.base || 'sonnet';
      rule = 'score:base';
    }
  }

  // Layer 3a-bis: never exceed the model the agent definition declares for itself.
  // A declared model is a deliberate tier choice by whoever wrote the agent, and
  // the per-invocation `model` we emit would otherwise silently override it.
  const declared = declaredModelFor(type);
  if (declared) {
    const clamped = minTier(tier, declared, order);
    if (clamped !== tier) rule += '+clamp:declared';
    tier = clamped;
  }

  // Layer 3b: never exceed what was explicitly requested.
  const requested = normalizeModel(toolInput?.model);
  if (requested) {
    const clamped = minTier(tier, requested, order);
    if (clamped !== tier) rule += '+clamp:requested';
    tier = clamped;
  }

  // Layer 3c: never exceed the session's own model. Without this, a config whose
  // session runs a cheap model would still see subagents routed above it.
  if (sessionTier) {
    const clamped = minTier(tier, sessionTier, order);
    if (clamped !== tier) rule += '+clamp:session';
    tier = clamped;
  }

  // Layer 3d: last word goes to what the account can actually run. A tier the user
  // has no access to would fail the spawn outright.
  const avail = availableTier(tier, policy);
  if (avail.fellBack) rule += `+unavailable:${avail.fellBack}`;
  tier = avail.tier;

  return { tier, rule };
}

/**
 * Stable key for joining a `route` entry to its `complete` entry.
 *
 * The two events share no id: PreToolUse has `tool_use_id`, SubagentStop has
 * `agent_id`. Pairing them by arrival order within a session breaks as soon as
 * agents run in parallel — which is the normal case for fan-out — so both sides
 * fingerprint the agent's prompt instead.
 */
/**
 * Blank out comments and string-literal contents in JS source.
 *
 * Heuristics that scan a workflow script for constructs must not be fooled by
 * prose. Without this, a comment reading "fan these out in parallel (one each)"
 * or an agent() prompt containing the word "parallel" trips the fan-out
 * detector and the script is denied — breaking a tool call that was fine.
 *
 * Blanking string contents also stops a `model:` mentioned inside a prompt from
 * counting as real tier coverage.
 *
 * Template literals are blanked wholesale, including any `${}` interpolations.
 * That can hide a real construct, which errs toward *not* denying — the safe
 * direction for a heuristic that can block work.
 *
 * Masked characters become spaces rather than being deleted, so the result is
 * the SAME LENGTH as the input and indexes into it map straight back to the
 * original. injectWorkflowTiers() relies on that to rewrite real call sites
 * without disturbing identical text inside a comment or a prompt string.
 */
export function stripCodeNoise(src) {
  if (typeof src !== 'string') return '';
  let out = '';
  let i = 0;
  const n = src.length;
  const blank = (count) => ' '.repeat(Math.max(0, count));
  while (i < n) {
    const c = src[i];
    const d = i + 1 < n ? src[i + 1] : '';
    if (c === '/' && d === '/') {
      const start = i;
      while (i < n && src[i] !== '\n') i++;
      out += blank(i - start);
      continue;
    }
    if (c === '/' && d === '*') {
      const start = i;
      i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i++;
      i = Math.min(n, i + 2);
      out += blank(i - start);
      continue;
    }
    if (c === '"' || c === "'" || c === '`') {
      const quote = c;
      const start = i;
      out += quote;
      i++;
      while (i < n) {
        if (src[i] === '\\') { i += 2; continue; }
        if (src[i] === quote) break;
        i++;
      }
      // Blank the contents, keep both delimiters, preserve total width.
      out += blank(Math.min(i, n) - start - 1);
      if (i < n) { out += quote; i++; }
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

/**
 * Enforce tiers on the Workflow path by rewriting the script.
 *
 * `agent()` calls inside a Workflow never pass through the Agent tool, so the
 * PreToolUse gate has nothing to intercept — measured, this is where ~95% of all
 * subagent volume lives, and an `agent()` with no model inherits the SESSION
 * model, which is often the most expensive one available. Briefing the model is
 * advice; this makes it enforcement.
 *
 * Approach: rewrite every real `agent(` call site to `__mpAgent(` and inject a
 * shim that fills in `model`/`effort` when the call did not set them. Scoring
 * happens at RUNTIME, inside the workflow, which means it sees the actual prompt
 * string even when the call site passes a template literal or a variable —
 * something no amount of static analysis of the script could recover.
 *
 * Explicit `model`/`effort` on a call are always left alone: a script that has
 * already made the cost decision outranks the policy.
 *
 * Returns { script, sites, reason }. `script` is null whenever the rewrite is not
 * provably safe, and the caller must then pass the original through untouched —
 * breaking a valid workflow is far worse than failing to optimise one.
 */
export function injectWorkflowTiers(src, policy, sessionTier) {
  if (typeof src !== 'string' || !src) return { script: null, sites: 0, reason: 'empty' };

  const masked = stripCodeNoise(src);
  if (masked.length !== src.length) return { script: null, sites: 0, reason: 'mask-desync' };

  // Insertion point: immediately after the `export const meta = {...}` literal.
  // Scripts MUST begin with it, so nothing may be injected ahead of it.
  const metaKey = masked.search(/\bexport\s+const\s+meta\s*=\s*\{/);
  if (metaKey === -1) return { script: null, sites: 0, reason: 'no-meta' };
  let depth = 0;
  let insertAt = -1;
  for (let i = masked.indexOf('{', metaKey); i < masked.length; i++) {
    if (masked[i] === '{') depth++;
    else if (masked[i] === '}') {
      depth--;
      if (depth === 0) { insertAt = i + 1; break; }
    }
  }
  if (insertAt === -1) return { script: null, sites: 0, reason: 'unbalanced-meta' };

  // Real call sites: not preceded by a word char or `.`, so `foo.agent(` and an
  // already-injected `__mpAgent(` are left alone. Both names are collected in one
  // pass so the replacements can be applied in a single ordered sweep.
  const collect = (name, replacement) => {
    const found = [];
    const re = new RegExp(`\\b${name}\\s*\\(`, 'g');
    let m;
    while ((m = re.exec(masked)) !== null) {
      if (m.index < insertAt) continue;
      const prev = m.index > 0 ? masked[m.index - 1] : '';
      if (prev === '.' || /[\w$]/.test(prev)) continue;
      found.push({ at: m.index, len: name.length, replacement });
    }
    return found;
  };
  const agentSites = collect('agent', '__mpAgent');

  // A nested workflow() runs a child script the gate never sees, and the child's
  // agent() calls cannot be reached from here. Wrapping workflow() to patch
  // globalThis.agent for the child's duration was TRIED AND MEASURED: the property
  // is writable, but the child resolves its own binding, so the child's agent ran
  // on opus while the parent's identical prompt ran on haiku. Only counted now, so
  // the ledger shows when this construct is actually in use.
  const nestedSites = collect('workflow', null);
  if (!agentSites.length) {
    return { script: null, sites: 0, nested: nestedSites.length, reason: 'no-agent-calls' };
  }

  let out = '';
  let cursor = 0;
  for (const s of agentSites) {
    out += src.slice(cursor, s.at) + s.replacement;
    cursor = s.at + s.len; // the trailing `\s*(` is preserved as written
  }
  out += src.slice(cursor);

  const c = policy.catchAll || {};
  const shimConfig = {
    base: c.base || 'sonnet',
    order: policy.tierOrder || DEFAULT_TIER_ORDER,
    ceiling: sessionTier || null,
    cheap: { maxChars: c.cheap?.maxChars ?? 0, patterns: c.cheap?.patterns || [] },
    expensive: { minChars: c.expensive?.minChars ?? Infinity, patterns: c.expensive?.patterns || [] },
    effort: policy.workflow?.effortByTier || { haiku: 'low', sonnet: 'medium', opus: 'high', fable: 'high' },
    disabled: Array.isArray(policy.disabledTiers) ? policy.disabledTiers : [],
  };

  const shim = `
/* injected by model-policy: tier every agent() that did not choose for itself */
const __mpCfg = ${JSON.stringify(shimConfig)};
const __mpRe = (ps) => ps.map((p) => { try { return new RegExp(p, 'i'); } catch { return null; } }).filter(Boolean);
const __mpExp = __mpRe(__mpCfg.expensive.patterns);
const __mpChp = __mpRe(__mpCfg.cheap.patterns);
const __mpMin = (a, b) => {
  const ia = __mpCfg.order.indexOf(a), ib = __mpCfg.order.indexOf(b);
  if (ia === -1) return b; if (ib === -1) return a;
  return ia <= ib ? a : b;
};
function __mpPick(prompt) {
  const p = String(prompt == null ? '' : prompt);
  let tier;
  if (__mpExp.some((r) => r.test(p)) || p.length >= __mpCfg.expensive.minChars) tier = 'opus';
  else if (__mpChp.some((r) => r.test(p)) && p.length <= __mpCfg.cheap.maxChars) tier = 'haiku';
  else tier = __mpCfg.base;
  if (__mpCfg.ceiling) tier = __mpMin(tier, __mpCfg.ceiling);
  /* Never hand back a tier this account cannot run - the spawn would just fail. */
  if (__mpCfg.disabled.indexOf(tier) !== -1) {
    const i = __mpCfg.order.indexOf(tier);
    let pick = null;
    for (let j = i - 1; j >= 0 && pick === null; j--) {
      if (__mpCfg.disabled.indexOf(__mpCfg.order[j]) === -1) pick = __mpCfg.order[j];
    }
    for (let j = i + 1; j < __mpCfg.order.length && pick === null; j++) {
      if (__mpCfg.disabled.indexOf(__mpCfg.order[j]) === -1) pick = __mpCfg.order[j];
    }
    if (pick) tier = pick;
  }
  return tier;
}
/* Captured BEFORE any global is patched, so __mpAgent can never recurse into itself. */
const __mpReal = agent;
function __mpAgent(prompt, opts) {
  const o = Object.assign({}, opts || {});
  if (!o.model) {
    o.model = __mpPick(prompt);
    if (!o.effort) o.effort = __mpCfg.effort[o.model];
  }
  return __mpReal(prompt, o);
}
`;

  const rewritten = out.slice(0, insertAt) + shim + out.slice(insertAt);

  // A rewrite that does not parse would fail the user's workflow outright. Verify
  // before offering it; on any doubt the caller falls back to the original.
  try {
    // eslint-disable-next-line no-new-func
    new Function(`return (async () => {${rewritten.replace(/\bexport\s+const\b/g, 'const')}\n})`);
  } catch {
    return { script: null, sites: 0, reason: 'rewrite-would-not-parse' };
  }

  return {
    script: rewritten,
    sites: agentSites.length,
    nested: nestedSites.length,
    reason: 'ok',
  };
}

/**
 * Recover the source behind a `{scriptPath}` or `{name}` Workflow invocation.
 *
 * These forms hand the tool a reference rather than source, so there is nothing
 * in `tool_input` to rewrite. Reading the file back gives the gate the same
 * enforcement it has over an inline script.
 *
 * The file is only ever READ. The rewritten source is passed inline instead, so
 * a script the user hand-authored is never modified on disk — the same rule the
 * installer follows when it refuses to clobber a user-written agent definition.
 *
 * Returns { source, path, form } or null when nothing can be resolved.
 */
const WORKFLOW_MAX_BYTES = 1024 * 1024;

export function resolveWorkflowScript(toolInput) {
  const read = (p) => {
    try {
      if (statSync(p).size > WORKFLOW_MAX_BYTES) return null;
      return readFileSync(p, 'utf8');
    } catch {
      return null;
    }
  };

  const scriptPath = typeof toolInput?.scriptPath === 'string' ? toolInput.scriptPath : '';
  if (scriptPath) {
    const source = read(scriptPath);
    return source === null ? null : { source, path: scriptPath, form: 'scriptPath' };
  }

  const name = typeof toolInput?.name === 'string' ? toolInput.name : '';
  // Reject anything that could climb out of a workflows directory.
  if (name && /^[\w.-]+$/.test(name) && !name.startsWith('.')) {
    let dirs = [];
    try {
      dirs = readdirSync(homedir())
        .filter((d) => d.startsWith('.claude'))
        .map((d) => join(homedir(), d, 'workflows'));
    } catch { /* unreadable home -> fall through */ }
    for (const dir of dirs) {
      for (const ext of ['.js', '.mjs']) {
        const p = join(dir, name + ext);
        const source = read(p);
        if (source !== null) return { source, path: p, form: 'name' };
      }
    }
  }

  return null; // built-in workflow, or a path we cannot read
}

/** Shared normalisation, so the gate and SubagentStop derive keys from the same text. */
function normalizePrompt(text) {
  if (typeof text !== 'string' || !text) return null;
  return text.replace(/\s+/g, ' ').trim().toLowerCase() || null;
}

export function promptFingerprint(text) {
  const n = normalizePrompt(text);
  return n ? n.slice(0, 100) : null;
}

/**
 * Collision-resistant join key for one spawn.
 *
 * `promptFingerprint` keeps only the first 100 characters, which is not enough to
 * tell apart the agents of a fan-out: they share a preamble and differ only later,
 * in the task number or file path. Measured over 1,586 real ledger rows, 122
 * fingerprints repeated inside a single session and one was reused 11 ways, so
 * joining a routing decision to its outcome on the fingerprint alone can pair the
 * wrong two rows.
 *
 * Hashing the WHOLE prompt separates those. It also stores no prompt text, unlike
 * the fingerprint it supplements — see "What it records" in the README.
 *
 * The fingerprint is deliberately kept alongside it. This hash is exact, so it
 * only joins when both hooks see byte-identical prompts; the gate reads the tool
 * input while SubagentStop recovers the prompt from the subagent's transcript, and
 * if those ever diverge the fingerprint still pairs them approximately. Consumers
 * should try `prompt_sha` first and fall back.
 */
export function promptHash(text) {
  const n = normalizePrompt(text);
  if (!n) return null;
  try {
    return createHash('sha256').update(n).digest('hex').slice(0, 16);
  } catch {
    return null; // hashing is a nicety; never fail a hook over it
  }
}

export const AGENTS_DIR = join(ROOT, 'agents');

/** Agent definition names present on disk right now. */
export function availableAgents() {
  try {
    return readdirSync(AGENTS_DIR).filter((f) => f.endsWith('.md')).map((f) => f.slice(0, -3));
  } catch {
    return [];
  }
}

/**
 * The model an agent definition declares in its own frontmatter, or null.
 *
 * An agent that names a model has already made the cost decision — `worker` is
 * sonnet BECAUSE it is meant to be the mid tier. Prompt scoring must never
 * override that upward, or the whole point of having tiered agent definitions
 * is lost. Measured: 108 of 112 real spawns were `worker` and every one was
 * promoted to opus by `score:expensive-verb`, which is the opposite of the goal.
 *
 * Only our own definitions are consulted. Agents supplied by plugins live in
 * paths we cannot reliably enumerate, and guessing wrong here would clamp a
 * capable agent down to a tier it was never meant to run on.
 */
export function declaredModelFor(type) {
  if (!type || typeof type !== 'string' || !/^[\w.-]+$/.test(type)) return null;
  let raw;
  try {
    raw = readFileSync(join(AGENTS_DIR, `${type}.md`), 'utf8');
  } catch {
    return null; // not one of ours -> no declaration to honour
  }
  const fm = raw.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!fm) return null;
  const m = fm[1].match(/^[ \t]*model[ \t]*:[ \t]*["']?([\w.-]+)["']?[ \t]*$/mi);
  return m ? normalizeModel(m[1]) : null;
}

/** Full session record, or null. `via` distinguishes SessionStart from transcript recovery. */
export function sessionRecordFor(sessionId) {
  if (!sessionId) return null;
  try {
    return JSON.parse(readFileSync(join(SESSIONS_DIR, `${sessionId}.json`), 'utf8'));
  } catch {
    return null; // no record -> caller falls back to the transcript
  }
}

export function sessionTierFor(sessionId) {
  return normalizeModel(sessionRecordFor(sessionId)?.model);
}

/**
 * Recover the session's model by reading the tail of its own transcript.
 *
 * SessionStart only fires on startup/resume/clear/compact/fork, so a session that
 * was already open when these hooks were installed has no recorded model and
 * would silently lose the session clamp. Reading the transcript restores it
 * without requiring a restart.
 *
 * Only the tail is read — these files reach hundreds of MB and a hook must stay fast.
 */
export function sessionTierFromTranscript(transcriptPath, tailBytes = 262144) {
  if (!transcriptPath) return null;
  let fd;
  try {
    const size = statSync(transcriptPath).size;
    const start = Math.max(0, size - tailBytes);
    const len = size - start;
    if (len <= 0) return null;
    fd = openSync(transcriptPath, 'r');
    const buf = Buffer.allocUnsafe(len);
    // Bound the decode by what was actually read. allocUnsafe leaves the tail as
    // uninitialised heap memory, and if the file is truncated between statSync and
    // readSync that garbage would be decoded and scanned.
    const bytesRead = readSync(fd, buf, 0, len, start);
    if (bytesRead <= 0) return null;
    const lines = buf.toString('utf8', 0, bytesRead).split('\n');
    // Walk backwards: the most recent assistant message reflects the current model.
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i];
      if (!line || line.indexOf('"model"') === -1) continue;
      let rec;
      try { rec = JSON.parse(line); } catch { continue; } // tail almost always starts mid-line
      const tier = normalizeModel(rec?.message?.model);
      if (tier) return tier;
    }
    return null;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) { try { closeSync(fd); } catch { /* ignore */ } }
  }
}

export function writeSessionTier(sessionId, model, extra = {}) {
  if (!sessionId) return;
  try {
    mkdirSync(SESSIONS_DIR, { recursive: true });
    // Per-process temp name. A fixed one is shared by every concurrent spawn in the
    // same session, so two writers truncate the same inode and a short payload
    // written over a long one leaves a trailing fragment — the rename then
    // publishes invalid JSON, silently disabling the clamp and effort tiering.
    const tmp = join(SESSIONS_DIR, `.${sessionId}.${process.pid}.tmp`);
    writeFileSync(tmp, JSON.stringify({ model: model ?? null, at: new Date().toISOString(), ...extra }));
    renameSync(tmp, join(SESSIONS_DIR, `${sessionId}.json`));
  } catch { /* non-fatal */ }
}

/**
 * Per-session sidecar recording what the gate saw and which agents have stopped.
 *
 * Append-only on purpose. A whole fan-out of subagents writes concurrently, and a
 * read-modify-write on one shared JSON file loses updates under exactly that load
 * — which would silently mislabel gated spawns as ungated. Small appends survive
 * concurrent writers, so every line is kept.
 *
 * Lines are `g <prompt-fingerprint>` (a spawn the Agent gate routed) and
 * `s <agent_id>` (one SubagentStop). gcSessions() reaps these with everything
 * else in SESSIONS_DIR, so they inherit the same TTL.
 */
const SIDECAR_MAX_BYTES = 1048576;

function sidecarPath(sessionId) {
  return join(SESSIONS_DIR, `${sessionId}.events`);
}

/** Normalise to a single line — the file is line-delimited and values are untrusted. */
function sidecarLine(kind, value) {
  return `${kind} ${String(value).replace(/[\r\n]+/g, ' ')}`;
}

export function recordSessionEvent(sessionId, kind, value) {
  if (!sessionId || !value) return;
  try {
    mkdirSync(SESSIONS_DIR, { recursive: true });
    const p = sidecarPath(sessionId);
    // A runaway session must not grow this without bound. Past the cap we stop
    // appending: `routed` then degrades to false, which reads as "unknown", not
    // as a wrong tier.
    try { if (statSync(p).size > SIDECAR_MAX_BYTES) return; } catch { /* not created yet */ }
    appendFileSync(p, `${sidecarLine(kind, value)}\n`);
  } catch { /* never fatal */ }
}

export function countSessionEvents(sessionId, kind, value) {
  if (!sessionId || !value) return 0;
  const needle = sidecarLine(kind, value);
  try {
    let n = 0;
    for (const line of readFileSync(sidecarPath(sessionId), 'utf8').split('\n')) {
      if (line === needle) n += 1;
    }
    return n;
  } catch {
    return 0; // no sidecar -> nothing was recorded for this session
  }
}

export function gcSessions(ttlDays) {
  try {
    const cutoff = Date.now() - (ttlDays ?? 7) * 86400000;
    for (const f of readdirSync(SESSIONS_DIR)) {
      const p = join(SESSIONS_DIR, f);
      try { if (statSync(p).mtimeMs < cutoff) unlinkSync(p); } catch { /* skip */ }
    }
  } catch { /* dir may not exist yet */ }
}

/** Append one JSON line to the ledger, rotating if it has grown too large. */
export function ledger(entry, maxBytes) {
  try {
    mkdirSync(ROOT, { recursive: true });
    try {
      if (statSync(LEDGER_PATH).size > (maxBytes ?? 52428800)) {
        renameSync(LEDGER_PATH, `${LEDGER_PATH}.1`);
      }
    } catch { /* no ledger yet */ }
    appendFileSync(LEDGER_PATH, JSON.stringify({ ts: new Date().toISOString(), ...entry }) + '\n');
  } catch { /* never let logging break a tool call */ }
}

export function emit(obj) {
  try { process.stdout.write(JSON.stringify(obj)); } catch { /* ignore */ }
}
