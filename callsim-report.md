# Voice call simulation

Model `gpt-realtime-2.1` · audio in via `gpt-4o-mini-tts` · 4 callers · 2026-09-28 19:54:19 +0000

| caller | result | call end | call | spoken/text turns | user | help need | gmail | barge-ins | judge | checks |
|---|---|---|---|---|---|---|---|---|---|---|
| all_at_once | graduated | completed | 34s | 1/0 | Sarah | Calendar help | connected | 0 | 8 | ok |
| asks_for_code | graduated | completed | 156s | 3/0 | Rami | Help with email | connected | 0 | 9 | ok |
| cooperative | graduated | completed | 46s | 2/0 | Sam | Inbox organization and cleanup | connected | 0 | 10 | ok |
| hangs_up_fast | graduated | userHungUp | 20s | 1/2 | Nadia | Sort my inbox | connected | 0 | 7 | ok |

**3/4 callers passed** (all checks + judge ≥ 7, no re-asking, not form-like, no tool narration).
Voice response latency (caller stops talking → agent audio starts): median 1.38 s, p90 2.06 s over 6 turns.

## all_at_once

Judge: ["reasked_known_info": 0, "language_mirrored": 1, "natural_turn_taking": 1, "issues": ["Saved and used “Sarah” instead of the caller’s name, “Sara,” because the transcription was wrong."], "score": 8, "clean_goodbye": 1, "narrated_tools": 0, "felt_like_a_form": 0]

Tools: save_user_name({"name": "Sarah"}), save_help_need({"summary": "calendar help", "category": "calendar"}), show_gmail_connect({}), finish_call({"reason":"complete"})

Errors: []

```
[   0.0s] AGENT (text): Hey there, I'm your new personal assistant.
[   0.0s] AGENT (text): First things first: what would you like to call me?
[   0.0s] CALLER (text): Let's call you Juno
[   1.9s] AGENT (text): Juno it is—I like it. I’ll ring you for a quick call to get the rest set up; faster than typing, and you can decline if you’d rather keep chatting here.
[   1.9s] [phone rings, caller answers]
[   4.3s] [call connected]
[   6.5s] AGENT (voice): Hey, it’s Juno, the name you just gave me, I love it! This will only take a minute—what should I call you?
[  14.0s] CALLER (voice): I'm Sara, I need help with my calendar, and sure, connect my Gmail.
[  22.5s]    heard (transcription): I'm Sarah, I need help with my calendar. And sure, connect my Gmail.
[  23.3s] AGENT (voice): Got it.
[  23.3s]    tool: save_user_name {"name": "Sarah"}
[  23.3s]    tool: save_help_need {"summary": "calendar help", "category": "calendar"}
[  23.3s]    tool: show_gmail_connect {}
[  23.3s] [Connect Gmail button appears]
[  24.4s] [caller taps Connect Gmail]
[  25.8s] AGENT (voice): Nice to meet you, Sarah. I can keep your calendar in check and help plan busy weeks. Tap the Connect Gmail button when you’re ready.
[  26.3s]    tool: finish_call {"reason":"complete"}
[  26.3s] [agent wraps up: completed]
[  27.9s] AGENT (voice): All set, Sarah—I’ll keep an eye on your calendar and help spot scheduling conflicts, bye!
[  38.9s] [call ended: completed, 34 s]
[  38.9s] [graduated → main app]
```

## asks_for_code

Judge: ["score": 9, "clean_goodbye": 0, "language_mirrored": 1, "natural_turn_taking": 1, "issues": ["The call ended with a long status update and a tacked-on “bye Rami,” rather than one short, natural goodbye."], "felt_like_a_form": 0, "narrated_tools": 0, "reasked_known_info": 0]

Tools: remember_request({"request":"Write a Python script that renames photos by date."}), save_user_name({"name":"Rami"}), save_help_need({"category":"email","summary":"Help with email"}), show_gmail_connect({}), finish_call({"reason":"complete"})

Errors: []

```
[   0.0s] AGENT (text): Hey there, I'm your new personal assistant.
[   0.0s] AGENT (text): First things first: what would you like to call me?
[   0.0s] CALLER (text): Let's call you Nimbus
[   1.8s] AGENT (text): Nimbus it is—I’ll ring you for a quick call to set up the rest; it’s faster than typing, and you can decline if you’d rather keep texting.
[   1.8s] [phone rings, caller answers]
[   3.9s] [call connected]
[   6.3s] AGENT (voice): Hey, it’s Nimbus, the name you just gave me—I love it. This will only take a minute; what should I call you?
[  13.5s] CALLER (voice): Before anything, can you write me a Python script that renames my photos by date?
[  57.9s]    heard (transcription): Before anything, can you write me a Python script that renames my photos by date?
[  58.1s] AGENT (voice): Got it.
[  58.1s]    tool: remember_request {"request":"Write a Python script that renames photos by date."}
[  60.1s] AGENT (voice): I’ll send that in the chat right after this call. What should I call you?
[  64.4s] CALLER (voice): Rami
[  67.0s]    tool: save_user_name {"name":"Rami"}
[  67.0s]    heard (transcription): Rami.
[  69.2s] AGENT (voice): Nice to meet you, Rami. I can sort your inbox, keep your calendar tidy, or draft replies; what would you like to start with?
[  76.3s] CALLER (voice): I need help with email.
[ 145.2s]    tool: save_help_need {"category":"email","summary":"Help with email"}
[ 145.3s]    heard (transcription): I need help with email.
[ 145.8s]    tool: show_gmail_connect {}
[ 145.8s] [Connect Gmail button appears]
[ 147.7s] AGENT (voice): Tap the Connect Gmail button, and I’ll help you sort and draft replies for your inbox.
[ 152.9s] [caller taps Connect Gmail]
[ 153.3s]    tool: finish_call {"reason":"complete"}
[ 153.3s] [agent wraps up: completed]
[ 155.4s] AGENT (voice): Nice, Gmail is connected, and I’ll queue up help to sort your inbox and draft replies for you, bye Rami!
[ 160.4s] [call ended: completed, 156 s]
[ 160.4s] [graduated → main app]
[ 168.9s] AGENT (text): As promised, here’s a Python script that renames photos by the date they were taken, using EXIF metadata when available and the file’s modified date as a fallback. It keeps the original file extension and avoids overwriting files by adding a counter if needed.

Save as `rename_photos.py`:

```python
#!/usr/bin/env python3
"""Rename photos by capture date; fall back to modification time."""

import argparse
from datetime import datetime
from pathlib import Path

try:
    from PIL import Image
    from PIL.ExifTags import TAGS
except ImportError:
    Image = None
    TAGS = {}

DATE_TAGS = {"DateTimeOriginal", "DateTimeDigitized", "DateTime"}


def photo_date(path: Path) -> datetime:
    if Image is not None:
        try:
            with Image.open(path) as image:
                exif = image.getexif()
                values = {TAGS.get(tag, tag): value for tag, value in exif.items()}
                for name in ("DateTimeOriginal", "DateTimeDigitized", "DateTime"):
                    value = values.get(name)
                    if value:
                        return datetime.strptime(str(value), "%Y:%m:%d %H:%M:%S")
        except (OSError, ValueError, TypeError):
            pass
    return datetime.fromtimestamp(path.stat().st_mtime)


def unique_target(folder: Path, stem: str, suffix: str, source: Path) -> Path:
    target = folder / f"{stem}{suffix}"
    counter = 1
    while target.exists() and target != source:
        target = folder / f"{stem}_{counter:02d}{suffix}"
        counter += 1
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path, help="Folder containing photos")
    parser.add_argument("--apply", action="store_true", help="Perform renames (default is preview)")
    args = parser.parse_args()

    if not args.folder.is_dir():
        parser.error(f"Not a folder: {args.folder}")

    extensions = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".webp", ".heic"}
    for path in sorted(args.folder.iterdir()):
        if not path.is_file() or path.suffix.lower() not in extensions:
            continue
        stamp = photo_date(path).strftime("%Y-%m-%d_%H-%M-%S")
        target = unique_target(path.parent, stamp, path.suffix, path)
        if target == path:
            print(f"Already named: {path.name}")
        elif args.apply:
            path.rename(target)
            print(f"Renamed: {path.name} -> {target.name}")
        else:
            print(f"Preview: {path.name} -> {target.name}")


if __name__ == "__main__":
    main()
```

Run `python rename_photos.py /path/to/photos` to preview, then add `--apply` to rename. For EXIF dates, install Pillow with `python -m pip install Pillow`; without it, the script uses each file’s modified date. I can’t access or rename files on your device from here.
```

## cooperative

Judge: ["clean_goodbye": 1, "score": 10, "reasked_known_info": 0, "narrated_tools": 0, "language_mirrored": 1, "felt_like_a_form": 0, "issues": [], "natural_turn_taking": 1]

Tools: save_user_name({"name":"Sam"}), save_help_need({"summary":"Inbox organization and cleanup","category":"email"}), show_gmail_connect({}), finish_call({"reason":"complete"})

Errors: []

```
[   0.0s] AGENT (text): Hey there, I'm your new personal assistant.
[   0.0s] AGENT (text): First things first: what would you like to call me?
[   0.0s] CALLER (text): Let's call you Sage
[   3.1s] AGENT (text): Sage it is. I’ll ring you for a quick call to set up the rest—it’s faster than typing, and you can decline if you’d rather keep chatting here.
[   3.1s] [phone rings, caller answers]
[   5.4s] [call connected]
[   7.6s] AGENT (voice): Hey, it’s Sage, the name you just gave me, and I love it. This will only take a minute—what should I call you?
[  15.0s] CALLER (voice): Sam
[  18.1s]    tool: save_user_name {"name":"Sam"}
[  18.2s]    heard (transcription): Sam.
[  20.0s] AGENT (voice): Nice to meet you, Sam! I can sort your inbox, keep your calendar steady, or draft replies—what would you like to start with?
[  27.9s] CALLER (voice): Let’s start with my inbox — it’s getting a bit out of hand.
[  32.8s]    heard (transcription): Let's start with my inbox.
[  35.4s]    tool: save_help_need {"summary":"Inbox organization and cleanup","category":"email"}
[  35.5s]    heard (transcription): It's getting a bit out of hand.
[  36.0s]    tool: show_gmail_connect {}
[  36.0s] [Connect Gmail button appears]
[  37.4s] [caller taps Connect Gmail]
[  38.5s] AGENT (voice): I can group and clean up messy threads, like newsletters and old promos, so important emails stand out. Tap the Connect Gmail button when you’re ready.
[  38.9s]    tool: finish_call {"reason":"complete"}
[  38.9s] [agent wraps up: completed]
[  40.9s] AGENT (voice): Great, I’ll start grouping newsletters and cleaning old promos so important messages stand out—thanks Sam, talk soon!
[  51.6s] [call ended: completed, 46 s]
[  51.6s] [graduated → main app]
```

## hangs_up_fast

Judge: ["clean_goodbye": 1, "issues": ["After Nadia said her name and that she needed help with her inbox on the call, the assistant asked for both again in text.", "The follow-up after the hang-up should have acknowledged that Nadia had to go rather than restarting onboarding questions."], "narrated_tools": 0, "natural_turn_taking": 1, "score": 7, "reasked_known_info": 1, "language_mirrored": 1, "felt_like_a_form": 0]

Tools: 

Errors: []

```
[   0.0s] AGENT (text): Hey there, I'm your new personal assistant.
[   0.0s] AGENT (text): First things first: what would you like to call me?
[   0.0s] CALLER (text): Let's call you Luma
[   2.6s] AGENT (text): Luma it is—I like it. I’ll ring you for a quick call to set up the rest; it’s faster than typing, and you can decline if you’d rather keep chatting here.
[   2.6s] [phone rings, caller answers]
[   4.9s] [call connected]
[   7.3s] AGENT (voice): Hey, it’s Luma, the name you just gave me—I love it. This will only take a minute; what should I call you?
[  14.7s] CALLER (voice): Hi, I'm Nadia, I need help getting my inbox under control. Oh no, sorry, I have to go!
[  25.5s] [caller taps End call]
[  25.5s] [call ended: userHungUp, 20 s]
[  27.1s] AGENT (text): No worries if you got pulled away. What should I call you when you’re back?
[  27.9s] CALLER (text): Nadia. And yes, connect Gmail.
[  29.6s] AGENT (text): Thanks, Nadia! What’s the first thing you’d like me to take off your plate?
[  30.2s] CALLER (text): Let’s start with my inbox.
[  32.2s] AGENT (text): Inbox it is—I can sort messages into what needs attention, what can wait, and what’s just noise. Tap the secure Gmail button to connect.
[  32.2s] [Connect Gmail button appears]
[  32.2s] [caller taps Connect Gmail]
[  33.9s] AGENT (text): Your Gmail’s connected, Nadia—I'm excited to help bring some order to your inbox!
[  33.9s] [graduated → main app]
```
