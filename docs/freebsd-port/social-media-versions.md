# Social Media Versions

## LinkedIn Post (Long Form)

---

**Is io_uring a security liability we're all ignoring?**

60% of Google's 2022 kernel exploit bounties targeted io_uring.

Docker disabled it by default. Android disabled it. ChromeOS disabled it. Google's own servers disabled it.

Yet almost every modern high-performance database is building on io_uring as their *only* fast I/O path. TigerBeetle, parts of ScyllaDB, and many others have deep io_uring dependencies.

What happens when your security team says "no io_uring"? You fall back to synchronous I/O. Performance tanks.

**There's an alternative that nobody talks about.**

FreeBSD AIO + kqueue provides the same completion-based async I/O model — truly non-blocking, not thread-pool simulation — with 25 years of security hardening instead of 5 years of CVEs.

This isn't theoretical:
• PostgreSQL 18 is implementing a `posix_aio` backend (same architecture)
• Netflix serves 30% of US internet traffic on FreeBSD
• WhatsApp handled 2M concurrent connections per server on FreeBSD
• ZFS 2.3.0 (Jan 2025) added O_DIRECT support, closing the last performance gap

I've been exploring this architecture for a TigerBeetle database port. The deep-dive revealed something surprising: the technical foundation is solid, validated by PostgreSQL's core team, and production-proven at massive scale.

The question isn't "Linux vs BSD." It's: what do you do when io_uring is blocked by policy?

Full technical analysis: [LINK]

Curious what database engineers and security folks think. Is this a real concern in your environment? Have you had to disable io_uring?

#databases #security #freebsd #linux #systemsprogramming #postgresql

---

## LinkedIn Post (Medium Length)

---

**60% of Google's 2022 kernel exploits targeted one subsystem: io_uring.**

Docker disabled it. Android disabled it. Google's own servers disabled it.

Yet most modern databases depend on io_uring for performance. When security teams block it, you're stuck with slow synchronous I/O.

There's an alternative: FreeBSD AIO + kqueue + ZFS.

Same async I/O model. 25 years of hardening vs 5 years of CVEs. PostgreSQL 18 is implementing this exact architecture. Netflix and WhatsApp run on it at scale.

With ZFS 2.3's new O_DIRECT support (Jan 2025), the last performance gap is closed.

Full technical deep-dive: [LINK]

Is io_uring a concern in your environment?

#databases #security #postgresql #freebsd

---

## Twitter/X Thread

---

**Tweet 1:**
60% of Google's 2022 kernel exploit bounties targeted io_uring.

Docker disabled it. Android disabled it. Google servers disabled it.

Yet almost every modern database depends on it for performance.

What's the alternative? 🧵

**Tweet 2:**
FreeBSD AIO + kqueue provides the same async I/O model:
- Completion-based (not thread pool)
- Truly non-blocking
- 25 years of hardening vs 5 years of CVEs

This isn't theoretical — PostgreSQL 18 is implementing it right now.

**Tweet 3:**
The old objection: "ZFS doesn't support O_DIRECT"

ZFS 2.3.0 (Jan 2025): O_DIRECT support added ✓

Now you get:
- Async I/O (no io_uring)
- Guaranteed durability
- Checksums
- Snapshots
- Smaller attack surface

**Tweet 4:**
Who uses FreeBSD in production?

• Netflix (30% of US internet traffic)
• WhatsApp (2M connections/server)
• PlayStation (PS3, PS4, PS5)
• Juniper Networks

"Nobody uses BSD" is a myth.

**Tweet 5:**
The question isn't Linux vs BSD.

It's: what do you do when io_uring is blocked by security policy?

Full analysis: [LINK]

---

## Hacker News Title + Comment

---

**Title:**
Beyond io_uring: FreeBSD AIO as a Secure Alternative for Database I/O

**Opening Comment:**
I've been exploring porting TigerBeetle (financial transactions database) from Linux io_uring to FreeBSD. The deep-dive revealed that:

1. FreeBSD AIO + kqueue provides equivalent async I/O (completion model, not thread pool)

2. PostgreSQL 18 is implementing the same architecture (posix_aio backend, Thomas Munro's work)

3. ZFS 2.3.0 (Jan 2025) adds O_DIRECT support, closing the performance gap

4. The security surface is dramatically smaller than io_uring

The irony: io_uring was created to solve real problems, but its attack surface led to it being disabled in Docker, Android, ChromeOS, and Google's servers. For security-conscious deployments, there's no fallback except slow synchronous I/O.

This documents an alternative path. Feedback from anyone who's dealt with io_uring security restrictions would be valuable.

---

## Reddit (r/programming, r/BSD, r/PostgreSQL)

---

**Title:**
FreeBSD AIO + ZFS 2.3: A secure alternative to io_uring for database I/O

**Body:**
Been researching async I/O alternatives after learning that io_uring accounts for 60% of Google's kernel exploit bounties and is disabled by default in Docker, Android, and ChromeOS.

Key findings:

- FreeBSD AIO provides true async I/O (completion model, same as io_uring)
- PostgreSQL 18 is implementing `posix_aio` backend for FreeBSD
- ZFS 2.3.0 (released Jan 2025) finally supports O_DIRECT
- 25 years of AIO hardening vs 5 years of io_uring CVEs

The full write-up covers the architecture, security comparison, PostgreSQL's work, and practical implementation.

Curious if anyone has had to deal with io_uring being blocked in their environment, and what alternatives you found.

[LINK]

---

## One-Liner for Quick Shares

---

"io_uring: 60% of Google's 2022 kernel exploits. Disabled in Docker, Android, ChromeOS. FreeBSD AIO + ZFS 2.3 offers the same async I/O model with 25 years of hardening. PostgreSQL 18 is already implementing it."

---

## Key Stats to Remember

For comments and discussions, these are the memorable points:

1. **60%** — Google's kernel exploit bounties targeting io_uring (2022)
2. **25 years** — FreeBSD AIO age vs **5 years** for io_uring
3. **30%** — US internet traffic served by Netflix on FreeBSD
4. **2 million** — Concurrent connections per server at WhatsApp (FreeBSD)
5. **January 2025** — ZFS 2.3.0 adds O_DIRECT support
6. **PostgreSQL 18** — Implementing posix_aio backend now
