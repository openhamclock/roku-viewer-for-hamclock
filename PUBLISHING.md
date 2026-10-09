# Publishing to the Roku Streaming Store

Everything here is based on Roku's public developer documentation (links at the bottom). Items marked
**UNVERIFIED** are things I could not confirm from the docs - check them in the Developer Dashboard.

## What is already done in this project

- Manifest: non-zero version (1.0.x), FHD **and** HD splash screens, icons, small package (~35 KB; limit 4 MB).
- Launch beacons: `AppLaunchComplete`, plus `AppDialogInitiate/Complete` around the first-run address dialog.
- Back key exits the channel from the main screen (Roku rule 4.6).
- Picture inset to stay inside TV overscan; no use of the network except the address the user types.
- Store poster (`store/poster_540x405.png`), listing text (`store/listing.md`), privacy policy draft
  (`store/privacy-policy.md`).

## What only you can do

### 1. Name and rights  (decide this first)

Roku requires "full rights or consent" for the app name, and the name must identify the company behind it.
"HamClock" is the name of someone else's software.

- Check HamClock's license and whether its author or rights holder permits a channel using that name.
- If in doubt, use a descriptive name that does not use the mark, e.g. "TV Viewer for Ham Dashboards", and keep
  the "works with HamClock" wording in the description only (the listing already says it is unofficial).
- To rename: edit `title=` in `channel/manifest`, change the names in `store/listing.md`, and regenerate the
  poster with `python3 tools/make_poster.py "New Name"`.

### 2. Developer account

Create a Roku developer account at developer.roku.com. Roku says the account should be owned by whoever owns
the content (you, or your organization). Link the Roku you will package on to this account.

### 3. Screenshots (up to six, 1920x1080)

Roku's developer web page on your Roku (`http://<roku-ip>`) has a **Utilities -> Screenshot** tool. With the
channel running, capture:
1. The live HamClock screen full size
2. The cursor over a button
3. HamClock's popup after a tap
4. The address dialog (shows first-run setup)

Use your own HamClock screens only. Keep call signs and locations you don't want public out of shot.

### 4. Hosting the privacy policy

Roku wants a URL. Fill in the `[placeholders]` in `store/privacy-policy.md` and host it anywhere public, for
example a GitHub Pages site or a public gist. Use the same page's address for the support contact if you like.

### 5. Package a store build (no baked address)

```
bash tools/build.sh            # NOT build.sh <address>: the store build must have no address in it
```
Sideload `dist/hamclock-roku.zip` to your Roku (`http://<roku-ip>`, Upload, Install), then:

1. `telnet <roku-ip> 8080`, run **`genkey`**, and write down the **Dev ID and password**. Do this **once**.
2. On the Roku's developer page, open the **Packager** (top right), check the Dev ID matches, enter an app
   name/version and the password, click **Package**, and download the `.pkg`.
3. **Back up the password and the `.pkg` somewhere safe.** Every future update must be signed with the same
   key, and Roku's docs give no recovery if you lose both the password and the package.

The Roku must be linked to your developer account and online for packaging to work. The Packager only shows
up after an app is sideloaded.

### 5b. Squashfs / minimum firmware

If you tick the compress option, Roku says to use Squashfs for OS 8.0+ and set the minimum firmware to 8.0 or
higher. This project uses BrightScript `try/catch`, which I believe needs a fairly recent OS (around 9.x),
so set the minimum firmware to 9.0 or higher. **UNVERIFIED:** the exact OS version that introduced
`try/catch`, and where the dashboard asks for the minimum firmware - check both before submitting.

### 6. Dashboard: create the app

Developer Dashboard -> add a **public** app and fill in:

| Field | Value |
|---|---|
| Package | the signed `.pkg` |
| Name, descriptions | `store/listing.md` |
| Poster | `store/poster_540x405.png` |
| Screenshots | your captures from step 3 |
| App type | App / Utility |
| Privacy policy / support | your URLs and contact |
| Category, age rating, countries | your choice / questionnaire (**UNVERIFIED** category names) |
| Sign-in / test credentials | none (the app has no accounts) |

### 7. Deep linking  (the open question)

Roku's certification criteria (5.1) say apps must support deep linking for all media types, and the
publishing guide says apps submitted without deep-linking parameters will not pass, with an exception for a
single live feed. This channel has **no media content**, so it is unclear how Roku applies that rule.
**UNVERIFIED.** Before submitting, ask on the Roku developer forum or through developer support whether a
non-media utility needs deep-linking parameters, and what to enter (or whether the field can be left empty).
Do this early: it is the most likely thing to block certification.

### 8. Certification checks and scheduling

- **Static Analysis** must show no errors. Fix warnings too.
- **App Behavior Analysis** (self-serve): the launch test needs the `AppLaunchComplete` beacon (done).
- Roku measures performance on a Streaming Stick+ (3810X) or Premiere+ (3921X): launch to a rendered screen
  within 15 s, response to key presses within 250 ms. You will want to test on a similar device if you can.
- Scheduling: earliest publish date is the second business day after scheduling; not Fridays or weekends.
- You must certify you have the rights to distribute the app.

Expect questions from reviewers: they need a HamClock to test with. Consider adding a note to the review
form explaining that the channel needs the user's own HamClock, and how a reviewer can reach one (**UNVERIFIED**
whether Roku gives reviewers a notes field; ask support if the dashboard has none).

### 9. Updating later

Increase `minor_version` (or `build_version`) in `channel/manifest`, build, package with the **same key**,
upload, and re-certify. Code updates need re-certification.

## Known limits of this channel

- Live mode uses raw TCP and speaks WebSocket itself, because Roku's `roWebSocket` is blocked for this kind of
  app on tested hardware ("WebSockets are not allowed"). It works, but it is a workaround; Roku could review it.
- The channel talks to an unencrypted `ws://` port on the user's LAN. HamClock's live port also lets anyone on
  that LAN control HamClock, so tell users not to expose it to the internet.

## Sources

- Roku app publishing guide: https://developer.roku.com/docs/developer-program/publishing/channel-publishing-guide.md
- Roku certification criteria: https://developer.roku.com/docs/developer-program/certification/certification.md
- Packaging Roku apps: https://developer.roku.com/dev/docs/packaging-channels
