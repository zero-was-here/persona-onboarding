# Privacy (prototype)

This is a prototype built for a hiring trial.

- **Microphone:** used only while you're on the in-app voice call. Audio is streamed to OpenAI to power the conversation and live captions, and isn't stored by this app.
- **Chat:** your messages are sent to OpenAI to generate replies. The onboarding state is stored only on your device.
- **Gmail:** a real Google sign-in (OAuth with PKCE) asking only for basic profile info and Gmail label names (`gmail.labels`). The app reads the label list once to confirm the connection (the assistant may mention up to three label names, and the email address plus label count are kept in the on-device onboarding state). It never reads, sends or stores email content, and the access token is kept only in memory. If no Google client is configured, a clearly labeled demo connection is used instead.
- **No tracking, no ads, no selling of data.** Restart onboarding from Tester tools to clear local data.
