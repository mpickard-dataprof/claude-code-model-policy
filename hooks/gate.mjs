#!/usr/bin/env node
// PreToolUse hook, matcher: Agent|Workflow
//
// Agent    -> rewrites tool_input.model to the policy tier.
// Workflow -> denies only a wide fan-out that sets no models at all.
//
// Fail-open by contract: any error exits 0 with no stdout, and the tool call
// proceeds exactly as it would have without this hook.

import {
  readStdin, parseJson, loadPolicy, resolveTier, sessionRecordFor, normalizeModel,
  sessionTierFromTranscript, writeSessionTier, tierIndex, promptFingerprint,
  stripCodeNoise, injectWorkflowTiers, resolveWorkflowScript, sessionTierFor,
  ledger, emit, recordSessionEvent, promptHash,
} from './lib.mjs';

// How long a cached session model is trusted before the transcript is re-read.
// Bounds how stale the clamp can get after a mid-session /model change.
const RECORD_MAX_AGE_MS = 5 * 60 * 1000;

const TIER_TABLE = [
  'haiku  - mechanical, bounded, verifiable (search, list, count, read)',
  'sonnet - routine engineering with a known shape',
  'opus   - real reasoning (debugging, design, multi-file change)',
  'fable  - reserve for the genuinely hardest work only',
].join('\n  ');

async function main() {
  const input = parseJson(await readStdin());
  if (!input) return;

  const policy = loadPolicy();
  if (!policy) return; // invalid policy -> behave as if the hook were absent

  const tool = input.tool_name;
  const toolInput = input.tool_input || {};

  if (tool === 'Agent') {
    // A real spawn always carries a prompt string. If it does not, this payload is
    // malformed or from a shape we do not understand — leave it completely alone.
    // Emitting updatedInput here would replace the whole input with a stub and
    // destroy the prompt.
    if (typeof toolInput.prompt !== 'string' || toolInput.prompt.length === 0) return;

    // Prefer the record SessionStart wrote. If this session predates the hooks
    // being installed, SessionStart never fired for it — recover the model from
    // the transcript and cache it, so the clamp works without a restart.
    let record = sessionRecordFor(input.session_id);
    let sessionTier = normalizeModel(record?.model);

    // A mid-session `/model` change does not fire SessionStart, so a cached tier
    // goes stale and the clamp starts measuring against the model the session
    // STARTED on. That can route a subagent to a tier more expensive than the
    // session itself — the exact inversion the clamp exists to prevent. Re-read
    // the transcript once the record ages out.
    const recordedAt = record?.at ? Date.parse(record.at) : NaN;
    const stale = !Number.isFinite(recordedAt)
      || (Date.now() - recordedAt) > RECORD_MAX_AGE_MS;

    if (!sessionTier || stale) {
      const fromTranscript = sessionTierFromTranscript(input.transcript_path);
      const sessionTierBefore = sessionTier;
      sessionTier = fromTranscript || sessionTier;
      if (fromTranscript && fromTranscript !== sessionTierBefore) {
        // SessionStart's `model` field is not guaranteed present, so a record can
        // exist with a null model. Recovering the model must NOT discard that
        // record's provenance — overwriting `via`/`agents` here would silently
        // disable effort tiering for the rest of the session.
        const carried = record?.via === 'sessionstart' && Array.isArray(record.agents)
          ? { via: 'sessionstart', agents: record.agents }
          : { via: 'transcript' };
        writeSessionTier(input.session_id, sessionTier, carried);
        record = { model: sessionTier, at: new Date().toISOString(), ...carried };
      }
    }

    const { tier, rule } = resolveTier(toolInput, policy, sessionTier);

    // A tier the policy invented (typo in policy.json, unknown alias) would be
    // written straight into `model` and fail the spawn. Refuse to emit it.
    if (tierIndex(tier, policy.tierOrder) === null) {
      ledger({
        event: 'error',
        reason: 'policy produced a tier that is not in tierOrder',
        tier, rule, session_id: input.session_id,
      }, policy.limits?.ledgerMaxBytes);
      return;
    }

    // Effort tiering: swap generic agent types for a definition carrying both
    // model and effort. Specialised built-ins keep their own prompt.
    //
    // Agent definitions are read once at session start and do NOT hot-reload —
    // unlike hooks and skills. Redirecting to an agent this session never loaded
    // fails the spawn outright with "Agent type not found". So only redirect when
    // SessionStart ran for this session AND saw the target on disk; a session
    // recovered from its transcript predates the install and must not redirect.
    const r = policy.redirect || {};
    const currentType = String(toolInput.subagent_type ?? '');
    const candidate = r.enabled && Array.isArray(r.redirectableTypes)
      && r.redirectableTypes.includes(currentType)
      ? (r.byTier || {})[tier] : null;
    const loaded = record?.via === 'sessionstart' && Array.isArray(record.agents);
    const redirectTo = typeof candidate === 'string' && candidate.length > 0
      && loaded && record.agents.includes(candidate)
      ? candidate : null;

    const requested = typeof toolInput.model === 'string' ? toolInput.model : null;
    const changed = requested !== tier || redirectTo !== null;

    // Log every spawn, including ones already on the right model — the tuner
    // needs the full denominator, not just the rewrites.
    ledger({
      event: 'route',
      tool: 'Agent',
      session_id: input.session_id,
      tool_use_id: input.tool_use_id,
      agent_type: toolInput.subagent_type ?? null,
      description: String(toolInput.description ?? '').slice(0, 120),
      prompt_chars: toolInput.prompt.length,
      prompt_fp: promptFingerprint(toolInput.prompt),
      prompt_sha: promptHash(toolInput.prompt),
      prompt_id: input.prompt_id ?? null,
      requested,
      session_tier: sessionTier,
      set: tier,
      redirect_to: redirectTo,
      rule: redirectTo ? `${rule}+redirect:${redirectTo}` : rule,
      changed,
    }, policy.limits?.ledgerMaxBytes);

    // Record that this exact prompt passed the gate, so SubagentStop can tell an
    // Agent-tool spawn from a Workflow agent() call that borrowed a custom
    // agentType and never reached this hook at all. Must happen before the
    // early return below, or every already-correct spawn looks ungated.
    recordSessionEvent(input.session_id, 'g', promptFingerprint(toolInput.prompt));

    if (!changed) return; // already correct, nothing to rewrite

    // updatedInput replaces the entire input object, so echo every field back
    // with only `model` changed.
    //
    // permissionDecision: "allow" is REQUIRED. Verified empirically: returning
    // updatedInput on its own is silently ignored — the hook logged model=haiku
    // while the agent actually ran on claude-opus-5. This does not turn the hook
    // into a blanket approver: per the hooks reference, deny and ask permission
    // rules are still evaluated regardless of what a hook returns.
    const updatedInput = { ...toolInput, model: tier };
    if (redirectTo) updatedInput.subagent_type = redirectTo;

    emit({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'allow',
        permissionDecisionReason: redirectTo
          ? `model-policy: ${tier} via ${redirectTo} (${rule})`
          : `model-policy: ${tier} (${rule})`,
        updatedInput,
      },
    });
    return;
  }

  if (tool === 'Workflow') {
    // `{scriptPath}` and `{name}` hand over a reference, not source. Read it back
    // so this path gets the same enforcement as an inline script. The file itself
    // is never written — the rewritten source is passed inline instead.
    let script = String(toolInput.script ?? '');
    let indirect = null;
    if (!script) {
      const note = (reason, extra = {}) => ledger({
        event: 'workflow',
        session_id: input.session_id,
        tool_use_id: input.tool_use_id,
        form: toolInput.scriptPath ? 'scriptPath' : (toolInput.name ? 'name' : 'unknown'),
        enforced: false,
        reason,
        ...extra,
      }, policy.limits?.ledgerMaxBytes);

      indirect = resolveWorkflowScript(toolInput);
      if (!indirect) { note('unresolvable'); return; }

      // An inline script is rewritten BEFORE Claude Code persists it, so the file
      // behind an iterate-on-scriptPath loop already carries the shim. Re-injecting
      // would nest it and, worse, change every call's opts — which is exactly what
      // invalidates a resume cache.
      if (indirect.source.includes('__mpAgent')) { note('already-enforced'); return; }

      // Resuming replays completed agents whose (prompt, opts) are unchanged.
      // Adding a model changes opts, so injecting here would discard the cache and
      // re-run work that is already paid for. Enforcement is not worth that.
      if (toolInput.resumeFromRunId) { note('resume-preserves-cache'); return; }

      script = indirect.source;
    }

    // Scan code only. Comments and prompt strings routinely contain the words
    // "parallel"/"pipeline"/"model:", and matching those denies a script that is
    // perfectly fine — the one outcome worse than failing to optimise.
    const code = stripCodeNoise(script);
    const agentCalls = (code.match(/\bagent\s*\(/g) || []).length;
    const modelOpts = (code.match(/\bmodel\s*:/g) || []).length;

    // Counting literal `agent(` occurrences badly undercounts the idiomatic
    // fan-out, which spawns N agents from a single call site:
    //     await parallel(FILES.map(f => () => agent(...)))
    // That is one literal `agent(` and seven spawns. So treat any parallel() or
    // pipeline() containing an agent() as a fan-out regardless of literal count —
    // those constructs exist precisely to spawn many.
    const fanOut = /\b(parallel|pipeline)\s*\(/.test(code) && agentCalls > 0;
    const threshold = policy.workflow?.denyThreshold ?? 6;

    // Enforce by rewriting rather than by refusing. Denial only ever asked the
    // model to try again and hope; the shim guarantees a tier on every agent()
    // that did not pick one, and does it at runtime where the real prompt is
    // visible. Calls that set their own model are untouched.
    let injected = null;
    if (policy.workflow?.enforce !== false) {
      const sessionTier = sessionTierFor(input.session_id)
        || sessionTierFromTranscript(input.transcript_path);
      injected = injectWorkflowTiers(script, policy, sessionTier);
    }
    const enforced = Boolean(injected?.script);

    // Deny is now the fallback for scripts the rewriter could not prove safe:
    // an unparseable meta block, no agent() calls it can see, a mask desync.
    const deny = !enforced && modelOpts === 0 && (fanOut || agentCalls >= threshold);

    ledger({
      event: 'workflow',
      session_id: input.session_id,
      tool_use_id: input.tool_use_id,
      agent_calls: agentCalls,
      model_opts: modelOpts,
      fan_out: fanOut,
      form: indirect ? indirect.form : 'script',
      enforced,
      sites: injected?.sites ?? 0,
      nested: injected?.nested ?? 0,
      reason: injected?.reason ?? 'disabled',
      denied: deny,
    }, policy.limits?.ledgerMaxBytes);

    if (enforced) {
      // For an indirect invocation the rewritten source has to travel inline,
      // because scriptPath takes precedence over script and would win otherwise.
      const updatedInput = { ...toolInput, script: injected.script };
      if (indirect) {
        delete updatedInput.scriptPath;
        delete updatedInput.name;
      }
      emit({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'allow',
          permissionDecisionReason:
            `model-policy: tiered ${injected.sites} agent() call site(s)` +
            (indirect ? ` from ${indirect.form}` : '') +
            `; calls that set their own model were left as written.` +
            // The child of a nested workflow() is out of reach — measured, its
            // agents inherit the session model. Say so, because the child script
            // is usually written in the same turn and can still be tiered by hand.
            (injected.nested
              ? `\n\nNOTE: this script calls workflow() ${injected.nested} time(s). A nested ` +
                `workflow's script is NOT rewritten — its agent() calls will inherit this ` +
                `session's model. Set opts.model and opts.effort explicitly inside the child script.`
              : ''),
          updatedInput,
        },
      });
      return;
    }

    if (deny) {
      emit({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason:
            (fanOut
              ? `Model policy: this workflow fans out via parallel()/pipeline() and sets no model on any agent() call, `
              : `Model policy: this workflow has ${agentCalls} agent() calls with no model set on any of them, `) +
            `so every spawned agent would inherit the main session model — the most expensive option.\n\n` +
            `Re-emit the script with opts.model (and opts.effort where it helps) on each agent() call:\n  ${TIER_TABLE}\n\n` +
            `Example: agent(prompt, { model: 'haiku', effort: 'low', label: 'scan' })\n` +
            `A script with no fan-out and fewer than ${threshold} agent() calls is not checked.`,
        },
      });
    }
  }
}

main().catch(() => { /* fail open */ });
