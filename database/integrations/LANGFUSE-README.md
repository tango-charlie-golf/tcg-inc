# TCG Inc. — Langfuse Observability Integration

**Tango Charlie Golf Inc. · Integrit-E Architecture · Instance Zero**

This module adds full AI observability to the TCG system using [Langfuse](https://langfuse.com) — an open-source LLM tracing and evaluation platform. Every Claude API call made by the TCG engine is automatically traced, scored against Integrit-E guardrail rules, and logged with Eric-Gate decisions.

---

## What This Does

| Capability | Description |
|---|---|
| **Trace every AI call** | Prompt, output, token count, latency — all captured automatically |
| **Guardrail evaluation** | Each output is scored against the 5 Integrit-E invariants |
| **Eric-Gate logging** | APPROVED / REVISION / REJECTED decisions written back to each trace |
| **Prompt versioning** | System prompts managed in Langfuse UI — update without touching code |
| **Session grouping** | All calls for a project grouped into a single session |
| **Make.com / Relay.app** | Webhook handler for automation layer integration |

---

## File Structure

```
tcg-inc/
├── .env.example          ← copy to .env, fill in your keys
├── tcg-langfuse.js       ← this integration layer
├── database/
│   └── schema.sql        ← Supabase schema
└── ui/
    ├── command-center.jsx
    ├── landscape-3d.jsx
    └── unified-system.jsx
```

---

## Setup (5 Steps)

### Step 1 — Install dependencies

```bash
npm install @langfuse/langfuse @anthropic-ai/sdk
npm install @langfuse/otel @arizeai/openinference-instrumentation-anthropic
npm install @opentelemetry/sdk-node
```

### Step 2 — Create your .env file

```bash
cp .env.example .env
```

Open `.env` and fill in:
- `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY` — from [cloud.langfuse.com](https://cloud.langfuse.com) → Your Project → Settings → API Keys
- `ANTHROPIC_API_KEY` — from [console.anthropic.com](https://console.anthropic.com)
- `SUPABASE_URL` and keys — from your Supabase project settings

### Step 3 — Initialize at app startup

Add this to your entry point (e.g. `index.js` or `app.js`):

```js
import { initTCGObservability } from "./tcg-langfuse.js";
initTCGObservability();
```

After this line runs, **every Anthropic SDK call in your entire application is automatically traced**. No other changes required.

### Step 4 — Replace raw fetch() calls with TCGEngine

Before (raw fetch in the UI):
```js
const res = await fetch("https://api.anthropic.com/v1/messages", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ model: "claude-sonnet-4-20250514", ... }),
});
```

After (TCGEngine with full observability):
```js
import { TCGEngine } from "./tcg-langfuse.js";

const { content, traceId, usage } = await TCGEngine.run({
  userPrompt:  "Draft a grant narrative for...",
  vertical:    "LA",
  outputType:  "Grant Narrative",
  projectId:   "your-supabase-uuid",
  projectName: "Riverside Community Garden",
});
```

That's the only change. Same output. Full tracing added.

### Step 5 — Open your Langfuse dashboard

Go to [cloud.langfuse.com](https://cloud.langfuse.com) → your project.

You will immediately see:
- **Traces** — every TCG AI call with input, output, tokens, latency
- **Scores** — guardrail pass/fail per Integrit-E invariant
- **Sessions** — all calls for a project grouped together
- **Prompts** — version-controlled TCG system prompts

---

## Vertical-Specific Functions

```js
import {
  generateGrantNarrative,
  generateClientProposal,
  generateZoneBrief,
  generateBlueprint,
} from "./tcg-langfuse.js";

// LA / CD — Grant
const grant = await generateGrantNarrative({
  projectName: "Riverside Community Garden",
  projectId:   "uuid",
  vertical:    "LA",
  scope:       "Multi-zone urban garden...",
  funderName:  "USDA Community Facilities Program",
  amount:      "$48,000",
});

// TA / Contract
const proposal = await generateClientProposal({
  projectName: "AI Workflow Automation Suite",
  projectId:   "uuid",
  vertical:    "TA",
  scope:       "End-to-end AI workflow automation...",
  amount:      "$75,000",
});

// LA — 3D Zone Brief
const zoneBrief = await generateZoneBrief({
  projectName: "Riverside Community Garden",
  projectId:   "uuid",
  zoneLabel:   "Water Feature",
  zoneType:    "Water Feature",
  materials:   ["native stone", "reclaimed timber"],
  plantList:   ["Horsetail Reed", "Blue Flag Iris"],
});

// Any vertical — Full Blueprint
const blueprint = await generateBlueprint({
  projectName: "Digital Literacy Program",
  projectId:   "uuid",
  vertical:    "CD",
  fundingType: "Grant",
  amount:      "$62,000",
  scope:       "Structured digital skills curriculum...",
});
```

---

## Guardrail Evaluation

Run Integrit-E guardrail checks on any generated output:

```js
import { TCGEngine } from "./tcg-langfuse.js";

const { content, traceId } = await generateGrantNarrative({ ... });

// Fetch your active rules from Supabase
const { data: rules } = await supabase
  .from("guardrail_rules")
  .select("*")
  .eq("is_active", true);

const evalResult = await TCGEngine.evaluate({
  content,
  traceId,
  vertical:    "CD",
  outputType:  "Grant Narrative",
  fundingType: "Grant",
  rules,
});

if (!evalResult.passed) {
  console.log("Flags:", evalResult.flags);
  // → update ai_outputs.gate_status to 'FLAGGED' in Supabase
  // → Relay.app pauses the workflow for Eric review
} else {
  // → proceed to delivery
}
```

---

## Eric-Gate Decision Logging

After reviewing in the Relay.app dashboard or TCG Command Center:

```js
TCGEngine.logGateDecision({
  traceId:  "lf-trace-id",
  decision: "APPROVED",   // APPROVED | REVISION | REJECTED | FLAGGED
  note:     "Solid narrative. Send to client.",
});
```

This writes the decision back to the Langfuse trace as a human score, creating a full audit trail of every gate decision.

---

## Make.com / Relay.app Webhook

Deploy `handleAutomationWebhook` as a serverless function. Then point your Make.com HTTP module or Relay.app action at that URL with a JSON body:

```json
{
  "action":      "generate_grant",
  "projectId":   "uuid",
  "projectName": "Riverside Community Garden",
  "vertical":    "LA",
  "fundingType": "Grant",
  "amount":      "$48,000",
  "scope":       "Multi-zone urban garden...",
  "funderName":  "USDA Community Facilities Program"
}
```

Supported actions: `generate_grant`, `generate_proposal`, `generate_blueprint`, `generate_zone_brief`, `gate_decision`

---

## Integrit-E Invariants Tracked

| ID | Invariant | What Langfuse Captures |
|---|---|---|
| DG | Deterministic Gates | Pass/fail score per guardrail rule |
| FD | Fail-Safe Default | Flagged if fabricated data detected |
| TV | Truth Verification | Flagged if unverified grant programs named |
| OI | Organic Integration | Latency + token usage trends over time |
| SI | Singular Integrity | Brand voice check score per output |

---

## What Goes in .gitignore

```
.env
node_modules/
```

The `.env.example` file **is** committed — it shows collaborators and reviewers exactly what keys are needed without exposing the actual values.

---

## Author

**Eric** — Chief Resilience Officer, Tango Charlie Golf Inc.  
Methodology: Integrit-E · Truth-Driven Resilience Architecture  
Mission: *"I build systems that create security for myself and strategic clarity for others."*
