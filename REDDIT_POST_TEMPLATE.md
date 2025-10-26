# Reddit Post Template

## For r/swift, r/macosprogramming, or r/VideoEditing

---

### Title
```
[Help] Critical VT-12785 Deadlock in Multi-Layer Video Editor (Swift/VideoToolbox)
```

### Body

```markdown
Hi r/swift,

I'm working on a video editor for macOS and hit a VideoToolbox challenge that I can't solve alone. This is a **real technical problem** with VT error -12785 causing a cascading deadlock.

## The Problem

After rapid scrubbing, the entire playback pipeline freezes:

- **Symptom:** Renderer stuck on stale frames, both forward/backward scrubbing broken
- **Root cause:** VT decode tasks fail with -12785 but never release admission slots
- **Result:** Admission counter wedges at `10/8` (over limit!), landing zone starves, watchdog never triggers

## Why This is Interesting

This isn't your typical "how do I decode a frame?" question. It involves:
- VideoToolbox low-level error handling
- Multi-layer NLE coordination (each clip has its own decoder)
- Admission control semaphore patterns
- Async task lifecycle guarantees
- GOP boundary handling during direction changes

There's **no Stack Overflow answer** for this. It's a real architectural challenge.

## The Repository

**GitHub:** https://github.com/lilluzifer/cinnamon-public

**What makes it helpful:**
- ✅ Complete architecture docs with line numbers ([ARCHITECTURE.md](https://github.com/lilluzifer/cinnamon-public/blob/main/ARCHITECTURE.md))
- ✅ Detailed deadlock analysis + 4 proposed solutions ([KNOWN_ISSUES.md](https://github.com/lilluzifer/cinnamon-public/blob/main/KNOWN_ISSUES.md))
- ✅ Built-in diagnostics (Cmd+Shift+D to enable)
- ✅ Reproduction steps
- ✅ Compiles immediately - just `open cinnamon.xcodeproj`

**Key problem files:**
- `AdmissionController.swift:106` - Counter leak on task failure
- `IntegratedScrubPipeline.swift:595` - Watchdog doesn't trigger
- `EnhancedScrubDecoder.swift:1677` - VT-12785 not handled

## What I'm Looking For

If you have experience with:
- VideoToolbox error handling (especially -12785)
- Admission control / semaphore patterns in Swift
- VT session lifecycle management
- Guaranteeing cleanup in async error paths

...your insights would be incredibly valuable.

Even if you can't code a fix, **comments on the approach** would help:
- Should I rebuild the VT session on -12785?
- Should admission use `defer` blocks for guaranteed cleanup?
- Is my watchdog logic flawed?

## Why Contribute?

**Learning opportunity:**
- Hands-on with VTDecompressionSession
- Real-world NLE architecture
- Advanced async/concurrent patterns

**Help the community:**
- Very few open-source macOS video editors
- Your solution could help others with VT issues

**Recognition:**
- Contributors listed in README with GitHub links
- Credited in commits and docs

**Transparency:**
This is a learning project for me. I'm not a video processing expert - just someone who dived deep and hit a wall. The code is well-documented because I had to understand it myself as I built it.

## Try It Yourself

```bash
git clone https://github.com/lilluzifer/cinnamon-public.git
cd cinnamon-public
open cinnamon.xcodeproj
# Build, import a video, scrub back and forth rapidly
# Watch it deadlock, then check diagnostics (Cmd+Shift+D)
```

Any help, ideas, or even "this is fundamentally wrong because..." would be appreciated! 🙏

---

**Links:**
- Repo: https://github.com/lilluzifer/cinnamon-public
- Issue analysis: [KNOWN_ISSUES.md](https://github.com/lilluzifer/cinnamon-public/blob/main/KNOWN_ISSUES.md)
- Contributing guide: [CONTRIBUTING.md](https://github.com/lilluzifer/cinnamon-public/blob/main/CONTRIBUTING.md)
```

---

## Alternative Shorter Version (for initial post)

```markdown
**[Help] VT-12785 Deadlock in Video Editor**

Building a macOS video editor, hit a VideoToolbox deadlock I can't solve:

**Problem:** VT error -12785 causes decode tasks to fail without releasing admission slots → counter wedges at 10/8 → pipeline freezes

**Repo:** https://github.com/lilluzifer/cinnamon-public
- Complete deadlock analysis: [KNOWN_ISSUES.md](...)
- Architecture docs with line numbers
- Compiles immediately, built-in diagnostics

**Looking for:** VideoToolbox / async cleanup expertise

**Why interesting:** Real NLE challenge, no Stack Overflow answer, well-documented, learning opportunity

This is a learning project but the problem is real. Any insights appreciated! 🙏
```

---

## Tips for Posting

### DO:
- ✅ Be authentic about it being a learning project
- ✅ Emphasize the **technical challenge** aspect
- ✅ Show you've done your homework (detailed docs)
- ✅ Make it easy to help (clear problem, line numbers)
- ✅ Offer recognition for contributions
- ✅ Ask specific questions, not just "please fix"

### DON'T:
- ❌ Use "vibe coding" or similar casual terms
- ❌ Apologize excessively for being a learner
- ❌ Just say "help me" without context
- ❌ Oversell the project
- ❌ Hide that it's a learning project
- ❌ Make it sound desperate

### Key Message:
> "This is a learning project, but the technical problem is real and interesting. Here's everything you need to understand it. Any help appreciated."

---

## Posting Strategy

1. **r/swift** - Start here (biggest community, most helpful)
2. **Wait 24h** - See responses
3. **r/macosprogramming** - Cross-post if needed
4. **r/VideoEditing** - Maybe later, more user-focused

**Best time to post:**
- Weekday mornings (US/EU timezone)
- Avoid weekends (lower engagement)
