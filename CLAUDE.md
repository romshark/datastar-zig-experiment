# CLAUDE.md

## Writing Style

Write like a technical specification, not an essay or marketing copy. Applies to all writing: comments, commit messages, and documentation (READMEs, doc pages, etc.).

- Use plain English: short declarative sentences, common words, active voice, few adjectives or adverbs.
- State facts and requirements directly. A sentence says what is true or required, not why it matters emotionally.
- Structure text as a logical hierarchy of sections and subsections: one topic per section, related points grouped together, nested under the broader topic they belong to, ordered general to specific.
- State each thing once. Reference or link to it from elsewhere instead of copying; duplicated text drifts out of sync.
- Headings are plain descriptors of their content, never slogans or metaphors.
- In Markdown files, do not hard-wrap prose: put each paragraph on one line and let the editor soft-wrap, so an edit doesn't reflow the whole paragraph.
- No metaphors, similes, slogans, or rhetorical flourishes.
- No editorializing or motivational framing.
- No second-person hype and no selling the reader on the design; only concise descriptive technical text.
- Mark rationale with an explicit label (`Rationale:`, `Why:`, `Requirement:`, `Check:`) rather than weaving persuasion into the prose.

### Comment style

Prefer one or two lines over a paragraph and a sentence fragment over a full sentence when it's unambiguous. State the non-obvious _why_ (invariant, constraint, browser quirk, gotcha). Never paraphrase the code's _what_. Use precise terms (e.g. "top layer", "capture phase", "passive listener", "cascade", "containing block") rather than narrating in plain English. If a comment grows past ~3 lines, the reason it needs that much prose is usually the signal to split or rename, not to keep writing.

No history in comments: describe the current state, not what the code used to do or what changed. That belongs in commit messages.

If a reader could infer the comment from the code itself, remove it as it adds no value.

### Git commits

Follow [Conventional Commits 1.0](https://www.conventionalcommits.org/en/v1.0.0/): `<type>[optional scope]: <description>` (e.g. `feat(switch): …`, `fix: …`, `chore: …`).

- Title (first line) 50 characters max, sentence case (capitalize the first word), no trailing period, imperative mood: it completes "If applied, this commit will …". Use `fix: Revalidate min bundles`, not `Revalidated` (past) or `Revalidates` (present).
- Body wraps at 72 characters per line. State the non-obvious _why_, never paraphrase the _what_. Describe the current state in present tense and the fix in imperative, not past: `Focus leaves the open dialog. Trap it in the panel`, not `Focus left the open dialog and was trapped`.
