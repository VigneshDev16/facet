# LinkedIn post — Facet (part 3 of the series)

Series: "building real solutions to problems I actually run into." Part 1 was Beam.

## How to post it

1. Create a **document post** and upload `Facet-carousel.pdf` (8 slides, 4:5).
   LinkedIn renders PDFs as a swipeable carousel — this is the format that gets reach.
2. Paste Option A as the post text.
3. Put the links in the **first comment**, not the post body — LinkedIn throttles
   reach on posts containing outbound links.

## Carousel document title

LinkedIn asks for a title when you upload the PDF. It's shown on the carousel card in
the feed, above the first slide — it's the hook people read before deciding to swipe,
so it does real work. Keep it under ~60 characters; the feed truncates past that.

**Recommended**

    Finding one person meant scrolling. So I built my own.   (53)

**Alternatives**

    Face search for your photos, without the cloud           (45)
    I built a face-search photo gallery for my Mac           (45)
    3,273 photos. One person. Twenty minutes of scrolling.   (53)
    Your photos, searchable by face — all on your Mac        (48)

Avoid a bare product name ("Facet") — nobody knows what it is yet, and the title is
the only thing working before the swipe.

## Links

- Code: https://github.com/VigneshDev16/facet
- Download (Apple Silicon, macOS 15+): https://github.com/VigneshDev16/facet/releases/download/v0.1.0/Facet-0.1.0-arm64.dmg
- Release notes: https://github.com/VigneshDev16/facet/releases/tag/v0.1.0

---

## Option A — recommended

I had 3,273 photos sitting in folders on my Mac. Finding every photo of one person
meant scrolling. For twenty minutes.

Apple Photos only groups faces inside its own library — my folders were invisible to it.
Google Photos wanted me to upload all of it. Immich and PhotoPrism wanted Docker, a
database and a server to babysit.

I just wanted to point something at a folder.

So I built **Facet**.

→ Finds every face and groups them into people, automatically
→ Click any face to pull up every other photo of that person
→ Search in plain English — "beach sunset", "birthday cake", "dog in snow"
→ Photos with two people together, or one person without the other
→ Open it on your phone from anywhere — read-only, so family can browse and
   download but never delete anything
→ No cloud, no account, no Docker, no server. One Mac app.

Everything runs on your Mac's Neural Engine. Nothing is uploaded. Nothing phones home.

And the face matching isn't hand-wavy — I benchmarked the whole pipeline against LFW,
the standard face-verification test: **99.32% accuracy at ~250 images/second**. A
100,000-photo library indexes in minutes, not hours.

The remote access is the part I didn't expect to enjoy so much. Your Mac serves a small
web app over your own private network, so the photos are on your phone without a single
one touching someone else's server.

Part 3 of the series: building real solutions to problems I actually run into.

Free and open source. Links in the comments.

#BuildInPublic #OpenSource #SideProject #macOS #MachineLearning #Privacy #Swift

### First comment

💻 Download for Mac (Apple Silicon): https://github.com/VigneshDev16/facet/releases/download/v0.1.0/Facet-0.1.0-arm64.dmg
⭐ Code: https://github.com/VigneshDev16/facet

It's signed ad-hoc rather than notarised, so the first launch needs a right-click → Open.
Once only.

---

## Option B — shorter

Part 3 of the series: building solutions for my own problems.

The problem: 3,273 photos in folders on my Mac, and no way to find one person without
scrolling. Apple Photos ignores anything outside its own library. Google Photos wants the
upload. Everything self-hosted wants Docker and a database.

The solution: **Facet**. Point it at a folder. It finds every face, groups them into
people, and lets you search by typing what's in the photo. Click a face to find everyone
else's shots of that person. Open it on your phone from anywhere — read-only, so family
can browse and download but not delete.

No cloud. No account. No server. It runs on your Mac's Neural Engine, and I benchmarked
it: 99.32% on LFW at ~250 images/sec.

Free and open source. Links in the comments.

#BuildInPublic #OpenSource #macOS #Privacy

---

## Option C — leads with the self-hosting angle

Self-hosted photo apps ask a lot of you. Docker, a database, a reverse proxy, a domain,
certificates. I wanted to look at my own photos on my phone.

**Facet** is a Mac app. You open it, point it at a folder, and it does three things:
finds every face and groups them into people, lets you search by typing what's in a
photo, and — if you want it — serves the whole library to your phone over your own
private network.

That last part is read-only by design. Not a permission toggle: there are no write
endpoints in the code at all, so family can browse and download but the library itself
can only be changed on the Mac.

Everything runs on the Neural Engine locally. 99.32% on the LFW face benchmark,
~250 images/sec. No cloud, no account, no subscription.

Part 3 of the series: building real solutions to problems I actually run into.

#BuildInPublic #SelfHosted #OpenSource #macOS #Privacy
