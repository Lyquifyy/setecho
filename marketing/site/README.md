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

The production source repository is https://github.com/Lyquifyy/setecho-site, owned by Lyquifyy. Its dedicated local checkout is `../github-site/` (ignored in the app repository).

The public website is https://getsetecho.com, with Cloudflare Pages deploying automatically from GitHub `main`. The site repo contains only the landing page, its assets, package scripts and documentation. App source, local design references, athlete data and secrets are excluded. The source repo is private; the website is public.

Cloudflare Pages configuration: build command `npm run check`, output `dist`, production branch `main`. The site repo is the source of truth for future website edits. This directory retains the launch snapshot and canonical-brand sync script.

Verified October 29, 2026: Cloudflare Pages project `setecho-site` deployed commit `9376d9e0f4defa8aae50118da5e8f69f8bc42330` from `Lyquifyy/setecho-site`. Its GitHub installation is scoped to that repository. The proxied apex CNAME targets `setecho-site.pages.dev`. The custom domain returns HTTP 200 over verified HTTPS, the page renders in the browser, and all 13 published files match the source byte-for-byte.

The earlier ChatGPT Sites review remains private and is not the production host. Its pending getsetecho.com registration was removed when the owner chose GitHub + Cloudflare. No Sites validation DNS records need to be added.
