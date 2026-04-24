-- ═══════════════════════════════════════════════════════════════
--  TCG INC. — DATABASE SCHEMA (DRAFT v1.0)
--  Tango Charlie Golf Inc. · Integrit-E Architecture
--  Author: Eric · Chief Resilience Officer
--
--  STATUS: Portfolio Draft — illustrates full system architecture.
--  Tables are ordered to resolve all foreign key dependencies.
--
--  To run: Supabase Dashboard → SQL Editor → paste → Run
-- ═══════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────
-- PREREQUISITES
-- ───────────────────────────────────────────────────────────────

create extension if not exists "uuid-ossp";

-- ───────────────────────────────────────────────────────────────
-- SECTION 1: ENUMERATIONS
-- Deterministic value sets — no freetext on critical fields.
-- ───────────────────────────────────────────────────────────────

create type vertical_type as enum (
  'LA',   -- Landscape Architecture
  'TA',   -- Tech Stack Architecture
  'CD'    -- Community Development
);

create type funding_type as enum (
  'Grant',
  'Contract',
  'Retainer',
  'Donation'
);

create type project_stage as enum (
  'Discovery',
  'Proposal',
  'Design Dev',
  'Build',
  'Active',
  'Complete',
  'Archived'
);

create type gate_status as enum (
  'PENDING',    -- Awaiting Eric review
  'APPROVED',   -- Cleared for client delivery
  'REVISION',   -- Returned for AI rework
  'REJECTED',   -- Hard no
  'FLAGGED'     -- Vellum guardrail failed
);

create type risk_level as enum ('LOW', 'MED', 'HIGH');

create type output_type as enum (
  'Grant Narrative',
  'Client Proposal',
  'Scope Summary',
  'Executive Summary',
  'Zone Brief',
  'Blueprint',
  'Site Plan'
);

create type invariant_id as enum (
  'DG',  -- Deterministic Gates
  'FD',  -- Fail-Safe Default
  'TV',  -- Truth Verification
  'OI',  -- Organic Integration
  'SI'   -- Singular Integrity
);

-- ───────────────────────────────────────────────────────────────
-- SECTION 2: TABLES
-- Order matters — referenced tables must come first.
-- clients → projects → ai_outputs → gate_log
-- ───────────────────────────────────────────────────────────────

-- ── 2A. CLIENTS ───────────────────────────────────────────────
-- Created first because projects.client_id references this table.

create table clients (
  id           uuid        primary key default uuid_generate_v4(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  name         text        not null,
  org_name     text,
  email        text        unique,
  phone        text,
  vertical     vertical_type,
  source       text,   -- 'Calendly' | 'Referral' | 'LinkedIn' | etc.
  notes        text,
  is_active    boolean     not null default true
);

-- ── 2B. PROJECTS ──────────────────────────────────────────────
-- Central truth record for every TCG engagement.

create table projects (
  id               uuid          primary key default uuid_generate_v4(),
  created_at       timestamptz   not null default now(),
  updated_at       timestamptz   not null default now(),

  -- Identity
  name             text          not null,
  vertical         vertical_type not null,
  stage            project_stage not null default 'Discovery',
  description      text,

  -- Site (consumed by 3D Landscape Viewer)
  site_address     text,
  site_lat         numeric(10,7),
  site_lng         numeric(10,7),

  -- Funding
  funding_type     funding_type  not null,
  funding_target   numeric(12,2),
  funding_secured  numeric(12,2) default 0,

  -- Progress 0–100
  progress_pct     smallint      default 0
    check (progress_pct between 0 and 100),

  -- Flags
  is_active        boolean       not null default true,
  is_template      boolean       not null default false,

  -- Optional client link (clients must exist first — see 2A)
  client_id        uuid          references clients(id) on delete set null,

  constraint projects_name_not_empty check (char_length(name) > 0)
);

-- ── 2C. AI OUTPUTS ────────────────────────────────────────────
-- Every Claude-generated deliverable. Source of truth for Eric-Gate queue.

create table ai_outputs (
  id             uuid          primary key default uuid_generate_v4(),
  created_at     timestamptz   not null default now(),
  updated_at     timestamptz   not null default now(),

  project_id     uuid          not null references projects(id) on delete cascade,
  output_type    output_type   not null,
  vertical       vertical_type not null,

  -- Content
  prompt_used    text,
  content        text          not null,
  model_used     text          default 'claude-sonnet-4-20250514',
  token_count    integer,
  version        integer       not null default 1,

  -- Gate
  gate_status    gate_status   not null default 'PENDING',
  risk_level     risk_level    default 'LOW',
  eric_note      text,
  reviewed_at    timestamptz,
  approved_at    timestamptz,

  -- Vellum eval result (written by automation layer)
  vellum_passed  boolean,
  vellum_flags   jsonb         default '[]'::jsonb
  -- example: [{"invariant":"TV","message":"Economic risk section missing"}]
);

-- ── 2D. GATE LOG ──────────────────────────────────────────────
-- Immutable audit trail. Written by trigger only — never edited manually.
-- Every gate decision is permanently recorded here.

create table gate_log (
  id              uuid         primary key default uuid_generate_v4(),
  logged_at       timestamptz  not null default now(),

  ai_output_id    uuid         not null references ai_outputs(id) on delete restrict,
  project_id      uuid         not null references projects(id)   on delete restrict,

  action          gate_status  not null,
  invariant_id    invariant_id,              -- which invariant triggered (if flagged)
  triggered_by    text         not null default 'ERIC',
  note            text,
  previous_status gate_status
);

-- ── 2E. GUARDRAIL RULES ───────────────────────────────────────
-- The live Integrit-E ruleset evaluated by Vellum before every delivery.
-- null vertical/output_type/funding_type = applies to all.

create table guardrail_rules (
  id             uuid          primary key default uuid_generate_v4(),
  created_at     timestamptz   not null default now(),
  updated_at     timestamptz   not null default now(),

  invariant_id   invariant_id  not null,
  vertical       vertical_type,
  output_type    output_type,
  funding_type   funding_type,

  rule_label     text          not null,
  rule_condition text          not null,  -- human-readable IF/THEN
  rule_prompt    text          not null,  -- exact eval prompt sent to Vellum
  fail_action    gate_status   not null default 'FLAGGED',
  is_active      boolean       not null default true
);

-- ── 2F. SITE PLANS ────────────────────────────────────────────
-- Container for a landscape site design. One project, many versioned plans.

create table site_plans (
  id               uuid        primary key default uuid_generate_v4(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  project_id       uuid        not null references projects(id) on delete cascade,
  plan_name        text        not null default 'Primary Site Plan',
  version          integer     not null default 1,
  is_active        boolean     not null default true,

  map_snapshot_url text,
  map_lat          numeric(10,7),
  map_lng          numeric(10,7),
  map_zoom         smallint    default 18
);

-- ── 2G. SITE ZONES ────────────────────────────────────────────
-- Individual design zones within a site plan.
-- pos_x, pos_z, width, depth, height feed the Three.js 3D viewer.

create table site_zones (
  id           uuid        primary key default uuid_generate_v4(),
  created_at   timestamptz not null default now(),

  site_plan_id uuid        not null references site_plans(id) on delete cascade,
  zone_label   text        not null,
  zone_type    text,
  color_hex    text        default '#4ade80',

  -- 3D scene positioning
  pos_x        numeric(6,2) default 0,
  pos_z        numeric(6,2) default 0,
  width        numeric(6,2) default 4,
  depth        numeric(6,2) default 4,
  height       numeric(6,2) default 0.6,

  -- Design content
  materials    text[],   -- ['decomposed granite', 'native stone', 'cedar']
  plant_list   text[],   -- ['Live Oak', 'Buffalo Grass', 'Black-Eyed Susan']
  notes        text,
  ai_brief     text      -- Claude-generated zone design brief
);

-- ── 2H. FUNDING APPLICATIONS ──────────────────────────────────

create table funding_applications (
  id               uuid         primary key default uuid_generate_v4(),
  created_at       timestamptz  not null default now(),
  updated_at       timestamptz  not null default now(),

  project_id       uuid         not null references projects(id) on delete cascade,
  funding_type     funding_type not null,

  funder_name      text         not null,
  program_name     text,
  amount_requested numeric(12,2),
  amount_awarded   numeric(12,2),
  deadline         date,
  submitted_at     timestamptz,
  decision_at      timestamptz,

  -- 'Draft'|'In Review'|'Submitted'|'Awarded'|'Declined'|'Waitlisted'
  status           text         not null default 'Draft',

  narrative_id     uuid         references ai_outputs(id) on delete set null,
  notes            text
);

-- ── 2I. AUTOMATION LOG ────────────────────────────────────────
-- Every Make.com / Relay.app event that touches TCG data.

create table automation_log (
  id             uuid        primary key default uuid_generate_v4(),
  logged_at      timestamptz not null default now(),

  source         text        not null,  -- 'make.com'|'relay.app'|'vellum'|'manual'
  event_type     text        not null,  -- 'intake_received'|'output_generated'|etc.
  project_id     uuid        references projects(id)   on delete set null,
  ai_output_id   uuid        references ai_outputs(id) on delete set null,
  payload        jsonb,
  success        boolean     not null default true,
  error_message  text
);

-- ───────────────────────────────────────────────────────────────
-- SECTION 3: INDEXES
-- ───────────────────────────────────────────────────────────────

create index idx_projects_vertical   on projects(vertical);
create index idx_projects_stage      on projects(stage);
create index idx_projects_active     on projects(is_active);
create index idx_projects_client     on projects(client_id);

create index idx_outputs_project     on ai_outputs(project_id);
create index idx_outputs_status      on ai_outputs(gate_status);
create index idx_outputs_pending     on ai_outputs(gate_status) where gate_status = 'PENDING';
create index idx_outputs_flagged     on ai_outputs(gate_status) where gate_status = 'FLAGGED';

create index idx_gate_log_output     on gate_log(ai_output_id);
create index idx_gate_log_project    on gate_log(project_id);
create index idx_gate_log_time       on gate_log(logged_at desc);

create index idx_guardrails_active   on guardrail_rules(is_active) where is_active = true;
create index idx_guardrails_vertical on guardrail_rules(vertical);

create index idx_zones_plan          on site_zones(site_plan_id);
create index idx_funding_project     on funding_applications(project_id);
create index idx_automation_time     on automation_log(logged_at desc);

-- ───────────────────────────────────────────────────────────────
-- SECTION 4: FUNCTIONS & TRIGGERS
-- ───────────────────────────────────────────────────────────────

-- Auto-stamp updated_at
create or replace function update_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger trg_clients_updated
  before update on clients
  for each row execute function update_updated_at();

create trigger trg_projects_updated
  before update on projects
  for each row execute function update_updated_at();

create trigger trg_ai_outputs_updated
  before update on ai_outputs
  for each row execute function update_updated_at();

create trigger trg_guardrails_updated
  before update on guardrail_rules
  for each row execute function update_updated_at();

create trigger trg_site_plans_updated
  before update on site_plans
  for each row execute function update_updated_at();

create trigger trg_funding_updated
  before update on funding_applications
  for each row execute function update_updated_at();

-- Auto-write gate_log whenever ai_outputs.gate_status changes
create or replace function log_gate_change()
returns trigger language plpgsql as $$
begin
  if old.gate_status is distinct from new.gate_status then
    insert into gate_log (
      ai_output_id, project_id, action,
      triggered_by, note, previous_status
    ) values (
      new.id, new.project_id, new.gate_status,
      'SYSTEM', new.eric_note, old.gate_status
    );
  end if;
  return new;
end;
$$;

create trigger trg_gate_log
  after update on ai_outputs
  for each row execute function log_gate_change();

-- ───────────────────────────────────────────────────────────────
-- SECTION 5: ROW LEVEL SECURITY
-- Authenticated users (Eric's dashboard) get full access.
-- service_role key (Make.com, Relay.app) bypasses RLS by default.
-- ───────────────────────────────────────────────────────────────

alter table clients              enable row level security;
alter table projects             enable row level security;
alter table ai_outputs           enable row level security;
alter table gate_log             enable row level security;
alter table guardrail_rules      enable row level security;
alter table site_plans           enable row level security;
alter table site_zones           enable row level security;
alter table funding_applications enable row level security;
alter table automation_log       enable row level security;

create policy "auth_full" on clients
  for all to authenticated using (true) with check (true);
create policy "auth_full" on projects
  for all to authenticated using (true) with check (true);
create policy "auth_full" on ai_outputs
  for all to authenticated using (true) with check (true);
create policy "auth_read" on gate_log
  for select to authenticated using (true);
create policy "auth_full" on guardrail_rules
  for all to authenticated using (true) with check (true);
create policy "auth_full" on site_plans
  for all to authenticated using (true) with check (true);
create policy "auth_full" on site_zones
  for all to authenticated using (true) with check (true);
create policy "auth_full" on funding_applications
  for all to authenticated using (true) with check (true);
create policy "auth_read" on automation_log
  for select to authenticated using (true);

-- ───────────────────────────────────────────────────────────────
-- SECTION 6: VIEWS
-- ───────────────────────────────────────────────────────────────

create or replace view v_project_pipeline as
select
  p.id, p.name, p.vertical, p.stage,
  p.funding_type, p.funding_target, p.funding_secured, p.progress_pct,
  p.site_address,
  c.name  as client_name,
  c.email as client_email,
  (select count(*) from ai_outputs ao
   where ao.project_id = p.id and ao.gate_status = 'PENDING') as pending_reviews,
  (select count(*) from ai_outputs ao
   where ao.project_id = p.id and ao.gate_status = 'FLAGGED') as flagged_outputs,
  p.created_at, p.updated_at
from projects p
left join clients c on c.id = p.client_id
where p.is_active = true
order by p.updated_at desc;

create or replace view v_gate_queue as
select
  ao.id, ao.created_at, ao.output_type, ao.vertical,
  ao.gate_status, ao.risk_level, ao.vellum_passed, ao.vellum_flags,
  ao.eric_note, ao.content,
  p.name as project_name, p.stage as project_stage, p.funding_type
from ai_outputs ao
join projects p on p.id = ao.project_id
where ao.gate_status in ('PENDING', 'FLAGGED')
order by
  case ao.gate_status when 'FLAGGED' then 0 else 1 end,
  ao.created_at asc;

create or replace view v_funding_summary as
select
  vertical, funding_type,
  count(*)                 as project_count,
  sum(funding_target)      as total_target,
  sum(funding_secured)     as total_secured,
  round(avg(progress_pct)) as avg_progress
from projects
where is_active = true
group by vertical, funding_type
order by vertical, funding_type;

create or replace view v_active_guardrails as
select
  id, invariant_id, vertical, output_type, funding_type,
  rule_label, rule_condition, rule_prompt, fail_action
from guardrail_rules
where is_active = true
order by invariant_id, vertical;

-- ───────────────────────────────────────────────────────────────
-- SECTION 7: SEED DATA
-- ───────────────────────────────────────────────────────────────

insert into guardrail_rules
  (invariant_id, vertical, output_type, funding_type,
   rule_label, rule_condition, rule_prompt, fail_action)
values
  ('DG', 'CD', 'Grant Narrative', 'Grant',
   'CD Grant: Economic Risk Section Required',
   'IF vertical=CD AND output_type=Grant Narrative AND funding_type=Grant THEN content MUST include economic risk or community impact analysis.',
   'Does this grant narrative include economic risk, economic impact, or community economic benefit? Respond PASS or FAIL only. If FAIL, state what is missing in one sentence.',
   'FLAGGED'),

  ('DG', 'LA', 'Blueprint', null,
   'LA Blueprint: Site Address Required',
   'IF output_type=Blueprint AND vertical=LA THEN a site address or GPS coordinates MUST be present.',
   'Does this landscape blueprint reference a specific site address or GPS coordinates? Respond PASS or FAIL only.',
   'FLAGGED'),

  ('DG', null, 'Client Proposal', 'Contract',
   'Contract Proposal: Scope of Work Required',
   'IF output_type=Client Proposal AND funding_type=Contract THEN a Scope of Work MUST be present.',
   'Does this proposal contain a clearly defined Scope of Work with specific deliverables? Respond PASS or FAIL only.',
   'FLAGGED'),

  ('FD', null, null, null,
   'Global: No Fabricated Data',
   'IF any output contains fabricated statistics, invented citations, or placeholder numbers presented as real THEN flag.',
   'Does this output contain fabricated statistics, invented citations, or placeholder values (X%, TBD) presented as facts? Respond PASS or FAIL only.',
   'FLAGGED'),

  ('TV', null, 'Grant Narrative', 'Grant',
   'Grant Narrative: Named Programs Must Be Real',
   'IF output references a specific grant program by name THEN that program must be real and currently active.',
   'Are all named grant programs in this narrative real and currently active as of 2026? Respond PASS or FAIL only. If FAIL, name the unverified program.',
   'FLAGGED'),

  ('SI', null, null, null,
   'Global: TCG Brand Voice Check',
   'IF output contains spiritual, astrological, or non-engineering-rooted framing THEN flag as brand drift.',
   'Does this output contain spiritual language, astrological framing, or vague motivational content inconsistent with an engineering-rooted consulting brand? Respond PASS or FAIL only.',
   'REVISION');

insert into projects
  (name, vertical, stage, description, site_address, funding_type, funding_target, progress_pct)
values
  ('Riverside Community Garden',      'LA','Proposal',   'Multi-zone urban garden with water feature, raised beds, gathering pavilion, and native plant corridors.',             '1420 Riverside Dr, Houston TX 77004',      'Grant',    48000,  65),
  ('Urban Corridor Greenway',         'LA','Design Dev', 'Linear greenway connecting three neighborhood blocks with bioswales, lighting, seating nodes, and tree canopy.',       '500 Main St Corridor, Houston TX 77002',   'Contract', 120000, 40),
  ('Neighborhood Beautification',     'LA','Active',     'Curb appeal and streetscape improvement for residential block associations.',                                          null,                                       'Donation', 12500,  80),
  ('Integrit-E SaaS Platform',        'TA','Build',      'Full-stack SaaS implementation of the Integrit-E methodology as a client-facing tool.',                               null,                                       'Retainer', 8500,   55),
  ('AI Workflow Automation Suite',    'TA','Discovery',  'End-to-end AI workflow automation for mid-market operations teams.',                                                   null,                                       'Contract', 75000,  20),
  ('Nonprofit Tech Infrastructure',   'TA','Proposal',   'Supabase + Make.com + Claude stack for a community nonprofit.',                                                       null,                                       'Grant',    35000,  30),
  ('Digital Literacy Program',        'CD','Active',     'Structured digital skills curriculum for underserved adults aged 18-45.',                                             null,                                       'Grant',    62000,  70),
  ('Workforce Transition Initiative', 'CD','Proposal',   'Retraining program bridging blue-collar workers into tech-adjacent roles.',                                           null,                                       'Grant',    150000, 15),
  ('Youth Tech Mentorship',           'CD','Design Dev', 'Outdoor learning campus with maker zones, performance lawn, digital kiosk nodes, and shade structures.',              null,                                       'Donation', 8200,   45);

-- ───────────────────────────────────────────────────────────────
-- QUICK REFERENCE
-- ───────────────────────────────────────────────────────────────
-- select * from v_project_pipeline;     -- full active pipeline
-- select * from v_gate_queue;           -- Eric-Gate review queue
-- select * from v_funding_summary;      -- totals by vertical
-- select * from v_active_guardrails;    -- Vellum ruleset

-- ═══════════════════════════════════════════════════════════════
--  SCHEMA COMPLETE · Draft v1.0
--  9 tables · 4 views · 7 triggers · 6 guardrail rules · 9 projects
--  Dependency order: clients → projects → ai_outputs → gate_log
-- ═══════════════════════════════════════════════════════════════
