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
// Overridable like LEDGER_PATH and SESSIONS_DIR. Without this the suite had to
// overwrite the real policy.json to test a corrupt config and move it back
// afterwards — an interrupted run would leave `{ broken` as the live policy and
// silently disable all routing.
export const POLICY_PATH = process.env.MODEL_POLICY_POLICY || join(ROOT, 'policy.json');

// The test suite must never touch the real ledger: it is the only record of how
// past spawns were routed and what they cost, and the tuning skill reads nothing
// else. test.sh previously deleted it outright — 267 rows of evidence lost to a
// routine `bash test.sh`.
export const LEDGER_PATH = process.env.MODEL_POLICY_LEDGER || join(ROOT, 'ledger.jsonl');
export const SESSIONS_DIR = process.env.MODEL_POLICY_SESSIONS || join(ROOT, 'sessions');
export const USAGE_SNAPSHOT_PATH = process.env.MODEL_POLICY_USAGE_SNAPSHOT || join(ROOT, 'usage.json');

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
 * Decide whether this spawn should be offloaded to an OpenAI model via Codex.
 *
 * Why this exists: the Agent tool's `model` enum is Anthropic-only, so a
 * subagent cannot simply BE a GPT model. The only route to another provider is
 * to swap the agent type for a relay definition that shells out to the `codex`
 * CLI and reports back what it said. On an account whose Codex auth_mode is
 * `chatgpt`, that subprocess bills against a flat-rate subscription instead of
 * the Anthropic usage window — which is the entire point.
 *
 * Runs AFTER resolveTier, and reuses its answer: the tier the task scored to
 * picks which OpenAI model it deserves. Scoring work is not duplicated, it is
 * re-read on the other provider's ladder.
 *
 * Returns null (stay on Anthropic) unless every one of these holds:
 *   - the codex block is enabled and names a relay agent;
 *   - that agent was on disk when this session loaded its definitions — agent
 *     definitions do NOT hot-reload, so redirecting to one this session never
 *     saw fails the spawn outright with "Agent type not found";
 *   - the requested type is generic (swapping a specialised built-in would throw
 *     away the tuned system prompt that made it worth calling);
 *   - and either the [gpt] tag is present, or the scored tier is opted in.
 */
/**
 * Separates the relay's routing instructions from the task itself.
 *
 * Fixed string, exported, and used by both the preamble builder and the
 * fingerprint stripper so the two can never drift apart.
 */
export const CODEX_TASK_MARKER = '--- CODEX-TASK-BEGINS (send only what follows) ---';
export const AGY_TASK_MARKER = '--- AGY-TASK-BEGINS (send only what follows) ---';

/** Read a fresh status-line usage snapshot, or null when it cannot safely spill. */
export function usageSnapshot(policy) {
  try {
    const spill = policy?.agy?.usageSpill || {};
    if (spill.enabled !== true) return null;
    const snap = JSON.parse(readFileSync(USAGE_SNAPSHOT_PATH, 'utf8'));
    const now = Number(process.env.MODEL_POLICY_NOW || Math.floor(Date.now() / 1000));
    if (!Number.isFinite(now) || !Number.isFinite(snap?.ts)
      || snap.ts > now || now - snap.ts > (spill.maxAgeSec ?? 600)) return null;
    const five = Number(snap.five_hour_pct);
    const seven = Number(snap.seven_day_pct);
    const overFive = Number.isFinite(five) && five >= Number(spill.fiveHourPct ?? Infinity);
    const overSeven = Number.isFinite(seven) && seven >= Number(spill.sevenDayPct ?? Infinity);
    return overFive || overSeven ? snap : null;
  } catch {
    return null;
  }
}

/** The explicit tag named by a description, in the fixed backend precedence order. */
export function offloadTag(desc, policy) {
  const text = String(desc ?? '');
  const cx = policy?.overrides?.codexTag || '[gpt]';
  const pools = policy?.agy?.pools || {};
  if (text.includes(cx)) return 'codex';
  if (text.includes(pools.thirdparty?.tag || '[agy]')) return 'agy:thirdparty';
  if (text.includes(pools.gemini?.tag || '[gemini]')) return 'agy:gemini';
  return null;
}

export function resolveCodexOffload(toolInput, policy, tier, currentType, record) {
  const cx = policy.codex || {};
  // Strictly boolean true, matching the gate and the wrapper. A string "false"
  // is truthy in JS, so a loose check here would advertise and route offloads
  // that the execution-side guards then refuse — turning a config typo into
  // work dispatched straight into a guaranteed failure.
  if (cx.enabled !== true) return null;

  const agent = typeof cx.agent === 'string' && cx.agent.length > 0 ? cx.agent : null;
  if (!agent) return null;

  // Same SessionStart guard the redirect path uses. A session recovered from its
  // transcript predates the install and must never be redirected.
  const loaded = record?.via === 'sessionstart' && Array.isArray(record.agents);
  if (!loaded || !record.agents.includes(agent)) return null;

  // Naming the relay directly is a legitimate way to ask for an offload — it is
  // how a person opts in explicitly. Treat it as one so the spawn still gets
  // validated routing metadata, rather than reaching the wrapper bare and
  // falling back to a default model nobody chose.
  const direct = String(currentType ?? '') === agent;

  const types = Array.isArray(cx.offloadableTypes) ? cx.offloadableTypes : [];
  if (!direct && !types.includes(String(currentType ?? ''))) return null;

  const tagged = offloadTag(toolInput?.description, policy) === 'codex';

  const never = Array.isArray(cx.neverAutoTiers) ? cx.neverAutoTiers : [];
  const auto = Array.isArray(cx.autoTiers) ? cx.autoTiers : [];
  const autoOn = auto.includes(tier) && !never.includes(tier);

  if (!direct && !tagged && !autoOn) return null;

  const spec = (cx.byTier || {})[tier];
  if (!spec || typeof spec.model !== 'string') return null;

  const model = spec.model;
  const effort = typeof spec.effort === 'string' ? spec.effort : 'medium';

  // The relay only writes a file, runs a subprocess and reads the result back,
  // so it runs at the bottom of the ladder no matter how hard the real task is.
  const relayTier = availableTier(cx.relayTier || 'haiku', policy).tier;

  // Travels in the prompt because the Agent schema is additionalProperties:false
  // and there is no field to carry it in.
  //
  // The BEGIN marker matters: these lines address the relay, not the worker.
  // Forwarding them would tell the OpenAI model to itself hand the task to
  // Codex — contradictory instructions at best, a recursive spawn at worst. The
  // marker is what lets the relay send the task body and nothing else, and it is
  // a fixed string so the split is mechanical rather than a judgement call.
  // Absolute path to THIS installation's wrapper. The agent definition used to
  // hardcode ~/.claude-shared/model-policy, so an install from any other
  // checkout either failed with "not found" or silently ran a different
  // installation against a different policy.
  const wrapper = join(ROOT, 'bin', 'codex-relay.sh');

  const preamble = [
    'CODEX-OFFLOAD:',
    `  model: ${model}`,
    `  effort: ${effort}`,
    `  wrapper: ${wrapper}`,
    '',
    'These lines are for you, the relay. Run the wrapper with exactly those settings',
    'and relay its answer verbatim. Do not attempt the task yourself, and do NOT',
    'include any line up to and including the marker below in what you send —',
    'forwarding it would instruct the worker to be another relay.',
    '',
    CODEX_TASK_MARKER,
    '',
  ].join('\n');

  return {
    agent,
    model,
    effort,
    relayTier,
    preamble,
    via: direct ? 'direct' : (tagged ? 'tag' : `auto:${tier}`),
  };
}

/** Resolve an Antigravity offload after the shared task tier has been scored. */
export function resolveAgyOffload(toolInput, policy, tier, currentType, record, cwd) {
  const agy = policy.agy || {};
  if (agy.enabled !== true) return null;
  const agent = typeof agy.agent === 'string' && agy.agent.length > 0 ? agy.agent : null;
  if (!agent) return null;
  const loaded = record?.via === 'sessionstart' && Array.isArray(record.agents);
  if (!loaded || !record.agents.includes(agent)) return null;

  const direct = String(currentType ?? '') === agent;
  const types = Array.isArray(agy.offloadableTypes) ? agy.offloadableTypes : [];
  if (!direct && !types.includes(String(currentType ?? ''))) return null;

  const tagged = offloadTag(toolInput?.description, policy);
  let poolName = tagged?.startsWith('agy:') ? tagged.slice(4) : null;
  let via = poolName ? 'tag' : null;
  if (!poolName && direct) {
    poolName = 'thirdparty';
    via = 'direct';
  }
  if (!poolName && !tagged) {
    const spill = agy.usageSpill || {};
    const allowed = Array.isArray(spill.tiers) ? spill.tiers : [];
    if (allowed.includes(tier) && usageSnapshot(policy)) {
      poolName = spill.pool;
      via = 'auto:usage';
    }
  }
  if (!poolName) return null;

  const pool = (agy.pools || {})[poolName];
  if (!pool || typeof pool !== 'object') return null;
  const model = pool.byTier?.[tier];
  if (typeof model !== 'string' || !model) return null;
  const relayTier = availableTier(agy.relayTier || 'haiku', policy).tier;
  const wrapper = join(ROOT, 'bin', 'agy-relay.sh');
  const parentCwd = typeof cwd === 'string' && cwd ? cwd : process.cwd();
  const preamble = [
    'AGY-OFFLOAD:',
    `  pool: ${poolName}`,
    `  model: ${model}`,
    `  wrapper: ${wrapper}`,
    `  cwd: ${parentCwd}`,
    '',
    'These lines are for you, the relay. Run the wrapper with exactly those settings',
    'and relay its answer verbatim. Do not attempt the task yourself, and do NOT',
    'include any line up to and including the marker below in what you send.',
    '',
    AGY_TASK_MARKER,
    '',
  ].join('\n');
  return { agent, pool: poolName, model, relayTier, preamble, via };
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
 * An explicit `model` on a call is never overridden, and an explicit `effort` is
 * never changed. An ABSENT effort is filled from effortByTier even when the model
 * was chosen by the author — without that, effortByTier.fable was unreachable,
 * since the scorer never returns fable and the only route to it is an explicit
 * model. Left alone otherwise: a script that has
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
/* Same alias handling as normalizeModel(): a call may name a full model id. */
function __mpTier(m) {
  const s = String(m == null ? '' : m).toLowerCase();
  if (s.indexOf('haiku') !== -1) return 'haiku';
  if (s.indexOf('sonnet') !== -1) return 'sonnet';
  if (s.indexOf('opus') !== -1) return 'opus';
  if (s.indexOf('fable') !== -1 || s.indexOf('mythos') !== -1) return 'fable';
  return null;
}
/* Captured BEFORE any global is patched, so __mpAgent can never recurse into itself. */
const __mpReal = agent;
function __mpAgent(prompt, opts) {
  const o = Object.assign({}, opts || {});
  if (!o.model) o.model = __mpPick(prompt);
  /* Effort is filled whenever it is ABSENT, including on a call that chose its
     own model. The scorer only ever returns haiku/sonnet/opus, so the previous
     "only when we picked the model" rule made effortByTier.fable unreachable:
     the one way to get a fable workflow agent is to ask for it explicitly, which
     was exactly the case that skipped this block. A model the author chose is
     still never overridden - only the effort they left unset is filled in. */
  if (!o.effort) {
    /* Normalise a full model id ("claude-opus-5") to its tier before the lookup,
       and only assign a value that exists - assigning undefined adds a key whose
       presence differs from absence to whatever reads it downstream. */
    const __t = __mpTier(o.model);
    const __e = __t ? __mpCfg.effort[__t] : undefined;
    if (__e) o.effort = __e;
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
  const n = normalizePrompt(stripOffloadPreamble(text));
  return n ? n.slice(0, 100) : null;
}

/**
 * Drop an offload preamble so a fingerprint describes the TASK.
 *
 * The preamble runs well past 100 characters, and a fingerprint keeps only the
 * first 100 — so without this, every offloaded spawn sharing a model and effort
 * fingerprints identically no matter what it was asked to do. That is not a
 * cosmetic loss: `countSessionEvents` uses the fingerprint to decide whether a
 * completing agent passed through the gate, so one gated offload would make
 * every later ungated one report `routed: true`.
 *
 * Applied inside promptFingerprint so both hooks strip identically without
 * either having to remember to. Deliberately NOT applied to promptHash: the hash
 * is the exact-join key and must reflect the literal prompt the agent received.
 */
export function stripOffloadPreamble(text) {
  if (typeof text !== 'string') return text;
  // Matched on the FULL generated shape, not on a length window and not on the
  // header word alone.
  //
  // Two earlier versions were wrong in opposite directions. A 600-character
  // cutoff broke as soon as the preamble grew a `wrapper:` line: on an install
  // with a long path the marker moved past the window and every offload went
  // back to fingerprinting its own routing metadata. Matching the bare prefix
  // `CODEX-OFFLOAD:` then stripped a legitimate task that merely began by
  // quoting the protocol — a documentation example about this very feature.
  //
  // So require the whole envelope this code emits: the header, then its three
  // indented fields, then the marker. Task text that happens to mention the
  // protocol does not reproduce that structure.
  // `.+` for the wrapper path, not `\S+`: an install under a directory with a
  // space ("/Users/Matt Smith/...") failed to match, and the envelope then went
  // UNSTRIPPED — putting routing metadata back into every fingerprint, the exact
  // bug the anchor was added to fix.
  const CODEX_ENVELOPE = /^CODEX-OFFLOAD:\n {2}model: \S+\n {2}effort: \S+\n {2}wrapper: .+\n/;
  const AGY_ENVELOPE = /^AGY-OFFLOAD:\n {2}pool: (gemini|thirdparty)\n {2}model: \S+\n {2}wrapper: .+\n {2}cwd: .+\n/;
  const marker = CODEX_ENVELOPE.test(text) ? CODEX_TASK_MARKER
    : (AGY_ENVELOPE.test(text) ? AGY_TASK_MARKER : null);
  if (!marker) return text;
  // The marker must be a LINE of its own, not merely present somewhere: an
  // `indexOf` hit inside a sentence was enough to trigger a split.
  const m = text.match(new RegExp('^' + marker.replace(/[.*+?^${}()|[\]\\-]/g, '\\$&') + '$', 'm'));
  if (!m || m.index === undefined) return text;
  return text.slice(m.index + marker.length);

  // Honest limit: this recognises the SHAPE the gate emits, so a caller who
  // reproduces those exact bytes is indistinguishable from a real envelope.
  // Closing that needs provenance (a nonce the gate records and this verifies),
  // which is not worth it while the only consequence is a fingerprint — the
  // exact-hash join does not depend on this function at all.
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
  // Enumerate the INSTALLED definitions, not this package's source directory.
  //
  // The two are not the same set, and the difference decides whether a redirect
  // works or kills the spawn. Updating the package adds a file to agents/ but
  // installs no symlink, so reading the source dir reports an agent Claude Code
  // has never heard of — and the gate then rewrites subagent_type to a type that
  // does not exist, failing the spawn outright. Reading the config dirs means a
  // missing symlink degrades to "no redirect", which is merely suboptimal.
  // When set, the env var REPLACES the defaults rather than adding to them —
  // otherwise the real config dirs leak into every test that tries to pin this
  // down, and a non-standard install cannot be pointed somewhere else.
  const override = (process.env.MODEL_POLICY_AGENT_DIRS || '').split(':').filter(Boolean);
  const dirs = override.length ? override : [
    join(homedir(), '.claude', 'agents'),
    join(homedir(), '.claude-work', 'agents'),
    join(homedir(), '.claude-personal', 'agents'),
  ];

  const found = new Set();
  let readAny = false;
  for (const d of dirs) {
    try {
      const entries = readdirSync(d);
      readAny = true; // the directory EXISTS; an empty one is a real answer
      for (const f of entries) {
        if (f.endsWith('.md')) found.add(f.slice(0, -3));
      }
    } catch { /* directory absent: nothing installed there */ }
  }
  // Fall back to the package's own agents/ only when no config directory could
  // be read AT ALL. Keying this off `found.size` instead meant an empty but
  // perfectly readable config dir reported every agent in the package — exactly
  // the "claims an agent the session never loaded" bug this function exists to
  // prevent, reintroduced by its own fallback.
  if (!readAny) {
    try {
      for (const f of readdirSync(AGENTS_DIR)) {
        if (f.endsWith('.md')) found.add(f.slice(0, -3));
      }
    } catch { /* nothing readable anywhere */ }
  }
  return [...found];
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
