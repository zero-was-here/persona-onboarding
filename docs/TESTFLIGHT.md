# TestFlight checklist

**App:** Persona Trial · bundle `com.eljebari.personaonboarding` · team BX2Z3922K9 · iOS 18+ · iPhone only

## Beta App Description
A prototype onboarding for a personal AI assistant. You name your assistant, it gives you a quick voice call to learn your name and what you need help with, and you connect Gmail with a real Google sign-in (it only asks to see your label names). It adapts if you decline or hang up the call, go off-script, or want to skip ahead.

## What to Test
1. Name your assistant (tap a suggestion or type one).
2. Answer the incoming call and talk naturally. Try interrupting it, going quiet, answering things out of order, or asking to switch to text.
3. Try declining the call, hanging up midway, or "Message instead": everything continues in chat with nothing lost.
4. Connect Gmail with the button: a real Google sign-in that only asks to see your Gmail label names, never your emails.
5. Tester tools (slider icon, top right): live state, "Drop the call", "Pretend microphone is denied", "Restart onboarding".
6. Tester tools → Autopilot caller: watch an AI caller go through the whole onboarding by voice (interrupting, refusing Gmail, speaking French…).

## Beta App Review notes
No login required. Microphone is used only during the in-app voice call with the assistant. Gmail uses a real Google sign-in requesting only basic profile info and Gmail label names (gmail.labels); no email content is read. Uses OpenAI APIs for speech and language.

Export compliance: `ITSAppUsesNonExemptEncryption = NO` is set in the build (standard HTTPS only).

## Upload steps (about 15 minutes of clicking, then Apple's processing)
1. App Store Connect → Apps → **+** → New App: iOS, name e.g. "Persona Onboarding Trial" (names must be unique on the store), bundle ID `com.eljebari.personaonboarding`, SKU `persona-trial`. Skip if the record already exists.
2. Xcode: set the run destination to **Any iOS Device (arm64)**, then **Product → Archive**.
3. Organizer → **Distribute App → App Store Connect → Upload**, keep automatic signing and the defaults.
4. App Store Connect → the app → **TestFlight**: wait for the build to finish processing (usually 10–30 min) and paste "What to Test" from above.
5. Create an **External** group (e.g. "Reviewers"), add the build, fill in the Beta App Review info above, and submit. Once it's approved (often a few hours), turn on the **Public Link** and share it.
