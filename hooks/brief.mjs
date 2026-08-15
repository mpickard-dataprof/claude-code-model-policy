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
  availableAgents, emit,
} from './lib.mjs';

async function main() {
  const input = parseJson(await readStdin());
  if (!input) return;

  const policy = loadPolicy();
  if (!policy) return;

  // `model` is only present on SessionStart, and not guaranteed even there.
  const tier = normalizeModel(input.model);

  // Record which agent definitions existed as this session started. Claude Code
  // reads the agents directory once at startup, so this is exactly the set the
  // session can actually spawn — the gate uses it to avoid redirecting to an
  // agent type that would fail with "Agent type not found".
  writeSessionTier(input.session_id, tier, { via: 'sessionstart', agents: availableAgents() });
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
    'Tag a task description with `[cheap]` to force haiku, or `[hard]` to force the top tier.',
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
    'Prefer `scout` over `general-purpose` for anything mechanical — it is the cheapest',
    'path available, and generic spawns that score mechanical are redirected to it anyway.',
    '',
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
    'Any call that sets its own model is left exactly as written, so set one wherever',
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
