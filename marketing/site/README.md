# Setecho landing page

Static HTML/CSS/JavaScript in `dist/`. No dependencies, forms, analytics, live backend calls or user data collection.

```sh
npm run sync-brand
npm run check
npm run preview
```

The walkthrough uses fixed synthetic examples. Clicking Plan update before approving routes to the proposal. Only the explicit approval button advances to applied. Reset clears that demo approval. Every step is keyboard-accessible; animations respect Reduce Motion.

`dist/assets/screen-*.png` are unaltered SwiftUI renders of the actual app using `ScreenFixtures`, captured by `ScreenRenderTests` on iPhone 17 Pro simulator. `bench-phone.png` is generated lifestyle imagery, disclosed on the page. Device frames are CSS, preserving the screenshot pixels. The watch exploration and generated device mockup are not published on this page.

## Hosting

Private review deployed successfully:
https://setecho-prep.zander-erwin.chatgpt.site

Site identity is tracked in `.openai/hosting.json`. The source-only deployment checkout is `/tmp/setecho-site-publish`; it contains only this directory, never the app repository or local design materials. Use the Sites source workflow with a fresh credential for subsequent publication. Credentials are not saved here.

## getsetecho.com

Custom domain registered with Sites; pending DNS validation. Cloudflare is signed out in the available browser and CLI. Add these records after authenticating, inspecting existing records before changing them:

| Type | Name | Content |
| --- | --- | --- |
| A | `@` | `162.159.143.30` |
| A | `@` | `172.66.3.26` |
| TXT | `_openai-site-verification` | `openai-site-verification=MHIVggOHvV5Eqsl1R8Xf1jd6-689lhYA-WSlnp1X5jY` |
| TXT | `_cf-custom-hostname` | `1fa8e2fe-1af9-49c2-b35d-a45066a5bfd4` |

Use DNS-only records for the routing entries unless the hosting provider specifies otherwise. Do not change mail records. Refresh custom-domain status through Sites after propagation. Public Site access still requires the owner's choice; the current preview is private. Once the custom domain is verified, update `og:url` and `og:image` in `dist/index.html` to `https://getsetecho.com/` and republish. Until then they correctly name the working review origin.
