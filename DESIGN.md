# Midnight Glass: design system

The onboarding is the first minute a person spends with their new assistant, so the app is built around one idea: **the agent is a living presence, not a form.** Everything else stays quiet so the orb and the conversation carry the experience.

## Sources

| Borrowed from | What we took |
|---|---|
| ElevenLabs (voice AI) | Editorial display serif paired with a clean sans, tiny uppercase labels, pill CTAs, atmospheric gradient "orbs" used only as atmosphere |
| Linear | Hairline precision, near-black canvas, restraint with color |
| Brand orb palette (teal "orb-drop") | `#0E9AA7 → #A8F0E8 → #F2FFFD` with an iris `#512F7F` rim |

All shaders, sounds and the icon are original to this project. Fonts are open source (SIL OFL): **Geist** (UI) and **Instrument Serif** (display).

## Tokens

### Color

| Role | Value | Use |
|---|---|---|
| canvas | `#060709` | App background (OLED near-black) |
| canvasRaised / surface | `#0D0F13` / `#13161B` | Sheets |
| teal / aqua / ice | `#0E9AA7` / `#A8F0E8` / `#F2FFFD` | Orb, glows, user bubbles, primary pill (ice) |
| iris / violet | `#512F7F` / `#7B61FF` | Orb rim iridescence, background bloom |
| accept / danger | `#2FD37F` / `#FF4757` | Call buttons only (universal call semantics) |
| ink / body / muted / faint | `#F4F7F6` at 100 / 72 / 46 / 26% | Text hierarchy |
| hairline / hairlineStrong | white 9% / 16% | 0.5pt strokes |

Rule: the orb palette never fills large surfaces. The primary action is an **ice pill with dark text**, not a saturated button.

### Type

| Token | Font | Size | Notes |
|---|---|---|---|
| display | Instrument Serif | 36–58 | Agent name, greetings, sheet titles. Never bold. |
| body | Geist 400 | 16 | Chat bubbles, +0.1 tracking |
| label | Geist 500–600 | 13–15 | Buttons, chips |
| eyebrow | Geist 600 | 10.5 | Uppercase, +1.6 tracking, inside a hairline pill |
| mono | SF Mono | 13 | Call timer, engine log |

### Shape and depth

- **Double bezel:** outer shell (white 3.5%, 0.5pt hairline, radius 30) holding an inner glass core (white 5.5% + ultra-thin material, top-lit gradient stroke, radius 24, concentric).
- Bubbles: 20pt radius with a 6pt "tail" corner.
- Liquid Glass on iOS 26 for chips and round controls, with a material fallback on iOS 18.
- Shadows are colored glows (teal, red, green), never grey drop shadows.

### Motion

| Token | Spring | Use |
|---|---|---|
| spring | response 0.55, damping 0.84 | Screen and state changes |
| snappy | 0.34 / 0.8 | Presses, chips |
| gentle | 0.9 / 0.9 | Phase transitions (chat → home) |
| bouncy | 0.5 / 0.62 | Success moments (progress glyphs, Gmail check) |

Content never pops in: it rises 14pt from a blurred resting state (`riseIn`). All motion respects Reduce Motion (the orb drops to 4 fps, backgrounds freeze).

## Components

- **AgentOrb** (Metal, `Shaders/Orb.metal`): a glass sphere with a flowing marble interior, fresnel rim, iridescent edge, specular glint, film grain and an audio-reactive wobbly silhouette. Moods: `idle`, `listening`, `thinking`, `speaking`, `ringing`, `happy`, `sleepy`. It is grey-silver until the agent is named, then takes on the brand teal.
- **OrbEyes:** two capsules that blink on an irregular rhythm, drift their gaze, look up while thinking, widen while listening, and turn into happy arcs when setup completes. They make the agent feel like a character, not a widget.
- **PulseRings / WaveRing:** ringing rings on the incoming call screen; radial audio bars around the orb that react to the user's voice.
- **Eyebrow, IslandButton (button-in-button trailing icon), GlassCapsule chips, InputBar, GmailInlineCard, ProgressConstellation** (3 glyphs that light up as name, goal and Gmail are collected, so progress shows without feeling like a form).

## Do / Don't

- Do keep one focal element per screen (the orb, or the conversation).
- Do write copy like a person: "wants to finish setting up by voice", not "Voice onboarding step 2".
- Don't use progress bars, step counters, or field labels in the conversation.
- Don't use the teal as a button fill or text color on large surfaces.
