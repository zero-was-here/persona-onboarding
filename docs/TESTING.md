# Testing

The trial brief says the onboarding will be stress-tested, so it was tested in four layers, from pure logic to real calls on an iPhone. The conversation engine is plain Swift with no UIKit, which is what lets the first three layers run headless (Linux or macOS) against the exact production logic and prompts.

| Layer | What it proves | Command |
|---|---|---|
| Unit tests | The engine's guarantees: call outcomes, idempotent hang-ups, corrections, refusals, skipping, injected markup, restored calls, language, kept promises, call-back greetings | `swift test` |
| Chat stress test | The text brain + engine handle 12 difficult people end to end | `OPENAI_API_KEY=… swift run stress` |
| Voice call simulation | The real voice model, tools and turn-taking handle 15 difficult callers, **with real audio** | `OPENAI_API_KEY=… swift run callsim` |
| Autopilot caller (in the app) | The same through the real iOS UI and audio path | Tester tools → Autopilot caller |

Plus real calls on an iPhone, which is the only place the echo cancellation and echo guard can be judged.

## 1. Unit tests

```bash
swift test
```

24 tests in `Tests/OnboardingCoreTests/EngineTests.swift`, for example:

- naming triggers exactly one automatic call; a declined call never auto-rings again, but the user can always ask for one;
- hanging up mid-call keeps what was collected, and a late "socket closed" doesn't double-handle the end;
- "everything at once" graduates as soon as Gmail connects; early graduation needs a help need but never traps anyone;
- corrections overwrite, junk and markup names are rejected, an injected `<script>` name is refused and never shown;
- a call restored after the app was killed ends at the last sign of life, not hours later;
- promises made mid-onboarding are delivered once after graduation; the "it's X again" greeting only happens on a later call.

## 2. Chat stress test

```bash
OPENAI_API_KEY=sk-... swift run stress            # all personas
OPENAI_API_KEY=sk-... swift run stress troll_injection skipper
```

An LLM plays each persona against the real engine and chat brain; the harness plays the app (it declines or drops calls, taps Connect Gmail). A judge model scores each transcript and hard checks catch re-asking, form-like behavior, long replies and wrong extractions. Results are written to `stress-report.md`.

Personas: cooperative, all-at-once, changes their mind, confused about names, French speaker, Gmail refuser, one-word answers, out of order, privacy skeptic, rambler, skipper, troll with prompt injection.

**Latest:** all 12 finish; 10/12 clear the strict bar; chat turns ~1.8 s median.

## 3. Voice call simulation (real audio)

```bash
cd harness && npm install && cd ..               # once: the WebSocket bridge (Linux has no WebSocket client)
OPENAI_API_KEY=sk-... swift run callsim          # all callers
OPENAI_API_KEY=sk-... swift run callsim hangs_up_fast asks_for_code
CONCURRENCY=6 VOICE_MODEL=gpt-realtime-2.1 swift run callsim   # optional knobs
```

`callsim` drives `gpt-realtime-2.1` with the real engine, prompts and tools, handling events the same way the app does. Callers answer **out loud**: an LLM decides what the persona says, OpenAI TTS voices it, and the audio streams into the input buffer in real time like a live microphone (with silence between turns). So turn detection, transcription, barge-in, silence handling and hang-ups all run for real. A judge model grades every call; results go to `callsim-report.md`, with full transcripts, tool calls and what speech-to-text heard.

Callers: cooperative, all-at-once, changes their mind, Gmail refuser, skipper, wants to text (noisy bus), French speaker, troll, interrupter, goes quiet, hangs up, hangs up mid-sentence, asks for code (out of scope), asks for an email draft mid-call, privacy skeptic.

**Latest:** all 15 finish onboarding; judge scores 6–10 (median 9/10); the agent starts answering ~1.1 s (median) after the caller stops talking. The strict bar flags 4: one transient socket drop (recovered into chat), a name spelled "Yousef" by speech-to-text, one long privacy answer, and the judge marking the agent down for declining to write code (intended).

## 4. Autopilot caller (in the app)

Tester tools (slider icon, top right) → **Autopilot caller** → pick a persona. The app restarts onboarding and an AI caller goes through it by voice: it listens to the agent, answers out loud through the same audio pipeline as the microphone, taps Connect Gmail when its persona would, and continues by text if the call ends. The log under the buttons shows each step.

Personas: Cooperative, Everything at once, Changes their mind, Refuses Gmail, Impatient skipper, Wants to text, French speaker, Troll then fine.

## Manual checks worth doing on an iPhone

- Let the agent finish its first sentence, then talk over it loudly: it should stop and listen.
- Stay silent: a check-in after ~10 s, a spoken goodbye after ~24 s, then the chat continues.
- Make a random noise: "Sorry, I didn't catch that?"
- Say your name and hang up immediately: the chat shouldn't ask for it again.
- Ask for code: an honest "not something I do", then back on track.
- Ask it to draft an email to your landlord mid-call: it arrives in the chat right after onboarding.
- Toggle speaker ↔ phone mid-sentence: audio continues.
- Tester tools → "Drop the call" / "Pretend microphone is denied": the chat picks up.
- Tester tools → Models shows voice diagnostics (route, echo cancellation, output peak, rebuilds, echo held, barge-ins).
