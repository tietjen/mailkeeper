#!/usr/bin/env python3 -I
"""Seed the dedicated mailcow TEST account with synthetic mail for the integration tests.

  (no argument)    "MailKeeper-Bulk": top up to 2 500 tiny messages (bulk sync test)
  --delete-test    "MailKeeper-DeleteTest": add 3 fresh messages (server-delete test)
  --cleanup-trash  remove the delete test's messages (Message-ID mk-del-*) from Trash
  --restore-test   "MailKeeper-RestoreTest": add 3 fresh messages (delete → restore test)
  --cleanup-restore remove the restore test's messages (mk-rst-*) from its folder and Trash
  --junk-test      "Junk": add 2 fresh messages (spam review: one legitimate, one spam)
  --cleanup-junk   remove the spam test's messages (mk-junk-*) from Junk and INBOX
  --inbox-spam-test  "INBOX": add 1 fresh lure (6.4 "Ist Spam → Spam-Ordner"; removed by --cleanup-junk)
  --origin-spam-test "MailKeeper-SpamOrigin": add 1 legitimate mail (6.8 "Kein Spam" back where it lay;
                   removed by --cleanup-junk)
  --fragment       "MailKeeper-Fragmented": tops up to 7 000 tiny messages, every other UID expunged
                   (fragmented-mailbox sync test; prints the folder's state on every call)

Credentials come from ~/.config/mailkeeper/test-accounts.json and the login keychain via
/usr/bin/security; nothing secret is printed. Never point this at a real mailbox — it writes.
"""
import imaplib, json, os, ssl, subprocess, sys, time

TARGET = 2500
FOLDER = "MailKeeper-Bulk"
cfg = json.load(open(os.path.expanduser("~/.config/mailkeeper/test-accounts.json")))
acc = next(a for a in cfg["accounts"] if a["id"] == "mailcow")
pw = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", acc["keychain"]["service"],
                     "-a", acc["keychain"]["account"], "-w"], capture_output=True, text=True, check=True).stdout.rstrip("\n")
m = imaplib.IMAP4_SSL(acc["host"], acc["port"], ssl_context=ssl.create_default_context())
m.login(acc["username"], pw)

if "--delete-test" in sys.argv:
    folder, stamp = "MailKeeper-DeleteTest", int(time.time())
    m.create(folder)
    for n in range(1, 4):
        msg = (f"From: delete-test@mailkeeper.test\r\nTo: inbox@mailkeeper.test\r\nSubject: Delete test {n}\r\n"
               f"Date: Thu, 14 Mar 2019 10:00:00 +0100\r\nMessage-ID: <mk-del-{stamp}-{n}@mailkeeper.test>\r\n\r\nDelete me {n}.\r\n")
        m.append(folder, None, imaplib.Time2Internaldate(time.time() - 400 * 86400), msg.encode())
    print(f"{folder}: 3 messages added (mk-del-{stamp}-*)")
    m.logout()
    sys.exit(0)

if "--restore-test" in sys.argv:
    folder, stamp = "MailKeeper-RestoreTest", int(time.time())
    m.create(folder)
    for n, flags in [(1, r"(\Seen)"), (2, r"(\Seen \Answered)"), (3, None)]:
        msg = (f"From: restore-test@mailkeeper.test\r\nTo: inbox@mailkeeper.test\r\nSubject: Restore test {n}\r\n"
               f"Date: Thu, 14 Mar 2019 10:00:00 +0100\r\nMessage-ID: <mk-rst-{stamp}-{n}@mailkeeper.test>\r\n\r\nBring me back {n}.\r\n")
        m.append(folder, flags, imaplib.Time2Internaldate(time.time() - 400 * 86400 + n * 3600), msg.encode())
    print(f"{folder}: 3 messages added (mk-rst-{stamp}-*)")
    m.logout()
    sys.exit(0)

if "--junk-test" in sys.argv:
    stamp = int(time.time())
    mails = [("billing@stadtwerke.example", "Ihre Jahresabrechnung 2025", "Anbei Ihre Jahresabrechnung. Der Betrag wird am 15. abgebucht."),
             ("win@lotto-gewinn.example", "Sie haben gewonnen!!!", "Senden Sie uns Ihre Bankdaten, um 1.000.000 EUR zu erhalten.")]
    for n, (sender, subject, text) in enumerate(mails, 1):
        msg = (f"From: {sender}\r\nTo: inbox@mailkeeper.test\r\nSubject: {subject}\r\n"
               f"Date: Thu, 14 Mar 2019 10:00:00 +0100\r\nMessage-ID: <mk-junk-{stamp}-{n}@mailkeeper.test>\r\n\r\n{text}\r\n")
        m.append("Junk", None, imaplib.Time2Internaldate(time.time()), msg.encode())
    print(f"Junk: 2 messages added (mk-junk-{stamp}-*)")
    m.logout()
    sys.exit(0)

if "--inbox-spam-test" in sys.argv:
    stamp = int(time.time())
    msg = (f"From: Sparkasse <service@sparkasse-kundenportal.example>\r\nTo: inbox@mailkeeper.test\r\n"
           f"Subject: Ihr Konto wurde eingeschraenkt\r\nDate: Thu, 14 Mar 2019 10:00:00 +0100\r\n"
           f"Message-ID: <mk-junk-{stamp}-9@mailkeeper.test>\r\n\r\nBitte bestaetigen Sie sofort Ihre Daten.\r\n")
    m.append("INBOX", None, imaplib.Time2Internaldate(time.time()), msg.encode())
    print(f"INBOX: 1 lure added (mk-junk-{stamp}-9)")
    m.logout()
    sys.exit(0)

if "--origin-spam-test" in sys.argv:
    folder, stamp = "MailKeeper-SpamOrigin", int(time.time())
    m.create(folder)
    msg = (f"From: Stadtwerke <rechnung@stadtwerke-test.example>\r\nTo: inbox@mailkeeper.test\r\n"
           f"Subject: Abschlag Oktober (Herkunftstest)\r\nDate: Thu, 14 Mar 2019 10:00:00 +0100\r\n"
           f"Message-ID: <mk-junk-{stamp}-7@mailkeeper.test>\r\n\r\nIhr Abschlag wird am 15. abgebucht.\r\n")
    m.append(folder, None, imaplib.Time2Internaldate(time.time()), msg.encode())
    print(f"{folder}: 1 mail added (mk-junk-{stamp}-7)")
    m.logout()
    sys.exit(0)

if "--cleanup-junk" in sys.argv:
    total = 0
    for folder in ["Junk", "INBOX", "MailKeeper-SpamOrigin"]:
        typ, data = m.select(folder)
        if typ != "OK":
            continue
        typ, found = m.uid("SEARCH", None, "HEADER", "Message-ID", "mk-junk-")
        uids = found[0].split()
        if uids:
            m.uid("STORE", b",".join(uids), "+FLAGS.SILENT", r"(\Deleted)")
            m.uid("EXPUNGE", b",".join(uids))  # UIDPLUS: only these
        total += len(uids)
    print(f"spam test: {total} messages removed")
    m.logout()
    sys.exit(0)

if "--cleanup-restore" in sys.argv:
    total = 0
    for folder in ["MailKeeper-RestoreTest", "Trash"]:
        typ, data = m.select(folder)
        if typ != "OK":
            continue
        typ, found = m.uid("SEARCH", None, "HEADER", "Message-ID", "mk-rst-")
        uids = found[0].split()
        if uids:
            m.uid("STORE", b",".join(uids), "+FLAGS.SILENT", r"(\Deleted)")
            m.uid("EXPUNGE", b",".join(uids))  # UIDPLUS: only these
        total += len(uids)
    print(f"restore test: {total} messages removed")
    m.logout()
    sys.exit(0)

if "--cleanup-trash" in sys.argv:
    typ, data = m.select("Trash")
    typ, found = m.uid("SEARCH", None, "HEADER", "Message-ID", "mk-del-")
    uids = found[0].split()
    if uids:
        m.uid("STORE", b",".join(uids), "+FLAGS.SILENT", r"(\Deleted)")
        m.uid("EXPUNGE", b",".join(uids))  # UIDPLUS: only these, never other \Deleted mail
    print(f"Trash: {len(uids)} delete-test messages removed")
    m.logout()
    sys.exit(0)

if "--fragment" in sys.argv:
    # Every other UID expunged: ESEARCH's ranges degrade to single UIDs and the one
    # "* ESEARCH … UID ALL" line outgrows swift-nio-imap's 8 KiB buffer (finding 2026-11-23,
    # Gmail). Only a line still incomplete beyond 8 KiB breaks — one that arrives whole in a
    # single TLS record (≤ 16 KiB) passes — so the folder aims at ~40 KiB: 7 000 runs.
    folder, runs_wanted = "MailKeeper-Fragmented", 7000
    m.create(folder)  # fails harmlessly if it exists
    typ, data = m.select(folder)
    have = int(data[0])  # earlier runs left alternating UIDs; tops up from there
    if have < runs_wanted:
        typ, st = m.status(folder, "(UIDNEXT)")
        first_new = int(st[0].decode().split("UIDNEXT")[1].strip(" )"))
        stamp = int(time.time())
        add = 2 * (runs_wanted - have)
        for n in range(1, add + 1):
            msg = (f"From: fragment@mailkeeper.test\r\nTo: inbox@mailkeeper.test\r\nSubject: Fragment {n}\r\n"
                   f"Date: Thu, 14 Mar 2019 10:00:00 +0100\r\nMessage-ID: <mk-frag-{stamp}-{n}@mailkeeper.test>\r\n\r\n"
                   f"Synthetic message {n}.\r\n")
            m.append(folder, None, imaplib.Time2Internaldate(time.time()), msg.encode())
            if n % 1000 == 0:
                print(f"  {n}/{add}")
        m.select(folder)
        typ, found = m.uid("SEARCH", None, "UID", f"{first_new}:*")
        new = sorted((u for u in found[0].split() if int(u) >= first_new), key=int)
        drop = new[1::2]  # keep the 1st, 3rd, …: no two new UIDs stay adjacent
        for i in range(0, len(drop), 500):
            chunk = b",".join(drop[i:i + 500])
            m.uid("STORE", chunk, "+FLAGS.SILENT", r"(\Deleted)")
            m.uid("EXPUNGE", chunk)  # UIDPLUS: only these
    typ, data = m.select(folder)
    typ, found = m.uid("SEARCH", None, "ALL")
    uids = sorted(int(u) for u in found[0].split())
    runs = sum(1 for i, u in enumerate(uids) if i == 0 or u != uids[i - 1] + 1)
    print(f"{folder}: {int(data[0])} messages in {runs} runs of UIDs")
    m.logout()
    sys.exit(0)

m.create(FOLDER)  # fails harmlessly if it exists
typ, data = m.select(FOLDER)
have = int(data[0])
print(f"{FOLDER}: {have} messages, target {TARGET}")
for n in range(have + 1, TARGET + 1):
    msg = (f"From: bulk@mailkeeper.test\r\nTo: inbox@mailkeeper.test\r\nSubject: Bulk {n}\r\n"
           f"Date: Thu, 14 Mar 2019 10:00:00 +0100\r\nMessage-ID: <mk-bulk-{n}@mailkeeper.test>\r\n\r\nSynthetic message {n}.\r\n")
    m.append(FOLDER, None, imaplib.Time2Internaldate(time.time()), msg.encode())
    if n % 250 == 0:
        print(f"  {n}")
m.logout()
print("done")
