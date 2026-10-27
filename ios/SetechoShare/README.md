# SetechoShare (WhatsApp → Share → Setecho)

The share extension hands the coach's text or voice note to the app through the app group
`group.com.getsetecho.app`. Automatic signing from the command line cannot register an App Group,
so the extension is built but **not embedded** until this one-time step is done in Xcode:

1. `make ios`, select the **Setecho** target → Signing & Capabilities → **+ Capability** → App Groups →
   add `group.com.getsetecho.app`. Do the same for the **SetechoShare** target.
2. Put the group back into `Config/Setecho.entitlements` and uncomment the `SetechoShare` dependency
   in `project.yml`, then `make testflight`.

Until then replies come in through More → Add coach reply (paste, or pick the voice note as a file).
