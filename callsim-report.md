# Voice call simulation

Model `gpt-realtime-2.1` · audio in via `gpt-4o-mini-tts` · 2 callers · 2026-09-28 20:07:07 +0000

| caller | result | call end | call | spoken/text turns | user | help need | gmail | barge-ins | judge | checks |
|---|---|---|---|---|---|---|---|---|---|---|
| hangs_up | graduated | userHungUp | 28s | 2/2 | Priya | Help me with invoices | connected | 0 | 9 | ok |
| hangs_up_fast | graduated | userHungUp | 20s | 1/0 | Nadia | Getting inbox under control | connected | 0 | 8 | ok |

**2/2 callers passed** (all checks + judge ≥ 7, no re-asking, not form-like, no tool narration).
Voice response latency (caller stops talking → agent audio starts): median 0.83 s, p90 0.83 s over 1 turns.

## hangs_up

Judge: ["reasked_known_info": 0, "felt_like_a_form": 0, "issues": [], "natural_turn_taking": 1, "clean_goodbye": 1, "narrated_tools": 0, "language_mirrored": 1, "score": 9]

Tools: save_user_name({"name":"Priya"})

Errors: []

```
[   0.0s] AGENT (text): Hey there, I'm your new personal assistant.
[   0.0s] AGENT (text): First things first: what would you like to call me?
[   0.0s] CALLER (text): Let's call you Mochi
[   3.1s] AGENT (text): Mochi it is! I’ll ring you for a quick call to get the rest set up—it’s faster than typing, and you can decline if you’d rather keep chatting here.
[   3.1s] [phone rings, caller answers]
[   5.2s] [call connected]
[   8.0s] AGENT (voice): Hey, it’s Mochi, the name you just gave me, and I love it! This will only take a minute—what should I call you?
[  15.0s] CALLER (voice): I'm Priya.
[  18.1s]    tool: save_user_name {"name":"Priya"}
[  18.3s]    heard (transcription): I'm Priya.
[  20.2s] AGENT (voice): Nice to meet you, Priya! I can sort your inbox, keep your calendar steady, or draft replies—what would you like to start with?
[  27.9s] CALLER (voice): oh sorry, I have to run!
[  33.2s] [caller taps End call]
[  33.9s]    heard (transcription): Oh, sorry, I have to run.
[  33.9s] [call ended: userHungUp, 28 s]
[  35.7s] AGENT (text): No worries, Priya—hope everything’s okay. When you’re back, just tell me what you’d like off your plate first.
[  36.3s] CALLER (text): Help me with invoices.
[  38.3s] AGENT (text): I can help track due dates, organize invoice details, or draft payment reminders—what would you like to start with?
[  38.8s] CALLER (text): Please connect my Gmail.
[  40.7s] AGENT (text): Sure—tap the secure connect button to link Gmail, which will help me find invoice emails and keep the details organized.
[  40.7s] [Connect Gmail button appears]
[  40.7s] [caller taps Connect Gmail]
[  42.8s] AGENT (text): Gmail’s connected—I'm excited to help you keep invoices and due dates from slipping through the cracks!
[  42.8s] [graduated → main app]
```

## hangs_up_fast

Judge: ["reasked_known_info": 0, "clean_goodbye": 0, "score": 8, "language_mirrored": 1, "felt_like_a_form": 0, "narrated_tools": 0, "issues": ["The assistant switched from the call to text without a short spoken goodbye."], "natural_turn_taking": 1]

Tools: save_user_name({"name": "Nadia"}), save_help_need({"summary": "Getting inbox under control", "category": "email"}), finish_call({"reason": "switch_to_text"})

Errors: []

```
[   0.0s] AGENT (text): Hey there, I'm your new personal assistant.
[   0.0s] AGENT (text): First things first: what would you like to call me?
[   0.0s] CALLER (text): Let's call you Luma
[   3.3s] AGENT (text): Luma it is—nice to meet you! I’ll ring you for a quick call to set up the rest; it’s faster than typing, and you can decline if you’d rather keep texting.
[   3.3s] [phone rings, caller answers]
[   5.4s] [call connected]
[   7.7s] AGENT (voice): Hey, it’s Luma, the name you just gave me, and I love it! This will only take a minute—what should I call you?
[  14.7s] CALLER (voice): Hi, I'm Nadia, I need help getting my inbox under control. Oh no, sorry, I have to go!
[  24.7s]    heard (transcription): Hi, I'm Nadia. I need help getting my inbox under control. Oh no, sorry, I have to go.
[  25.1s]    tool: save_user_name {"name": "Nadia"}
[  25.1s]    tool: save_help_need {"summary": "Getting inbox under control", "category": "email"}
[  25.1s]    tool: finish_call {"reason": "switch_to_text"}
[  25.1s] [agent wraps up: switchedToText]
[  25.9s] [caller taps End call]
[  25.9s] [call ended: userHungUp, 20 s]
[  28.2s] AGENT (text): No worries, Nadia—hope everything’s okay. Whenever you’re back, would you like to connect Gmail with the secure button so I can help sort your inbox and draft replies for your approval?
[  28.2s] [Connect Gmail button appears]
[  28.2s] [caller taps Connect Gmail]
[  29.9s] AGENT (text): Hooray, Nadia—we’re all set to get your inbox under control!
[  29.9s] [graduated → main app]
```
