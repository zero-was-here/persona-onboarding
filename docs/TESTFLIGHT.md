# TestFlight checklist

**App:** Persona Trial · bundle `com.eljebari.personaonboarding` · team BX2Z3922K9 · iOS 18+ · iPhone only

## Beta App Description
A prototype onboarding for a personal AI assistant. You name your assistant, it gives you a quick voice call to learn your name and what you need help with, and you connect Gmail (simulated in this build). It adapts if you decline or hang up the call, go off-script, or want to skip ahead.

## What to Test
1. Name your assistant (tap a suggestion or type one).
2. Answer the incoming call and talk naturally. Try interrupting it, going quiet, answering things out of order, or asking to switch to text.
3. Try declining the call, hanging up midway, or "Message instead": everything continues in chat with nothing lost.
4. Connect Gmail with the button (sign-in is simulated; any address works).
5. Tester tools (slider icon, top right): live state, "Drop the call", "Pretend microphone is denied", "Restart onboarding".

## Beta App Review notes
No login required. Microphone is used only during the in-app voice call with the assistant. Gmail sign-in is simulated (no Google data is accessed). Uses OpenAI APIs for speech and language.

Export compliance: `ITSAppUsesNonExemptEncryption = NO` is set in the build (standard HTTPS only).
