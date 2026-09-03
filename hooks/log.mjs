#!/usr/bin/env node
// SubagentStop hook.
//
// Records what each spawn actually cost and whether it appears to have
// succeeded. This is what makes tuning evidence-based: a haiku agent that
// gives up and forces an opus retry costs MORE than opus would have, so the
// target metric is cost per completed task, not cost per spawn.

import { readFileSync, appendFileSync, statSync, openSync, readSync, closeSync } from 'node:fs';
import { join } from 'node:path';
import {
  readStdin, parseJson, loadPolicy, ledger, promptFingerprint, promptHash, ROOT,
  recordSessionEvent, countSessionEvents,
} from './lib.mjs';

// SubagentStop also fires for Claude Code's internal utility agents (session
// title generation and similar). Those carry no agent_type and no transcript,
// so they contribute nothing to tuning but would skew every rate we compute.
// Record their shape separately, capped, and keep them out of the ledger.
const DIAG_PATH = join(ROOT, 'diagnostics.jsonl');
const DIAG_MAX_BYTES = 65536;

function diag(entry) {
  try {
    try { if (statSync(DIAG_PATH).size > DIAG_MAX_BYTES) return; } catch { /* not created yet */ }
    appendFileSync(DIAG_PATH, JSON.stringify({ ts: new Date().toISOString(), ...entry }) + '\n');
  } catch { /* never fatal */ }
}

// Phrases that suggest the agent could not finish the job. Deliberately narrow:
// a false positive here pushes the tuner toward a more expensive tier.
const GIVE_UP = [
  /\bunable to\b/i,
  /\bcouldn'?t (find|determine|locate|complete)\b/i,
  /\bcould not (find|determine|locate|complete)\b/i,
  /\bnot able to determine\b/i,
  /\bno (results|matches) found\b/i,
  /\bI don'?t have (enough|access)\b/i,
  /\binsufficient (context|information)\b/i,
];

/**
 * Read a subagent's own transcript for token usage and its opening prompt.
 * SubagentStop carries neither.
 *
 * The prompt is what lets the tuner join this entry back to the routing decision
 * that produced it — see promptFingerprint().
 */
// A subagent transcript can reach hundreds of MB (large tool outputs, many turns).
// readFileSync on one of those raises a fatal V8 "heap out of memory" that aborts
// the process — it is NOT a catchable exception, so try/catch and main().catch()
// cannot save it, and the hook would exit non-zero in violation of fail-open.
// Past the cap, read the head (for the opening prompt) and the tail (for recent
// usage) instead, and flag the totals as partial.
const MAX_WHOLE_FILE = 16 * 1024 * 1024;
const HEAD_BYTES = 256 * 1024;
const TAIL_BYTES = 4 * 1024 * 1024;

function readTranscript(path) {
  const out = {
    usage: { input: 0, output: 0, cache_read: 0, cache_write: 0, turns: 0 },
    prompt: null,
    partial: false,
    // What the agent ACTUALLY ran on. The route entry records only what the hook
    // asked for, which proved insufficient: a spawn once logged `set: haiku`
    // while running on opus. This is the only field that can confirm the policy
    // took effect, and it is the sole evidence available for workflow subagents,
    // which never pass through the PreToolUse gate at all.
    models: null,
  };
  if (!path) return out;

  let raw;
  try {
    const size = statSync(path).size;
    if (size <= MAX_WHOLE_FILE) {
      raw = readFileSync(path, 'utf8');
    } else {
      out.partial = true;
      const fd = openSync(path, 'r');
      try {
        const head = Buffer.allocUnsafe(HEAD_BYTES);
        const hn = readSync(fd, head, 0, HEAD_BYTES, 0);
        const tail = Buffer.allocUnsafe(TAIL_BYTES);
        const tn = readSync(fd, tail, 0, TAIL_BYTES, Math.max(0, size - TAIL_BYTES));
        raw = `${head.toString('utf8', 0, Math.max(0, hn))}\n${tail.toString('utf8', 0, Math.max(0, tn))}`;
      } finally {
        try { closeSync(fd); } catch { /* ignore */ }
      }
    }
  } catch {
    return out;
  }

  for (const line of raw.split('\n')) {
    if (!line) continue;
    let rec;
    try { rec = JSON.parse(line); } catch { continue; }

    const model = rec?.message?.model;
    if (typeof model === 'string' && model) {
      (out.models ||= {})[model] = (out.models[model] || 0) + 1;
    }

    const u = rec?.message?.usage;
    if (u) {
      out.usage.input += u.input_tokens || 0;
      out.usage.output += u.output_tokens || 0;
      out.usage.cache_read += u.cache_read_input_tokens || 0;
      out.usage.cache_write += u.cache_creation_input_tokens || 0;
      out.usage.turns += 1;
    }

    if (out.prompt === null && rec?.type === 'user') {
      const c = rec.message?.content;
      if (typeof c === 'string') out.prompt = c;
      else if (Array.isArray(c)) {
        const t = c.find((b) => b && b.type === 'text' && typeof b.text === 'string');
        if (t) out.prompt = t.text;
      }
    }
  }
  return out;
}

async function main() {
  const input = parseJson(await readStdin());
  if (!input) return;

  const policy = loadPolicy();
  const last = String(input.last_assistant_message ?? '');
  const agentType = String(input.agent_type ?? '');
  const { usage, prompt, partial, models } = readTranscript(input.agent_transcript_path);

  // One model in the normal case; more than one means a fallback or a /model
  // change mid-run, which is worth seeing rather than collapsing away.
  const ranked = models
    ? Object.entries(models).sort((a, b) => b[1] - a[1]).map(([m]) => m)
    : [];

  // A real spawn has a type, or at minimum a transcript we could read usage from.
  // Anything with neither is an internal utility agent — divert it to diagnostics.
  if (agentType.length === 0 && usage.turns === 0) {
    diag({
      note: 'skipped: no agent_type and no readable transcript',
      keys: Object.keys(input).sort(),
      agent_id: input.agent_id ?? null,
      transcript_path: input.agent_transcript_path ?? null,
      tail: last.slice(0, 120),
    });
    return;
  }

  const fp = promptFingerprint(prompt);

  // Provenance. SubagentStop reports whatever agent type ran, so a Workflow
  // agent() call that passed opts.agentType (e.g. 'general-purpose') is
  // indistinguishable here from a real Agent-tool spawn. Those rows then appear
  // in the Agent-tool population with no `route` row and read as agents that
  // escaped the gate — every such alarm inspected so far has been a correctly
  // tiered workflow agent. Ask the gate directly instead: it records the
  // fingerprint of every spawn it routes.
  const routed = countSessionEvents(input.session_id, 'g', fp) > 0;

  // SubagentStop fires REPEATEDLY for one long-running agent, and readTranscript
  // above re-reads the whole transcript each time — so every row is a cumulative
  // snapshot that supersedes the previous one, not an increment. Summing rows
  // double-counts: over 1,146 real rows, $490.66 summed against $390.76 true.
  // Number them so a consumer can keep the highest `stop_seq` per agent_id
  // without having to infer supersession from a usage field.
  const agentId = input.agent_id ?? null;
  recordSessionEvent(input.session_id, 's', agentId);
  const stopSeq = agentId ? countSessionEvents(input.session_id, 's', agentId) : null;

  ledger({
    event: 'complete',
    session_id: input.session_id,
    agent_id: agentId,
    agent_type: agentType || null,
    routed,
    stop_seq: stopSeq,
    prompt_fp: fp,
    prompt_sha: promptHash(prompt),
    prompt_id: input.prompt_id ?? null,
    actual_model: ranked[0] ?? null,
    actual_models_all: ranked.length > 1 ? ranked : undefined,
    usage,
    usage_partial: partial, // true = transcript exceeded the read cap, totals understate
    looks_failed: GIVE_UP.some((re) => re.test(last)),
    tail: last.slice(-300),
  }, policy?.limits?.ledgerMaxBytes);
}

main().catch(() => { /* fail open */ });
