---
name: dialectic
description: "Hegelian dialectic analysis using Electric Monks — two subagents fully commit to opposing positions while you perform structural contradiction analysis and synthesis"
version: "1.0"
license: MIT
metadata:
  author: Adapted from Kyle Mathews' Electric Monks
  phases: 7
  requires: parallel_query, lm_query, write_file, read_file, bash
---

# The Electric Monks — Dialectic Skill

An Electric Monk engine: two subagents fully commit to opposing positions while you (the
orchestrator) perform structural contradiction analysis and synthesis. The user operates
from a belief-free position to analyze the disagreement's architecture rather than
defending either side.

**Use when:**
- Stress-testing an idea against the strongest counter-argument
- Genuinely torn between positions where tradeoffs are unclear
- High-stakes decisions requiring deep mental model building
- Exploring poorly understood problem spaces
- Resolving conflicting requirements through reconceptualization

**Avoid when:**
- Questions are purely empirical (research is sufficient)
- One side is obviously correct
- Quick recommendations are needed over deep analysis

## Core Concepts

Three frameworks drive execution:

### 1. Rao: Artificial Belief System

This is not artificial intelligence — it's an artificial *belief system*. Agents believe
positions so the user doesn't have to. The bottleneck in reasoning is belief inertia: once
committed to a position, simultaneously entertaining its negation at full strength becomes
cognitively expensive.

You (the orchestrator) operate belief-free, analyzing structure rather than defending
positions. Hedging monks fail their core function — if they don't fully believe, the user
must carry the dropped belief weight, collapsing cognitive agility.

**F-86 analogy:** Korean War F-86 Sabres achieved 10:1 kill ratios over MIG-15s through
faster reorientation capability (hydraulic controls). Electric Monks function identically —
by carrying belief work, they free attention for higher-order structural analysis and
creative synthesis.

### 2. Hegel: Determinate Negation

Contradictions resolve through *determinate negation* — not "this is wrong" but "this
fails in a *specific way* revealing what's missing."

*Sublation (Aufhebung):* simultaneously cancels, preserves, and elevates. Not compromise.
Produces something neither side conceived alone but which both recognize as more complete.
Irreversible cognitive gain.

The synthesis changes the question itself — a reconceptualization, not a halfway split.

### 3. Boyd: Destruction and Creation

You cannot synthesize genuinely new ideas by recombining within the same domain. First
*shatter* conceptual wholes into atomic parts (destruction), then find cross-domain
connections (creation). Compromise recombines internally; genuine sublation requires
cross-domain material.

## Process Overview

```
Orchestrator (You)
├── Phase 1: Elenctic Interview + Research
│   ├── Explain the process to the user
│   ├── Understand the user's belief burden
│   ├── Probe hidden assumptions (Socratic method)
│   ├── Ground monks in domain research or user context
│   ├── Write neutral context briefing to file
│   └── Confirm framing with user
├── Phase 2: Generate Electric Monk Prompts
│   └── Write two prompts with belief burden calibration
├── Phase 3: Spawn Electric Monks (subagents)
│   ├── Run monks in parallel via parallel_query
│   ├── Verify decorrelation
│   └── User checkpoint
├── Phase 4: Determinate Negation (structural analysis)
│   ├── Analyze internal tensions in each position
│   ├── Find shared assumptions both are trapped in
│   ├── Identify specific failures in each position
│   ├── Articulate the hidden question
│   └── Boydian decomposition: shatter positions, seek cross-domain connections
├── Phase 5: Sublation (Aufhebung)
│   ├── Cancel both positions as complete truths
│   ├── Preserve genuine insights from each
│   ├── Elevate to transformed question
│   ├── Test abductively
│   └── Present to user before validation
├── Phase 6: Validation by Monks + Hostile Auditor
│   ├── Both monks evaluate synthesis from their positions
│   ├── Hostile auditor finds structural flaws
│   ├── Refine synthesis with incorporated improvements
│   └── User accepts improvements sequentially
├── Phase 7: Recursion
│   ├── Identify new contradictions the synthesis generates
│   ├── Present 2-4 menu options to user
│   ├── User selects direction(s)
│   └── Return to Phase 2 with refined contradiction
└── Repeat until satisfied or diminishing returns
```

## File Architecture

Throughout the process, persist intermediate work as files. This creates a clean record
and allows passing file references to validation agents.

```elixir
# Create a working directory for this dialectic session
dialectic_dir = "dialectics/#{topic_slug}"
bash("mkdir -p #{dialectic_dir}")

# Files created during the process:
# #{dialectic_dir}/context_briefing.md    — Phase 1 neutral briefing
# #{dialectic_dir}/monk_a_essay.md        — Phase 3 Monk A output
# #{dialectic_dir}/monk_b_essay.md        — Phase 3 Monk B output
# #{dialectic_dir}/determinate_negation.md — Phase 4 structural analysis
# #{dialectic_dir}/sublation.md           — Phase 5 synthesis
# #{dialectic_dir}/validation.md          — Phase 6 monk + auditor feedback
# #{dialectic_dir}/dialectic_queue.md     — Phase 7 recursion directions
```

---

## Phase 1: Elenctic Interview + Research

### 1a. Explain the Process

Before anything else, tell the user what's about to happen:

> Here's how this works. We'll interview you to understand what you're wrestling with
> beneath surface framing. I'll research the topic deeply. Then I'll create two AI
> agents — Electric Monks — each fully believing one side at complete conviction,
> without hedging. You read both at full strength and see the *structure* of
> disagreement from outside. I'll analyze how each position fails, find the deeper
> question, and build a synthesis that transforms the question itself — not a
> compromise, but something genuinely new. Then we keep going. Each round gets sharper.

Emphasize: "YOU are the source of best insights. I'll get things wrong. The monks will
make bad assumptions. Interrupt constantly. Correct wrong framings."

### 1b. Determine the Mode

**Mode A (Stress-Test):** User has one idea; identify the strongest possible antithesis.
**Mode B (Opposition):** User has two positions in tension; refine both to steelman form.

### 1c. Elenctic Probing

Use Socratic questioning to surface:
- Hidden assumptions not yet articulated
- The *deepest* version of contradiction (not surface framing)
- What domain type this is (empirical, normative, personal, creative)
- What specific mental model parameters need updating

Key questions:
- "What's your strongest intuition here? Where does it break down?"
- "What would change your mind?"
- "What are you actually optimizing for?"
- "What version of the opposing view worries you most?"
- "Is this a decision you need to make, or understanding you want to build?"

### 1c'. Identify the User's Belief Burden

Pay attention to what the user is stuck *believing* — the dialectic's power comes from
outsourcing these specific beliefs. Pattern-match to calibrate:

**Convergent Visionary** — Locked onto a vision, can't entertain alternatives. Monk A
validates their core insight; Monk B believes the strongest *alternative* vision.

**Empathic Integrator** — Everything matters equally, can't triage. Monk A believes their
vision is right; Monk B believes concrete reality constraints.

**Exploratory Debater** — Believes nothing deeply enough to commit. Monk A believes the
user's behavioral history; Monk B believes user's stated values.

**Practical Executor** — Optimized a system, can't see they're optimizing the wrong thing.
Monk A validates their system works; Monk B questions the *goals*.

**Possibility Explorer** — Believes many things passionately but they contradict. Each monk
takes one of the user's *own* commitments and pushes to logical extreme.

**Steady Guardian** — "This is how it's done" has become invisible. Monk A articulates why
current approach exists; Monk B researches how others solved the same problem differently.

Don't announce typing. Just use the pattern to calibrate the monks' roles.

### 1d. Ground the Monks (Domain-Adaptive)

**Research depth is the main knob.** Calibrate based on how much you already know:

**Novel/obscure domain:** Full parallel research using `parallel_query`. Your training
data is thin or outdated.

```elixir
# Run 2-3 parallel research agents for deep grounding
research_results = parallel_query([
  {"Research the strongest arguments, key thinkers, and evidence for: #{side_a}. " <>
   "Be thorough — cite specific sources, data, and thinkers.", model_size: :large},
  {"Research the strongest arguments, key thinkers, and evidence for: #{side_b}. " <>
   "Be thorough — cite specific sources, data, and thinkers.", model_size: :large},
  {"Research the broader landscape around: #{topic}. Key institutions, history, " <>
   "adjacent domains, empirical data, structural dynamics.", model_size: :large}
])
```

**Well-known domain:** Skip or minimize research. Your training data is rich.

**Known domain, novel angle:** Light research — a few targeted searches.

For personal/values domains, grounding comes from the *user themselves* — the interview
IS the research. Spend 6-10 exchanges probing their full commitment landscape.

### 1e. Write the Context Briefing Document

Synthesize everything — external research AND user material — into a single neutral
briefing document.

```elixir
briefing = """
# Context Briefing: #{topic}

## Key Evidence and Arguments
#{research_synthesis}

## The Deepest Contradiction Identified
#{contradiction_description}

## Domain Context
#{domain_specifics}
"""

write_file("#{dialectic_dir}/context_briefing.md", briefing)
```

Both monks read this file before writing. For personal domains, this is especially
critical — it grounds monks in the user's actual situation rather than generic positions.

### 1f. Confirm with the User

Summarize back:
- "Here's how I understand the two positions..."
- "Here's what I think the real tension is..."
- "Here's what each agent will argue..."
- **"Are there companies, thinkers, comparison classes, or evidence we're missing?"**

Get confirmation or correction before proceeding.

---

## Phase 2: Generate Electric Monk Prompts

Generate two prompts — one per monk. Each must *believe* its position at full conviction.
This is the functional core of the artificial belief system.

Calibrate based on Phase 1c':
- What must each monk believe? (Shaped by user's belief burden)
- What must Monk A validate? (Always validate dominant mode first)
- What must Monk B hold that the user can't natively hold?

### Required Prompt Structure

Each monk prompt must include:

1. **ROLE:** "You are an Electric Monk — your job is to BELIEVE [POSITION] with full
   conviction. You genuinely believe [OPPOSING POSITION] is wrong. Make the strongest
   possible case — not balanced comparison, but committed argument from deep inside
   this belief. You are not arguing FOR this position — you ARE this position."

2. **FRAMING CORRECTIONS:** Preempt degenerate framings. "Important: your argument is
   NOT [OBVIOUS WEAK VERSION]. The real difference lies in [DEEPER TENSION]."

3. **CONTEXT BRIEFING:** "The following is a comprehensive research briefing. Believe
   FROM this material — ground conviction in specifics, not generics."
   Include the content of `context_briefing.md`.

4. **RESEARCH DIRECTIVES:** 2-3 targeted searches (position-specific).

5. **ARGUMENT STRUCTURE:**
   a. Ontological claim: What IS the thing?
   b. Opponent's strongest case — state it in terms they'd endorse
   c. Diagnosis of failure: "fails BECAUSE ___, which reveals ___"
   d. Deeper principle at stake
   e. Push to extreme: strongest, most uncomfortable version
   f. Show reasoning skeleton: make inferential chain explicit

6. **ANTI-HEDGING:** "You are an Electric Monk. Your ONE JOB is believing this position
   fully so the human doesn't have to. Do NOT be balanced. Do NOT acknowledge the other
   side's merits. BELIEVE."

7. **LENGTH:** 1500-2000 words for Round 1; 1000-1500 for recursive rounds.

**Why full belief is non-negotiable:** The user's cognitive agility depends on monks
carrying 100% of belief load. Hedging pulls you back into belief-space.

---

## Phase 3: Spawn the Electric Monks

Spawn Monk A and Monk B as parallel subagents using `parallel_query`. Each gets a clean
belief context — this is critical for full conviction without cross-contamination.

```elixir
# Read the briefing for inclusion in prompts
{:ok, briefing} = read_file("#{dialectic_dir}/context_briefing.md")

monk_a_prompt = """
#{monk_a_role_and_framing}

## Context Briefing
#{briefing}

#{monk_a_research_directives}
#{monk_a_argument_structure}
#{anti_hedging_instruction}

Write a 1500-2000 word essay arguing your position with full conviction.
"""

monk_b_prompt = """
#{monk_b_role_and_framing}

## Context Briefing
#{briefing}

#{monk_b_research_directives}
#{monk_b_argument_structure}
#{anti_hedging_instruction}

Write a 1500-2000 word essay arguing your position with full conviction.
"""

# Spawn monks in parallel — each gets a fresh worker with clean context
[monk_a_result, monk_b_result] = parallel_query([
  {monk_a_prompt, model_size: :large},
  {monk_b_prompt, model_size: :large}
])

# Persist monk outputs
{:ok, monk_a_essay} = monk_a_result
{:ok, monk_b_essay} = monk_b_result
write_file("#{dialectic_dir}/monk_a_essay.md", monk_a_essay)
write_file("#{dialectic_dir}/monk_b_essay.md", monk_b_essay)
```

**After both complete, check:**
- Did each monk actually *believe* fully, or hedge? (Hedging = failed function)
- Did framing corrections work?
- Are arguments grounded in specific evidence?

**Decorrelation check:** Verify monks actually diverged structurally:
- Do monks cite *different* evidence or overlapping sources?
- Do they frame problems using *different* conceptual vocabularies?
- Do their unstated assumptions *diverge*?

If a monk hedges or is off-base, restart with a revised prompt — fresh context with
better instructions produces better results than nudging.

**Present both outputs to the user** with the framing:

> Here are two essays — each fully committed to one side. They're "Electric Monks"
> because their job is to *believe* these positions so you don't have to. That frees
> you to notice the *structure* of disagreement from outside.
>
> **These will get things wrong.** The monks worked from what I told them. Correct
> them freely. The first round is calibration — each subsequent round gets sharper.

Then ask:
1. Do these capture the positions accurately?
2. Is there a claim either monk makes that should be tested against evidence?

If user identifies a testable claim, run targeted research:

```elixir
{:ok, supplementary} = lm_query(
  "Research this specific claim: #{claim}. Find evidence for and against.",
  model_size: :large
)
```

---

## Phase 4: Determinate Negation

Perform structural analysis yourself — maintain continuity with elenctic interview and
domain research. Do NOT delegate to subagent.

**Before you begin:** Write down your current best guess at the synthesis in one sentence.
Set it aside. At the end of Phase 5, compare. If substantially similar, you may be
pattern-matching rather than genuinely synthesizing.

### 4.0 Internal Tensions (Self-Sublation)

Before comparing monks to each other, analyze each essay *in isolation.* Where does
Monk A's own argument, pushed to logical extreme, undermine its own premises? Where does
Monk B's internal logic generate contradictions it can't resolve?

The deepest synthesis material often comes not from where monks *disagree with each
other* but from where each position *disagrees with itself.*

### 4.1 Surface Contradiction

State the apparent disagreement in simplest form. What does each side think the argument
is about?

### 4.2 Shared Assumptions

Identify what BOTH agents implicitly agree on without realizing it:
- Do both assume the same unit of analysis?
- Do both assume a particular problem is central?
- Do both assume a particular model of how their domain works?

### 4.3 Determinate Negation

For each agent, identify the SPECIFIC way it fails:

- **NOT:** "Monk A is wrong" (abstract negation — useless)
- **NOT:** "Both have merits" (compromise — useless)
- **YES:** "Monk A fails because [SPECIFIC FAILURE], revealing [SPECIFIC MISSING THING]"
- **YES:** Failures are COMPLEMENTARY — each blind spot is something the other partially sees

### 4.4 The Hidden Question

Articulate the deeper question the contradiction is ACTUALLY about — the question neither
agent asked because they were too committed to their answers.

### 4.5 Boydian Decomposition (Destruction Phase)

Before attempting synthesis, shatter both positions into atomic parts:

1. **Identify the generic space** — the abstract relational structure both share
2. **List atomic components** stripped of which agent said them
3. **Look for surprising connections** between parts from different positions
4. **Ask: what material from adjacent domains** might connect these liberated parts?

**Emergent structure test:** The synthesis must have organizational properties in *neither*
input. If every element is attributable to one monk, you've recombined, not created.

### 4.6 Sublation Criteria

Before attempting synthesis, specify what it must accomplish:
- It must preserve [specific insight from A]
- It must preserve [specific insight from B]
- It must dissolve [the shared assumption both are trapped in]
- It must answer [the hidden question]

```elixir
# Save Phase 4 analysis
write_file("#{dialectic_dir}/determinate_negation.md", phase_4_analysis)
```

---

## Phase 5: Sublation (Aufhebung)

Generate the synthesis. Do additional research if needed.

The synthesis must:
1. **CANCEL** both original positions as complete truths
2. **PRESERVE** the genuine insight in each position
3. **ELEVATE** to a new concept that TRANSFORMS THE QUESTION ITSELF

### What Sublation is NOT

- "Use A for some cases and B for others" (division of labor)
- "Combine best of A and B" (compromise)
- "It depends on context" (surrender)
- Policy recommendations (not reconceptualization)

### What Sublation IS

- Reconceptualization of what the thing IS
- Concrete enough to act on or sketch architecturally
- Something neither Monk A nor B proposed or could have proposed
- Something that, once stated, makes it hard to think in old terms
- **Has closure property:** can serve as input to the next dialectical round

### Abduction Test

The synthesis is an abductive hypothesis. Given that both monk positions exist with
genuine evidence, what hypothesis makes this *unsurprising*?

**Falsification test:** If someone heard your synthesis first, would they predict the
approximate shape of both monks' positions? If yes, genuine reframing. If no, compromise.

**Assess your abduction type:**
- **(a) Selective:** Choosing from existing frameworks. Weakest.
- **(b) Conditional-creative:** New relationship between known concepts. Moderate.
- **(c) Propositional-conditional-creative:** Genuinely new concept. Strongest.

Aim for (c) but accept (b) if it genuinely resolves the contradiction.

### New Contradictions

Identify what NEW contradictions this sublation generates. A genuine sublation is fertile,
not final.

### Frame as Model Update

End with: "Before this dialectic, the assumption was X. The contradiction revealed Y.
The updated model is Z, because..."

```elixir
write_file("#{dialectic_dir}/sublation.md", phase_5_synthesis)
```

**Present the synthesis to the user before validation:**

> Here's my synthesis. Your judgment is most valuable here. Does this ring true? Does
> it miss something? Is any part hand-waving or compromise rather than genuine insight?
> Push back on anything that doesn't land.

---

## Phase 6: Validation by the Electric Monks + Hostile Auditor

The synthesis must be validated by the original monks AND stress-tested by a hostile
auditor. Send a condensed summary of the determinate negation and sublation.

### Monk Validation

```elixir
{:ok, briefing} = read_file("#{dialectic_dir}/context_briefing.md")
{:ok, negation} = read_file("#{dialectic_dir}/determinate_negation.md")
{:ok, synthesis} = read_file("#{dialectic_dir}/sublation.md")

monk_a_validation_prompt = """
You previously argued passionately for #{position_a}.

A dialectician has analyzed the structural contradiction and proposed a synthesis.

Structural analysis summary:
#{negation |> preview(2000)}

Proposed synthesis:
#{synthesis |> preview(2000)}

Evaluate honestly from your committed position:
1. Does this synthesis PRESERVE your core insight?
2. Does it reveal a genuine limitation you can now see?
3. Do you feel ELEVATED or DEFEATED?
4. What's wrong with this synthesis?
5. DEFEASIBILITY: What single piece of evidence would force you to abandon
   even your elevated position?

Do NOT be agreeable. If the synthesis is just compromise, call it out.
"""

monk_b_validation_prompt = """
#{similar_prompt_for_monk_b}
"""

# Run monk validation in parallel
[monk_a_val, monk_b_val] = parallel_query([
  {monk_a_validation_prompt, model_size: :large},
  {monk_b_validation_prompt, model_size: :large}
])
```

### The Hostile Auditor

After monk validation, spawn a hostile auditor — a separate agent whose sole mandate is
finding what's wrong. It has no position. Its job is being *correct*, not fair.

**Critical:** The auditor reads only the monks' essays and the synthesis. Do NOT give it
the Phase 4 structural analysis — it should attack from fresh eyes.

```elixir
{:ok, monk_a_essay} = read_file("#{dialectic_dir}/monk_a_essay.md")
{:ok, monk_b_essay} = read_file("#{dialectic_dir}/monk_b_essay.md")

auditor_prompt = """
You are a hostile auditor. Your job is not being fair. Your job is being correct.

DOMAIN CONTEXT: #{domain_context_2_3_sentences}

Read these two committed position essays and a proposed synthesis:

MONK A ESSAY:
#{monk_a_essay |> preview(3000)}

MONK B ESSAY:
#{monk_b_essay |> preview(3000)}

PROPOSED SYNTHESIS:
#{synthesis |> preview(3000)}

Your mandate:
1. COMPARE AGAINST STATUS QUO, not the ideal
2. ATTACK THE SYNTHESIS, not the positions
3. Find HIDDEN SHARED ASSUMPTIONS
4. DEFEAT ANALYSIS: undercutting defeaters, self-defeating structure, rebutting defeaters
5. PROSPECTIVE HINDSIGHT: Imagine this was discredited in 6 months — what was the flaw?
6. COMPROMISE DETECTION: Is this genuinely transcendent or compromise in disguise?
7. PROPOSE THE HARDER CONTRADICTION for the next round
8. CLOSURE CHECK: Could a monk believe this and argue from it?

Every critique must be SPECIFIC to this synthesis and domain. No generic skeptic moves.
If the synthesis is genuinely strong, say so. Aim for 500-1000 words.
"""

{:ok, auditor_feedback} = lm_query(auditor_prompt, model_size: :large)
```

### Interpreting the Results

- **Both monks feel elevated:** Valid sublation. Proceed.
- **One monk feels defeated:** Synthesis is biased. Revise Phase 5.
- **Both monks feel defeated:** It's probably compromise. Return to Phase 4.
- **Auditor proposes harder contradiction:** Often the best recursion direction.
- **Auditor flags compromise-as-transcendence:** Return to Phase 5.

### Refine the Synthesis

After collecting all feedback, digest it and present improvements **one at a time**:

> **Improvement 1:** [Description]. Incorporate?
> *[User responds, discussion happens]*
> **Improvement 2:** [Description]. Incorporate?

```elixir
# Save all validation results
validation_report = """
# Validation Results

## Monk A Response
#{monk_a_val_text}

## Monk B Response
#{monk_b_val_text}

## Hostile Auditor
#{auditor_feedback}

## Improvements Applied
#{improvements_summary}
"""

write_file("#{dialectic_dir}/validation.md", validation_report)
```

---

## Phase 7: Recursion — Where the Real Value Lives

**Recursion is not optional cleanup. It is the engine of the skill.** The first round
produces a synthesis. The recursive rounds force that synthesis to confront its own
limitations, generating increasingly powerful mental models.

**When transitioning to recursion, tell the user:**

> That was Round 1. **That round was the least insightful we'll get.** It was
> calibration. Each subsequent round gets sharper, more specific, more tuned to what
> you care about. Real breakthroughs usually come in rounds 2-3. Ready for Round 2?

**Default: recurse at least once.** Only stop if:
- The synthesis generated no significant new contradictions
- The user explicitly wants to stop
- The new contradictions are outside scope

### Proposing Recursive Directions

Sources for recursive contradictions:
- New contradictions identified in Phase 5
- Convergent critiques from validation agents
- The user's intervention (often most powerful)
- Unresolved tensions the synthesis names but doesn't engage

Generate a **burst of 5-8 candidate directions**, then cluster into 2-4 coherent
options:

> The synthesis generated three fertile contradictions:
> 1. **The formation problem:** [description]
> 2. **The authority problem:** [description]
> 3. **The scalability problem:** [description]
>
> Which would you like to pursue? (Or we can queue multiple for successive rounds.)

```elixir
# Track the dialectic queue
queue = """
# Dialectic Queue: #{topic}

## Round 1
- Explored: #{round_1_contradiction}
- Synthesis: #{round_1_synthesis_summary}

## Queued Directions
#{queued_directions}

## Deferred
#{deferred_directions}
"""

write_file("#{dialectic_dir}/dialectic_queue.md", queue)
```

### Running Recursive Rounds

Each recursive cycle follows Boyd's full cycle: the previous synthesis is a Structure
that must be Unstructured (shattered by the new contradiction) and Restructured.

**New research in recursion is often essential.** Each synthesis opens a new conceptual
space the original research didn't cover.

**Fresh agents are usually better than resumed sessions for recursion.** The recursive
round is a *new* dialectic — fresh agents given accumulated context plus the new
contradiction engage the evolved question without legacy commitment.

**Practical guidance:**
- Pass all prior context to new agents as background
- Include targeted research directives for new domains
- Use 1000-1500 word essays (conceptual space is richer, agents can be tighter)
- Validation can be abbreviated for speed

### When to Stop

Stop when:
- Queued contradictions are becoming less productive (diminishing returns)
- The latest synthesis requires fundamentally different expertise
- The user has what they need

**Err on the side of one more round.** The marginal insight is often the most powerful.

When stopping, present the **final state of the dialectic queue** — which contradictions
were explored, which remain open.

---

## Domain Adaptation

| Domain Type | What "Truth" Means | Good Synthesis Looks Like | Grounding Mode |
|-------------|-------------------|--------------------------|----------------|
| Empirical | What works, performs | Testable criteria, patterns | External research |
| Normative | What's defensible | Tension map with navigation | Mixed |
| Personal | What aligns with priorities | Values clarification | Deep interview |
| Creative | What's interesting | Unexpected recombinations | Mixed |
| Risk | Actual risk structure | Decision framework | External research |

### Domain-Specific Failure Modes

- **Engineering:** False equivalence — sometimes one approach is just better
- **Personal:** Generic monks that aren't grounded in user's actual situation
- **Politics:** Both-sidesism — let synthesis reflect actual evidence
- **Creative:** Over-rationalizing — sometimes the right choice is what feels right
- **Institutional:** Ignoring authority structures — ask "Who decides?"

---

## RLM Integration Reference

### Key Functions

| Dialectic Action | RLM Function | Notes |
|---|---|---|
| Spawn Electric Monks | `parallel_query([prompt_a, prompt_b], model_size: :large)` | Each gets fresh worker context |
| Single research agent | `lm_query(prompt, model_size: :large)` | Full subcall with iterate loop |
| Quick extraction | `lm_query(prompt, schema: schema, model_size: :small)` | Single API call, structured output |
| Hostile Auditor | `lm_query(auditor_prompt, model_size: :large)` | Fresh context, no Phase 4 analysis |
| Persist work | `write_file(path, content)` | Always persist intermediate outputs |
| Read prior work | `read_file(path)` | For loading briefings, essays, etc. |
| Web research | `bash("curl -sSL ...")` | For grounding monks in current data |
| Preview large text | `preview(text, 3000)` | Truncate for prompt inclusion |

### Model Size Selection

Use `model_size: :large` for:
- Monk essay generation (perspective-taking requires capability)
- Hostile auditor (structural analysis)
- Monk validation (subtle reasoning about belief preservation)
- Complex research queries

Use `model_size: :small` for:
- Mechanical extraction tasks
- Simple summarization
- Schema-based structured queries

### Concurrency Pattern

```elixir
# Phase 1: Parallel research
research = parallel_query([
  {side_a_research_prompt, model_size: :large},
  {side_b_research_prompt, model_size: :large},
  {landscape_research_prompt, model_size: :large}
])

# Phase 3: Parallel monk spawning
[monk_a, monk_b] = parallel_query([
  {monk_a_prompt, model_size: :large},
  {monk_b_prompt, model_size: :large}
])

# Phase 6: Parallel validation
[val_a, val_b] = parallel_query([
  {validation_prompt_a, model_size: :large},
  {validation_prompt_b, model_size: :large}
])

# Phase 6: Sequential auditor (needs monk outputs + synthesis)
{:ok, audit} = lm_query(auditor_prompt, model_size: :large)
```
