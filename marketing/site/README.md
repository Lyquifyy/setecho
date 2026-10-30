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

The approved public target is https://getsetecho.com, with Cloudflare Pages deploying from GitHub `main`. The site repo contains only the landing page, its assets, package scripts and documentation. App source, local design references, athlete data and secrets are excluded. The source repo is private; the website is intended to be public.

Cloudflare Pages configuration: build command `npm run check`, output `dist`, production branch `main`. The site repo is the source of truth for future website edits. This directory retains the launch snapshot and canonical-brand sync script.

Setup status: source pushed to `Lyquifyy/setecho-site`; Cloudflare's GitHub installation is scoped to that repository and approved by the owner. GitHub requires owner reauthentication before installation can complete. Deployment and custom-domain DNS are still pending.

The earlier ChatGPT Sites review remains private and is not the production host. Its pending getsetecho.com registration was removed when the owner chose GitHub + Cloudflare. No Sites validation DNS records need to be added.
