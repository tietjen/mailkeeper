# ADR-0010: Spam and phishing — separate signals, the user decides

- Status: accepted (TJ, 2026-10-12) — §1–5 built in Phase 5.5/5.6; §6 in Phase 6, §7 later
- Deciders: TJ

## Context

Providers file legitimate mail as spam and let phishing through. TJ (2026-10-11): let the model
look at spam folders now and then, make "not spam" a one-click fix that also moves the mail on
the server, examine links, and judge **phishing separately from spam** — a spam newsletter is no
phishing, a fake invoice can be both. Earlier idea (Phase 6): a register of real relationships
(banks, partners, shops) as a prior, and the public bait address `kontakt@paranoidsecurity.de`
as context for unsolicited first contacts.

## Decision

1. **Three separate things per mail:** the *category* (rules or model; `spam` is one of nine),
   the *phishing level* (`nein` / `verdacht` / `ja`, model only, with its concrete signs) and the
   *user's verdict* (`spam` / `ham`). The UI shows them apart; `is:phishing`, `kategorie:spam`
   and the spam review filter on them separately.
2. **Deterministic link checks** (`LinkCheck`, linear scanner, no network): text naming another
   domain than the target, bare IP, punycode, shorteners, unusual schemes, user info before the
   host. Shown on hover and in the reader; given to the model as findings. **Never a verdict on
   their own** — newsletters route clicks through tracking domains.
3. **Signals for the model** (fenced, ADR-0004): sender, Reply-To on a foreign domain, the
   topmost `Authentication-Results` (dkim/spf/dmarc — added by the own server; lower ones can be
   forged), link findings and target domains, headers and a bounded excerpt. Instructions in the
   mail are themselves a warning sign.
4. **Spam folders are read only when the account says so** (`includeJunk`; never the trash; an
   include list still rules). The model checks new mail there after each sync (quietly, small
   batches) and on request.
5. **The user decides, and it sticks:** "Ist Spam" / "Kein Spam" are journalled (`classified`)
   and survive a rebuild; no rule or model overrides them. "Kein Spam → Posteingang" moves the
   mail on the server (ADR-0006 §8) — one click for one mail, the plan sheet for several.
6. **Phase 6 — relationship register:** entities (a bank, a school, a shop) with the
   authenticated sender domains they actually used and the start/end of the relationship,
   suggested from history (replies in Sent, "Kein Spam", DMARC-pass transactional mail),
   confirmed by the user. A prior that may *lower* caution only with positive evidence; a mail
   that names a known entity but comes from another domain *raises* it. Derived items never
   become rules on their own (ADR-0005). First contact at the bait address is unsolicited, not
   spam; personal details found online are no proof of legitimacy.
   *As built (6.3, 2026-10-12):* schema v12 indexes the topmost `Authentication-Results`
   (authserv-id, dkim, spf, dmarc, `header.from`) and `Delivered-To` — at ingest, for older mail by
   a background pass over the headers only (42k in under five minutes). The own servers per account
   are learned — several, a mailbox may move (TJ: 27,030 mails from one server, then 7,093 from
   another): one that stamped at least half of *all* the account's incoming mail, in the last year
   or ever (≥ 20), or a fifth (≥ 5) when its host shares the account's registrable IMAP domain
   (Gmail: mx.google.com for imap.gmail.com); one that is own in another account counts where it
   checked a quarter (≥ 5). Review 6 B1: counting only mails that carry the header let five forged
   headers make a sender "own" on a provider that adds none; in the second pass the host alone let
   one forged header naming the provider's public MX do it — the host is a tie-breaker, never a
   free pass. What remains: a dormant account with few mails can be outnumbered (≥ 20 forged).
   The authserv-id must be a domain name.
   Results from any other server count for nothing ("foreign"). Relations are memory items of kind `relation` (name, registrable
   domains, since, until), journalled; a rejected suggestion is stored inactive with
   `rejected` so it is not suggested again, a forgotten one may come back (review 6 S3 — journals
   from before that fix have no flag: their rejected suggestions count as forgotten after a
   rebuild, once). Suggestions need positive evidence (mails the user wrote to the domain, the
   user's "kein Spam" or category, ≥ 2 authenticated transactional mails), never freemail or the
   user's own domains, never where spam and phishing outweigh; named after the domain unless one
   non-generic sender name stands for most of its mails and is not the user's own; one name with
   several domains is one suggestion. Per mail a deterministic check: known relation (with the own
   server's verdict), look-alike (the sender name or domain label carries a relation's name or
   domain words — never single words of a person's name — from another domain), failed check of
   the own server, first contact at a public address (notes with subject `public:<address>`; no
   mail before, never written to). The reader shows it as "Echtheit" (with "… gehört doch dazu"
   for a look-alike the user knows), the model gets it outside the fence and sees only the own
   server's results. Settings › Beziehungen.
   *As built (6.4):* the inbox is screened after every sync: new mail of the last 14 days outside
   spam, sent and trash that no model and no user judged. Deterministic first — the register's
   warning (look-alike, failed check of the own server) is stored (`warning`) so "Verdächtig"
   shows it without a model — then the model only where it matters: a warning, a first contact at
   a public address, mail the rules left open, invoices/orders/notifications/account mail that do
   not come from a confirmed relation with a passing check (≤ 30 per sync, quietly; together with
   the spam-folder check). `is:verdächtig` = phishing or spam by a model, or a stored warning,
   unless the user said "kein Spam" or gave another category; sidebar "Verdächtig" with
   "Posteingang prüfen" (14 / 90 / 365 days) for older mail. "Ist Spam → Spam-Ordner" per
   ADR-0006 §9. *"Einschätzung korrigieren" (6.4b, TJ):* the user calls a flagged mail genuine
   (journalled "kein Spam"), may add a relation as the firm rule and a note for the sender's
   domain, and have this mail and the other model-flagged mails of these domains judged again.
   A Reply-To inside the same confirmed relation is no warning sign any more (paypal.de → paypal.com).
   *Unsubscribe (6.5c, TJ):* "Vom Newsletter abmelden" in the reader and the cleanup group, checked
   first and again at the click: locked (with the reasons) when a model holds the mail for
   phishing, the register sees a look-alike or the own server's check failed, the mail is spam (a
   user or model verdict, or in a spam folder without "kein Spam" — unsubscribing only confirms
   the address), or the List-Unsubscribe link has findings. One click (RFC 8058: one POST, no
   cookies, no redirects — a redirect opens the page instead) only when the own server's dkim and
   dmarc passed; else the page opens in the browser or a mail is prepared. Logged in the audit
   (`unsubscribe`) and remembered as a note for the list or sender (further newsletters are
   unwanted). The model sees the unsubscribe target with its findings.
   *Review 6.5c (Fable):* a replayed signed newsletter with List-Unsubscribe put on top passes
   DKIM and DMARC — a verifier checks the bottom-most instance (RFC 6376 §5.4.2). So: the last
   instance is taken, more than one locks the button, and one click also needs a `DKIM-Signature`
   of the From domain (relaxed) whose `h=` lists List-Unsubscribe and List-Unsubscribe-Post as
   often as they occur (RFC 8058 §4; which signature passed is not known, what it covers is).
   https targets must be ordinary public names (no numbers in disguise, `%`, single labels, local
   suffixes, the user's own domains) and resolve to public addresses right before the request or
   the browser opens (DNS rebinding in between stays out of reach); `mailto:` is rebuilt from one
   address and the subject. The click re-checks and must find what the user confirmed; the note
   is written once and a failure to write it is said; the audit names how and the domain only.
7. **Later — report phishing:** forward a mail as a complete `.eml` attachment to an address the
   user configures (e.g. `phishing@verbraucherzentrale.nrw`). Needs a sending path (SMTP, not in
   MailKeeper yet); always explicit, per mail, logged.

## Consequences

- A model mistake costs a wrong label, never a lost mail: nothing is deleted on a verdict, and
  moving to INBOX is the user's click.
- Accuracy is measured on the gold set (ADR-0005 §7) including phishing probes; live checks so
  far: S3 injection probes not followed, fake bank → phishing, newsletter with tracking links and
  a real invoice → no phishing.
