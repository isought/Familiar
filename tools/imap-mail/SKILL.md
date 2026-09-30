---
name: Mail over IMAP
description: Reads your mailbox over IMAP (Gmail, iCloud, Yahoo, Fastmail and others) with an app password. Read-only: it never marks anything read, moves or deletes.
requires: [MAIL_ADDRESS, MAIL_APP_PASSWORD]
sources: [today]
---
`imap-mail__today` lists what arrived in the inbox recently (the last 24 hours by default), newest first: sender, subject,
time, whether it's read, a short preview, and for Gmail the tab it landed in (Primary, Promotions, Social, Updates,
Forums) and Gmail's Important marker. It can also feed a saved job, so the morning pack reads mail without a browser.

It needs two secrets in Noteling Settings (right-click the bubble → Settings…):
- MAIL_ADDRESS: the email address.
- MAIL_APP_PASSWORD: an app password, not the normal password. Gmail: myaccount.google.com/apppasswords (needs
  2-Step Verification). iCloud: account.apple.com → App-Specific Passwords.

If it returns an error, repeat it in plain words and stop. Never ask anyone to type a password into the chat.
