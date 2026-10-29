# SetechoShare (WhatsApp → Share → Setecho)

The share extension hands the coach's text or voice note to the app through the app group
`group.com.getsetecho.app`. The group was registered on the team's App IDs in Xcode on Oct 29
(Signing & Capabilities → App Groups, on both targets), and the extension is embedded in the app.
On a new team or machine, repeat that step in Xcode first: automatic signing from the command line
cannot register an App Group.

Replies can also come in through More → Add coach reply (paste, or pick the voice note as a file).
