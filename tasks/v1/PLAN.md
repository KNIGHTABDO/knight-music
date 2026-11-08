# Duet v1.0 — plan (started 2026-11-08)

User request: full-quality film render; then v1.0 release of Duet with an intro like Streamora's
(film → perfect, invisible handoff) in the **app** and on the **website**; Streamora's site landing becomes the
**Duet** landing (with the promo film); IPA/README/everything renamed to Duet. "Make it your app."

Decisions (user, 2026-11-08):
- Film is bundled publicly (IPA + website) — user chose this knowing it holds Nolan trailers + "Shotta's".
- Website = Streamora's site (streamora-5w5.pages.dev): its landing becomes Duet's landing; the web app keeps working.
- Bundle id stays `com.knightabdo.knightmusic` (changing it = new app, data + updates lost). Repo name stays.

## 1. Film deliverables (promo/duet, private repo KNIGHTABDO/duet-film)
- [ ] 1080p60 delivery render (render.yml preview=false) → `promo/duet/renders/duet-1080p60.mp4`
- [ ] encode in CI (not laptop): app `duet-intro.mp4` HEVC 1080p30 (hvc1, faststart, ~35–45 MB);
      web `film-720.mp4` / `film-480.mp4` H.264 + `film-poster.webp`; handoff still at HANDOFF_T
- [ ] upload app film to knight-music release `intro-assets` (prerelease); ios.yml fetches it into
      `KnightMusic/Resources/Intro/` (gitignored), like scripts/fetch-vlckit.sh

Film facts: D=94.34. End card from EN=89.12 (icon #eIc 300x300 at 810,150 r68, scale→1.04 by ~92.0).
Black fade (#eBl) starts D-1.2=93.14 → **HANDOFF_T = 93.0** (end card settled, before the fade).

## 2. Native intro (app)
- `UI/Intro/IntroFilm*`: full-screen window above everything (`.normal+3`), AVPlayerLayer, letterboxed (aspect fit,
  black). Plays on first launch of v1.0 (`introSeenVersion`), and from Settings → "Play the Duet film".
- Skip: glass pill fades in after ~3 s; skipping hands off from the current frame (same handoff, never a cut).
- Handoff at HANDOFF_T: pause → snapshot → **page curl up** (Duet's own switch gesture, same as the film's curls)
  revealing the already-mounted app (onboarding or Home). Audio fades over the curl.
- Then teach the gesture: DuetHUD glass pill "Shake to switch to movies" once.
- Audio session: soloAmbient during the film (respects silent switch), restore PlayerEngine's session after.
- Never during background/CarPlay launch; never when the user has started playback.

## 3. Web (streamora repo)
- index.html boot: skip the web intro inside Duet (`window.__duet` set by StreamoraBridgeScript at doc start).
- js/intro.js: Duet film (480/720) + the peel; the flying mark = Duet icon (from the frozen frame's icon rect into
  the landing logo). Erase the icon from the frozen frame (clean-plate still or eraseMark).
- Landing → Duet: music + movies, SideStore source / IPA links, "Watch the film" section, Streamora web entry.
- Deploy per streamora DEPLOY.md / HANDOFF.

## 4. Rename to Duet
- ios.yml: `Duet.ipa`, release title "Duet vX"; make-source.py names/URLs; README/docs; updater already accepts any
  .ipa asset (UpdateChecker picks first *.ipa) so old installs update fine.

## 5. Release
- MARKETING_VERSION 1.0.0, release notes, tag v1.0.0 (no [shots] on tag commit), check SideStore source JSON.
