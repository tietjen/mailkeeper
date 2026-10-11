#!/usr/bin/env python3 -I
"""Seed the dedicated mailcow TEST account with synthetic mail for the integration tests.

  (no argument)    "MailKeeper-Bulk": top up to 2 500 tiny messages (bulk sync test)
  --delete-test    "MailKeeper-DeleteTest": add 3 fresh messages (server-delete test)
  --cleanup-trash  remove the delete test's messages (Message-ID mk-del-*) from Trash
  --restore-test   "MailKeeper-RestoreTest": add 3 fresh messages (delete → restore test)
  --cleanup-restore remove the restore test's messages (mk-rst-*) from its folder and Trash

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
