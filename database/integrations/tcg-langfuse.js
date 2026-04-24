// ═══════════════════════════════════════════════════════════════
//  TCG INC. — LANGFUSE TRACING LAYER  (v2.0)
//  Tango Charlie Golf Inc. · Integrit-E Architecture
//
//  Written against: @langfuse/tracing (JS SDK v4)
//  Best practices sourced from: langfuse.com/docs + langfuse/skills
//
//  INSTALL:
//    npm install @langfuse/tracing @anthropic-ai/sdk langfuse
//
//  .env (copy .env.example → .env):
//    LANGFUSE_PUBLIC_KEY=pk-lf-...
//    LANGFUSE_SECRET_KEY=sk-lf-...
//    LANGFUSE_HOST=https://us.cloud.langfuse.com
//    ANTHROPIC_API_KEY=sk-ant-...
// ═══════════════════════════════════════════════════════════════

import Anthropic                          from "@anthropic-ai/sdk";
import { Langfuse }                       from "langfuse";
import {
  startActiveObservation,
  startObservation,
  updateActiveObservation,
}                                         from "@langfuse/tracing";

// ───────────────────────────────────────────────────────────────
// CLIENTS
// One shared instance of each — never instantiate per-request.
// ───────────────────────────────────────────────────────────────

export const anthropic = new Anthropic({
  apiKey: process.env.ANTHROPIC_API_KEY,
});

// Langfuse client — used for scoring, sessions, prompt management.
// SDK v4 reads LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY / LANGFUSE_HOST
// from env automatically. No constructor args needed.
export const langfuse = new Langfuse();

// TCG single source-of-truth system prompt.
// In production, replace this with: await getPrompt("tcg-system")
export const TCG_SYSTEM = `You are the TCG Inc. AI operations engine — Tango Charlie Golf Inc., founded by Eric, Chief Resilience Officer. TCG operates across three verticals: Landscape Architecture (LA), Tech Stack Architecture (TA), and Community Development (CD). The governing methodology is Integrit-E — a Truth-Driven Resilience Architecture with 5 constitutional invariants: Deterministic Gates, Fail-Safe Default, Truth Verification, Organic Integration, Singular Integrity. TCG mission: "I build systems that create security for myself and strategic clarity for others." Brand voice: construction-analogy, engineering-rooted, bold, no spiritual language, no filler. Be concise, strategic, and decisive.`;


// ───────────────────────────────────────────────────────────────
// SECTION 1: CORE ENGINE — startActiveObservation pattern
//
// Best practice: wrap every multi-step operation in a root span,
// then nest the generation inside it. This gives you a clean
// trace hierarchy in Langfuse: pipeline → llm-call.
// ───────────────────────────────────────────────────────────────

/**
 * TCGEngine.run()
 * Executes a Claude generation fully traced in Langfuse.
 *
 * Trace structure produced:
 *   tcg-pipeline (span)
 *     └── claude-generation (generation)
 *
 * @param {object} p
 * @param {string} p.userPrompt    - Prompt to send to Claude
 * @param {string} p.vertical      - 'LA' | 'TA' | 'CD'
 * @param {string} p.outputType    - e.g. 'Grant Narrative'
 * @param {string} p.projectId     - Supabase project UUID
 * @param {string} p.projectName   - Human-readable project name
 * @param {string} [p.sessionId]   - Groups multiple traces together
 * @param {string} [p.userId]      - Defaults to 'eric'
 * @param {string} [p.environment] - 'production' | 'development'
 * @param {string} [p.systemPrompt]- Override default TCG system prompt
 * @returns {Promise<{content: string, traceId: string, usage: object}>}
 */
export const TCGEngine = {

  async run({
    userPrompt,
    vertical,
    outputType,
    projectId,
    projectName,
    sessionId,
    userId      = "eric",
    environment = process.env.NODE_ENV ?? "development",
    systemPrompt = TCG_SYSTEM,
  }) {
    let result = {};

    // Root span: represents the full pipeline step
    await startActiveObservation(
      `tcg-${vertical?.toLowerCase()}-${outputType?.toLowerCase().replace(/ /g, "-")}`,
      async (rootSpan) => {

        // Attach trace-level attributes to the root span
        rootSpan.update({
          input:  { userPrompt },
          userId,
          sessionId: sessionId ?? `project-${projectId}`,
          metadata: {
            vertical,
            outputType,
            projectId,
            projectName,
            environment,
          },
          tags: [
            `vertical:${vertical}`,
            `output:${outputType?.replace(/ /g, "-").toLowerCase()}`,
            "tcg-engine",
            "integrit-e",
          ],
        });

        // Nested generation span: represents the Claude API call itself
        const generation = rootSpan.startObservation(
          "claude-generation",
          {
            input: [
              { role: "system", content: systemPrompt },
              { role: "user",   content: userPrompt },
            ],
            model:    "claude-sonnet-4-20250514",
            metadata: { vertical, outputType },
          },
          { asType: "generation" }
        );

        try {
          const response = await anthropic.messages.create({
            model:      "claude-sonnet-4-20250514",
            max_tokens: 1000,
            system:     systemPrompt,
            messages:   [{ role: "user", content: userPrompt }],
          });

          const content = response.content
            ?.map(b => b.text ?? "")
            .join("") ?? "";

          const usage = {
            input:  response.usage?.input_tokens  ?? 0,
            output: response.usage?.output_tokens ?? 0,
            total: (response.usage?.input_tokens  ?? 0)
                 + (response.usage?.output_tokens ?? 0),
          };

          // Update generation with output + usage
          generation.update({
            output:       content,
            usageDetails: { input: usage.input, output: usage.output },
          }).end();

          // Update root span output
          rootSpan.update({ output: { content, usage } });

          result = {
            content,
            traceId: rootSpan.id,
            usage,
          };

        } catch (error) {
          generation.update({
            metadata: { error: true, errorMessage: error.message },
            level:    "ERROR",
          }).end();

          rootSpan.update({
            metadata: { error: true },
            level:    "ERROR",
          });

          throw error;
        }
      }
    );

    // Best practice: flush after each call in dev/serverless environments.
    // In long-running servers, remove this — the SDK batches automatically.
    await langfuse.flushAsync();

    return result;
  },


  // ─────────────────────────────────────────────────────────────
  // SECTION 2: GUARDRAIL EVALUATOR
  //
  // Runs each active Integrit-E guardrail rule as a Claude-as-judge
  // sub-call, nested under the parent trace as sibling spans.
  // Scores are posted back to Langfuse via langfuse.score().
  // ─────────────────────────────────────────────────────────────

  /**
   * TCGEngine.evaluate()
   * @param {object} p
   * @param {string} p.content      - AI output to evaluate
   * @param {string} p.traceId      - Langfuse trace ID from .run()
   * @param {string} p.vertical     - 'LA' | 'TA' | 'CD'
   * @param {string} p.outputType   - Output type string
   * @param {string} p.fundingType  - 'Grant' | 'Contract' | etc.
   * @param {Array}  p.rules        - Rows from Supabase guardrail_rules
   * @returns {Promise<{passed: boolean, flags: Array, scores: Array}>}
   */
  async evaluate({ content, traceId, vertical, outputType, fundingType, rules = [] }) {

    // Filter to rules that apply to this vertical / output type / funding type
    const applicable = rules.filter(r =>
      r.is_active &&
      (!r.vertical     || r.vertical     === vertical)   &&
      (!r.output_type  || r.output_type  === outputType) &&
      (!r.funding_type || r.funding_type === fundingType)
    );

    const flags  = [];
    const scores = [];

    for (const rule of applicable) {

      // Each guardrail check is its own traced span
      await startActiveObservation(`guardrail-${rule.invariant_id}`, async (span) => {
        span.update({
          input:    { rule: rule.rule_label, content },
          metadata: { invariantId: rule.invariant_id, ruleId: rule.id },
          tags:     ["guardrail", `invariant:${rule.invariant_id}`],
        });

        const evalResponse = await anthropic.messages.create({
          model:      "claude-sonnet-4-20250514",
          max_tokens: 150,
          system:     "You are an evaluation judge for the TCG Inc. Integrit-E guardrail system. Answer with PASS or FAIL only, followed by one sentence of explanation if FAIL.",
          messages:   [{
            role:    "user",
            content: `${rule.rule_prompt}\n\n---\nCONTENT TO EVALUATE:\n${content}`,
          }],
        });

        const evalText = evalResponse.content?.[0]?.text ?? "";
        const passed   = evalText.trim().toUpperCase().startsWith("PASS");

        span.update({
          output:   { result: passed ? "PASS" : "FAIL", evalText },
          metadata: { passed },
        });

        // Post score to the original generation trace
        langfuse.score({
          traceId,
          name:     rule.rule_label,
          value:    passed ? 1 : 0,
          comment:  evalText,
          dataType: "BOOLEAN",
        });

        scores.push({ ruleId: rule.id, ruleLabel: rule.rule_label, invariantId: rule.invariant_id, passed, evalText });

        if (!passed) {
          flags.push({
            invariant:  rule.invariant_id,
            rule:       rule.rule_label,
            failAction: rule.fail_action,
            message:    evalText,
          });
        }
      });
    }

    await langfuse.flushAsync();
    return { passed: flags.length === 0, flags, scores, rulesChecked: applicable.length };
  },


  // ─────────────────────────────────────────────────────────────
  // SECTION 3: ERIC-GATE DECISION LOGGER
  //
  // Posts a human score to the trace every time Eric makes a
  // gate decision. Creates a full audit trail in Langfuse.
  // ─────────────────────────────────────────────────────────────

  /**
   * TCGEngine.logGateDecision()
   * @param {object} p
   * @param {string} p.traceId   - Langfuse trace ID
   * @param {string} p.decision  - 'APPROVED' | 'REJECTED' | 'REVISION' | 'FLAGGED'
   * @param {string} [p.note]    - Eric's review comment
   */
  async logGateDecision({ traceId, decision, note = "" }) {
    const value = decision === "APPROVED" ? 1
                : decision === "REVISION" ? 0.5
                : 0;

    langfuse.score({
      traceId,
      name:     "eric-gate",
      value,
      comment:  `${decision}${note ? ` — ${note}` : ""}`,
      dataType: "NUMERIC",
    });

    await langfuse.flushAsync();
    console.log(`[TCG Eric-Gate] ${decision} logged → trace ${traceId}`);
  },


  // ─────────────────────────────────────────────────────────────
  // SECTION 4: PROMPT MANAGEMENT
  //
  // Best practice: store all TCG prompts in Langfuse.
  // Edit them in the Langfuse UI → changes take effect instantly
  // without a code deploy. Falls back to hardcoded default if
  // the prompt hasn't been created in Langfuse yet.
  // ─────────────────────────────────────────────────────────────

  /**
   * TCGEngine.getPrompt()
   * @param {string} name       - Prompt name in Langfuse library
   * @param {object} variables  - Template variables to compile into the prompt
   * @returns {Promise<{prompt: string, langfusePrompt: object|null}>}
   */
  async getPrompt(name, variables = {}) {
    try {
      const langfusePrompt = await langfuse.getPrompt(name);
      const compiled = langfusePrompt.compile(variables);
      return { prompt: compiled, langfusePrompt };
    } catch {
      console.warn(`[TCG] Prompt "${name}" not in Langfuse yet — using local default.`);
      return { prompt: TCG_SYSTEM, langfusePrompt: null };
    }
  },
};


// ───────────────────────────────────────────────────────────────
// SECTION 5: VERTICAL GENERATORS
// Thin wrappers that build the right prompt and call TCGEngine.run()
// ───────────────────────────────────────────────────────────────

export async function generateGrantNarrative({ projectName, projectId, vertical, scope, funderName, amount, sessionId }) {
  const userPrompt = `Write a compelling 2-paragraph grant narrative for the following TCG project.

Project: ${projectName}
Vertical: ${vertical}
Funding Target: ${amount}
Funder: ${funderName}
Scope: ${scope}

Include: (1) community need and impact, (2) TCG design approach and methodology, (3) funding justification. No fabricated statistics. TCG Integrit-E brand voice.`;

  return TCGEngine.run({ userPrompt, vertical, outputType: "Grant Narrative", projectId, projectName, sessionId });
}

export async function generateClientProposal({ projectName, projectId, vertical, scope, amount, sessionId }) {
  const userPrompt = `Write a client-ready project proposal for the following TCG engagement.

Project: ${projectName}
Vertical: ${vertical}
Contract Value: ${amount}
Scope: ${scope}

Sections required: Executive Summary, Scope of Work, Deliverables, Timeline (general), Investment. TCG brand voice. Engineering-rooted.`;

  return TCGEngine.run({ userPrompt, vertical, outputType: "Client Proposal", projectId, projectName, sessionId });
}

export async function generateZoneBrief({ projectName, projectId, zoneLabel, zoneType, materials, plantList, sessionId }) {
  const userPrompt = `Write a concise design brief (3–4 sentences) for the following landscape site zone.

Project: ${projectName}
Zone: ${zoneLabel} (${zoneType})
Materials: ${materials?.join(", ") ?? "TBD"}
Plant List: ${plantList?.join(", ") ?? "TBD"}

Include: design intent, material rationale, community benefit. TCG LA voice.`;

  return TCGEngine.run({ userPrompt, vertical: "LA", outputType: "Zone Brief", projectId, projectName, sessionId });
}

export async function generateBlueprint({ projectName, projectId, vertical, fundingType, amount, siteAddress, scope, sessionId }) {
  const userPrompt = `Generate a complete client-ready project blueprint for TCG Inc.

Project: ${projectName}
Vertical: ${vertical}
Site: ${siteAddress ?? "Address TBD"}
Funding: ${fundingType} · ${amount}
Scope: ${scope}

Sections required:
1. Executive Summary (2 sentences)
2. Site & Scope Overview
3. Design Intent
4. Funding Justification
5. Deliverables List
6. Next Steps

Format with clear section headers. TCG Integrit-E brand voice.`;

  return TCGEngine.run({ userPrompt, vertical, outputType: "Blueprint", projectId, projectName, sessionId });
}


// ───────────────────────────────────────────────────────────────
// SECTION 6: AUTOMATION WEBHOOK HANDLER
// Deploy as a Supabase Edge Function or serverless function.
// Point Make.com HTTP module or Relay.app at this endpoint.
// ───────────────────────────────────────────────────────────────

/**
 * handleWebhook()
 * Supported actions: generate_grant | generate_proposal |
 *                    generate_blueprint | generate_zone_brief | gate_decision
 */
export async function handleWebhook(body) {
  const { action, ...rest } = body;

  switch (action) {
    case "generate_grant":       return generateGrantNarrative(rest);
    case "generate_proposal":    return generateClientProposal(rest);
    case "generate_blueprint":   return generateBlueprint(rest);
    case "generate_zone_brief":  return generateZoneBrief(rest);
    case "gate_decision":        return TCGEngine.logGateDecision(rest);
    default: throw new Error(`[TCG] Unknown webhook action: ${action}`);
  }
}


// ───────────────────────────────────────────────────────────────
// SECTION 7: USAGE EXAMPLES
// Uncomment any block to test. Run: node --env-file=.env tcg-langfuse.js
// ───────────────────────────────────────────────────────────────

/*
// ── Example 1: Generate and trace a grant narrative ───────────
const result = await generateGrantNarrative({
  projectName: "Riverside Community Garden",
  projectId:   "your-supabase-uuid",
  vertical:    "LA",
  scope:       "Multi-zone urban garden with water feature, raised beds, native plant corridors.",
  funderName:  "USDA Community Facilities Program",
  amount:      "$48,000",
  sessionId:   "session-riverside-2026",
});

console.log("Content:", result.content);
console.log("Trace ID:", result.traceId);  // → paste into Langfuse UI
console.log("Usage:", result.usage);

// ── Example 2: Run Integrit-E guardrail eval ──────────────────
// First fetch your active rules from Supabase:
// const { data: rules } = await supabase.from("guardrail_rules").select("*").eq("is_active", true);

const evalResult = await TCGEngine.evaluate({
  content:     result.content,
  traceId:     result.traceId,
  vertical:    "LA",
  outputType:  "Grant Narrative",
  fundingType: "Grant",
  rules,       // from Supabase
});

if (!evalResult.passed) {
  console.log("FLAGGED — invariant violations:", evalResult.flags);
  // → set ai_outputs.gate_status = 'FLAGGED' in Supabase
  // → Relay.app pauses workflow, routes to Eric-Gate
} else {
  console.log("All guardrails passed. Routing to Eric-Gate for final review.");
  // → set ai_outputs.gate_status = 'PENDING' in Supabase
}

// ── Example 3: Log Eric's gate decision ───────────────────────
await TCGEngine.logGateDecision({
  traceId:  result.traceId,
  decision: "APPROVED",
  note:     "Strong narrative. Approved for client delivery.",
});
// → Score appears on trace in Langfuse under "eric-gate"
// → Update ai_outputs.gate_status = 'APPROVED' in Supabase

// ── Example 4: Use Langfuse-managed prompt ────────────────────
// First create a prompt named "tcg-system" in Langfuse UI.
// Then retrieve it:
const { prompt, langfusePrompt } = await TCGEngine.getPrompt("tcg-system", {
  vertical: "CD",
});
// Pass prompt as systemPrompt override:
const result2 = await TCGEngine.run({
  userPrompt:   "Draft a grant narrative for the Digital Literacy Program...",
  vertical:     "CD",
  outputType:   "Grant Narrative",
  projectId:    "uuid",
  projectName:  "Digital Literacy Program",
  systemPrompt: prompt,  // ← Langfuse-managed version
});
*/
