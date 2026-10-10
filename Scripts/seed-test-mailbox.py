#!/usr/bin/env python3 -I
"""Seed the dedicated mailcow TEST account with synthetic mail for the bulk integration test.

Creates the folder "MailKeeper-Bulk" with 2 500 tiny synthetic messages (idempotent: tops up
to the target count). Credentials come from ~/.config/mailkeeper/test-accounts.json and the
login keychain via /usr/bin/security; nothing secret is printed. Never point this at a real
mailbox — it writes.
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
