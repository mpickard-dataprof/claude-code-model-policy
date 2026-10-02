#!/usr/bin/env node
// SessionStart hook.
//
// Two jobs:
//   1. Record this session's model so gate.mjs can clamp subagents to it
//      (stops the policy from *raising* cost in a sonnet session).
//   2. Brief Claude on the tier table, so Workflow scripts are written with
//      per-agent models from the first call rather than patched afterwards.

import {
  readStdin, parseJson, loadPolicy, normalizeModel, writeSessionTier, gcSessions,
  availableAgents, agyBinaryAvailable, emit,
} from './lib.mjs';

/**
 * The offload section of the brief.
 *
 * Only shown when the mechanism is actually live, and only describing the route
 * that is actually open. Briefing Claude on a `[gpt]` tag that the gate would
 * ignore — because the relay agent is missing, or codex.enabled is false — would
 * teach it to write tags that silently do nothing.
 */
function codexBrief(policy) {
  const cx = policy.codex || {};
  if (cx.enabled !== true || !cx.agent) return [];
  if (!availableAgents().includes(cx.agent)) return [];

  const tag = policy.overrides?.codexTag || '[gpt]';
  const auto = (Array.isArray(cx.autoTiers) ? cx.autoTiers : [])
    .filter((t) => !(cx.neverAutoTiers || []).includes(t));

  return [
    '## Offloading to OpenAI models (saves the Anthropic usage window)',
    '',
    `Tag a task description with \`${tag}\` and the spawn is handed to an OpenAI model`,
    'through the Codex CLI instead of an Anthropic one. The work still comes back to you',
    'as a normal subagent result — a cheap relay agent drives the subprocess and reports',
    'what it said.',
    '',
    'This runs on a ChatGPT subscription, not Anthropic token billing, so an offloaded',
    'task costs essentially nothing against this window. **Prefer it whenever the work is',
    'self-contained** — a review, an analysis, a bounded implementation, a second opinion —',
    'and especially when the window is under pressure.',
    '',
    'Keep work on Anthropic when it needs this session\'s conversation context, a tool only',
    'this harness has, or tight back-and-forth with you. The relay passes the prompt and',
    'nothing else.',
    '',
    `The tier still gets scored: it picks which OpenAI model the task deserves. \`${tag}\``,
    'combines with the other tags, so `[gpt] [hard]` means a hard task on the Codex model for the hard tier.',
    '',
    auto.length
      ? `Tiers that offload automatically with no tag: ${auto.join(', ')}.`
      : 'Nothing offloads automatically — the tag is the only route in.',
    '',
  ];
}

function agyBrief(policy, available) {
  const agy = policy.agy || {};
  if (agy.enabled === true && !available) {
    const pools = agy.pools || {};
    const gemini = pools.gemini?.tag || '[gemini]';
    const thirdparty = pools.thirdparty?.tag || '[agy]';
    return [`Antigravity tags \`${gemini}\` and \`${thirdparty}\` are inactive on this machine: they require the configured \`agy\` binary and Linux \`bwrap\` sandbox. Install agy with \`curl -fsSL https://antigravity.google/cli/install.sh | bash\`, install bubblewrap, then run \`agy\` once to sign in.`];
  }
  if (agy.enabled !== true || !agy.agent || !availableAgents().includes(agy.agent)) return [];
  const pools = agy.pools || {};
  const gemini = pools.gemini?.tag || '[gemini]';
  const thirdparty = pools.thirdparty?.tag || '[agy]';
  const spill = agy.usageSpill || {};
  return [
    '## Offloading to Antigravity models',
    '',
    `Tag a review with \`${gemini}\` to use Gemini. It is **reviews only** and always`,
    'read-only. Tag a review or a self-contained worktree development task with',
    `\`${thirdparty}\` to use the third-party pool. Development can edit only a named`,
    '`.worktrees/` directory. Every run is in a mandatory Linux bubblewrap sandbox;',
    'Gemini remains on probation: verify every result and run tests yourself afterwards.',
    '',
    `If more than one offload tag appears, precedence is \`${policy.overrides?.codexTag || '[gpt]'}\` > \`${thirdparty}\` > \`${gemini}\`.`,
    spill.enabled === true
      ? `When the local usage snapshot is fresh and either usage window is high, untagged ${Array.isArray(spill.tiers) ? spill.tiers.join('/') : 'sonnet/opus'} work spills to the ${spill.pool || 'thirdparty'} pool automatically.`
      : 'Usage-window auto-spill is disabled; these tags are the only route in.',
    '',
  ];
}

async function main() {
  const input = parseJson(await readStdin());
  if (!input) return;

  const policy = loadPolicy();
  if (!policy) return;

  // `model` is only present on SessionStart, and not guaranteed even there.
  const tier = normalizeModel(input.model);
  const agyAvailable = agyBinaryAvailable(policy);

  // Record which agent definitions existed as this session started. Claude Code
  // reads the agents directory once at startup, so this is exactly the set the
  // session can actually spawn — the gate uses it to avoid redirecting to an
  // agent type that would fail with "Agent type not found".
  writeSessionTier(input.session_id, tier, {
    via: 'sessionstart', agents: availableAgents(), agy_available: agyAvailable,
  });
  gcSessions(policy.limits?.sessionTtlDays);

  const lines = Object.entries(policy.agentTypes || {})
    .map(([type, t]) => `  ${type} -> ${t}`)
    .join('\n');

  const additionalContext = [
    '# Subagent model policy (enforced by hook)',
    '',
    'Subagent spawns via the Agent tool have their model set automatically, so you do not',
    'need to pass `model` yourself. Current routing:',
    '',
    lines,
    `  general-purpose / claude -> scored from the prompt (base ${policy.catchAll?.base ?? 'sonnet'})`,
    '',
    `Tag a task description with \`${policy.overrides?.cheapTag ?? '[cheap]'}\` to force ${policy.overrides?.cheapTier ?? 'haiku'}, or \`${policy.overrides?.hardTag ?? '[hard]'}\` to force ${policy.overrides?.hardTier ?? 'the top tier'}.`,
    '',
    '## Two agent types carry effort as well as model',
    '',
    'Effort cannot be set per invocation, so it lives in agent definitions:',
    '',
    '  scout  - haiku + effort low.    Read-only fact retrieval: find a file, locate a',
    '           definition, count occurrences, check whether something exists.',
    '  worker - sonnet + effort medium. Routine work whose approach is already decided:',
    '           write a specified test, implement a given signature, apply a known migration.',
    '',
    '  architect - fable + effort medium. Genuinely hard work: unknown root cause,',
    '           multi-file design, a contested call. Used when a spawn resolves to fable.',
    '',
    'Prefer `scout` over `general-purpose` for anything mechanical — it is the cheapest',
    'path available, and generic spawns that score mechanical are redirected to it anyway.',
    '',
    ...codexBrief(policy),
    ...agyBrief(policy, agyAvailable),
    '## Workflow scripts ARE auto-tiered — but say so when you know better',
    '',
    'An inline Workflow script is rewritten before it runs: every `agent()` call that',
    'sets no `model` gets one chosen from its prompt at runtime, plus a matching',
    '`effort`. You do not have to tier a script by hand for it to be cheap.',
    '',
    '  haiku  - mechanical and bounded: search, list, count, read, extract',
    '  sonnet - routine engineering with a known shape',
    '  opus   - real reasoning: debugging, design, multi-file change',
    '  fable  - only when explicitly asked for; it is the most expensive tier',
    '',
    'A call that sets its own model keeps it (an effort you leave unset is filled in),',
    'so set a model wherever',
    'the prompt text would mislead the scorer — a short prompt pointing at a hard',
    'problem, or a long one that is only boilerplate:',
    '',
    "  agent(prompt, { model: 'opus', effort: 'high', label: 'root-cause' })",
    '',
    'Two forms escape rewriting, so tier those by hand: `{scriptPath}` and `{name}`.',
  ].join('\n');

  const out = {
    hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext },
  };

  // This env var outranks the per-invocation model parameter, so if it is ever
  // set the whole policy silently stops working. Say so rather than no-op quietly.
  if (process.env.CLAUDE_CODE_SUBAGENT_MODEL) {
    out.systemMessage =
      `model-policy: CLAUDE_CODE_SUBAGENT_MODEL is set to "${process.env.CLAUDE_CODE_SUBAGENT_MODEL}". ` +
      'It overrides per-invocation model selection, so tiered routing is inactive this session. ' +
      'Unset it to re-enable.';
  }

  emit(out);
}

main().catch(() => { /* fail open */ });
