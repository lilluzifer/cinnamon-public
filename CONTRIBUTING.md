# Contributing to Cinnamon

Thank you for your interest in helping with Cinnamon! 🙏

## Why Contribute?

### 1. Interesting Technical Challenge
The **VT-12785 admission deadlock** is a real, non-trivial problem involving:
- VideoToolbox low-level APIs
- Async task lifecycle management
- Multi-threaded decoder coordination
- Admission control semaphores

This is the kind of challenge that doesn't have a Stack Overflow answer.

### 2. Learn Advanced Video Processing
Working on this project gives you hands-on experience with:
- VideoToolbox (VTDecompressionSession)
- H.264 GOP structure and IDR frames
- Frame-accurate scrubbing algorithms
- Metal rendering pipeline
- Professional NLE architecture

### 3. Help the macOS Developer Community
There are **very few** open-source video editors on macOS using native frameworks. Solving this helps:
- Other developers facing similar VT issues
- Students learning video processing
- The Swift/macOS community in general

### 4. Well-Documented Codebase
Unlike many open-source projects:
- ✅ Comprehensive architecture documentation ([ARCHITECTURE.md](ARCHITECTURE.md))
- ✅ Detailed issue analysis ([KNOWN_ISSUES.md](KNOWN_ISSUES.md))
- ✅ Line-by-line references to problem areas
- ✅ Built-in diagnostics and telemetry
- ✅ Clear reproduction steps

### 5. Recognition
Contributors will be:
- Listed in README.md with GitHub profile links
- Credited in commit messages
- Acknowledged in release notes (if we get there!)

---

## What Kind of Help is Needed?

### 🔴 Critical Priority

**Fix the Admission Deadlock** ([KNOWN_ISSUES.md](KNOWN_ISSUES.md))
- VT-12785 error handling
- Admission counter leak prevention
- Watchdog trigger logic
- Task cleanup guarantees

**Skills needed:**
- VideoToolbox experience
- Understanding of semaphores/admission control
- Async/await error handling in Swift

### 🟡 High Priority

**Multi-Layer Coordination**
- Per-clip vs. global admission strategies
- Layer synchronization during scrubbing
- Composition-wide failsafe mechanisms

**Skills needed:**
- NLE architecture knowledge
- Multi-threaded coordination
- Resource pooling patterns

### 🟢 Medium Priority

**Performance Optimization**
- Landing zone prediction tuning
- GOP reuse heuristics
- Cache eviction strategies

**Skills needed:**
- Video codec knowledge
- Performance profiling
- Algorithm optimization

### 💙 Nice to Have

**Documentation & Testing**
- Unit tests for core components
- Integration test scenarios
- Performance benchmarks
- Additional architecture diagrams

---

## How to Contribute

### 1. Start Small

**Good first contributions:**
- Review [KNOWN_ISSUES.md](KNOWN_ISSUES.md) and add your analysis
- Try to reproduce the deadlock and document your findings
- Suggest alternative approaches in GitHub Issues
- Review the proposed solutions and provide feedback

### 2. Discuss First

Before starting major work:
1. **Open an issue** describing your proposed approach
2. **Tag it** with relevant labels (e.g., `admission-control`, `vt-error-handling`)
3. **Wait for feedback** to ensure alignment

This prevents duplicate work and ensures your effort is valuable.

### 3. Code Contributions

**Branch naming:**
- `fix/admission-deadlock` - Bug fixes
- `feature/better-watchdog` - New features
- `refactor/error-handling` - Code improvements

**Commit messages:**
```
Fix admission counter leak on VT-12785 errors

- Add defer block to guarantee slot release
- Implement counter validation failsafe
- Add telemetry for leak detection

Fixes #42
```

**Testing:**
1. Build the project (`Cmd+R`)
2. Load a multi-layer composition
3. Scrub rapidly back and forth
4. Check diagnostics (`Cmd+Shift+D`)
5. Verify no deadlock occurs

### 4. Pull Request Guidelines

**PR Title:**
```
[FIX] Prevent admission deadlock via defer cleanup
```

**PR Description:**
- Link to the issue: `Fixes #42`
- Describe the problem clearly
- Explain your solution approach
- Include before/after diagnostic logs
- Note any trade-offs or concerns

**Review process:**
- PRs will be reviewed within 48 hours
- Feedback will be constructive and specific
- Multiple iterations are expected and welcome

---

## Not a Coder? You Can Still Help!

### Share Your VideoToolbox Knowledge
- Comment on issues with your experience
- Share links to relevant documentation
- Suggest alternative architectures

### Test & Report
- Try to reproduce issues
- Test proposed fixes
- Report edge cases

### Documentation
- Improve clarity of existing docs
- Add diagrams or flow charts
- Write tutorials for specific components

---

## Code of Conduct

### Be Respectful
- This is a learning project - mistakes are expected
- Constructive criticism only
- Assume good intent

### Be Patient
- The maintainer is learning too
- Responses may take 1-2 days
- Complex problems need time

### Be Collaborative
- Share knowledge freely
- Credit others' contributions
- Help newcomers understand the codebase

---

## Recognition

### Hall of Fame

Contributors who make significant improvements will be featured here:

| Contributor | Contribution | Impact |
|-------------|--------------|--------|
| *(Your name here!)* | Fixed admission deadlock | 🎯 Critical |
| | | |

### Credits in Code

Significant contributions will be acknowledged in the relevant source files:

```swift
// Solution contributed by @username
// See: https://github.com/lilluzifer/cinnamon-public/pull/42
```

---

## Questions?

- **General questions:** Open a GitHub Discussion
- **Bug reports:** Open an Issue with the `bug` label
- **Feature ideas:** Open an Issue with the `enhancement` label
- **Quick questions:** Comment on relevant issues

---

## Thank You!

Every contribution, no matter how small, is valuable:
- A comment with an idea
- A link to relevant documentation
- A reproduction case
- A code review
- A pull request

You're helping build something that could benefit the entire macOS video editing community. 🚀

---

**Note:** This project is a learning journey. The goal is not just to build a video editor, but to deeply understand video processing on macOS. Your contribution helps both the project and the learning process.

Thank you for being part of this journey! 🙏
