# Viewer Modernization Plan (Remove `<frameset>`)

**Status**: Proposal + starter implementation guidance  
**Goal**: Replace the 1990s `<frameset>` + frames + jQuery keyboard hacks with a modern, accessible, mobile-friendly, maintainable viewer while preserving (and improving) the core "commentary + source side-by-side" experience that makes Lions Book special.

---

## 1. Why the current viewer is problematic

- `<frameset>` / `<frame>` is deprecated, removed from the HTML Living Standard for new content.
- Extremely poor accessibility (screen readers, keyboard navigation between panes is broken or confusing).
- No responsive design — unusable on phones/tablets, bad on narrow windows.
- History, deep linking, printing, and SEO are painful.
- The two "panes" cannot be bookmarked independently easily.
- `alert()` on every load + debug code.
- All interactivity is global key handlers that only work when the container has focus.
- The generated plastex HTML (left) and `all.html` (right) have their own scroll, TOC, etc. — the frame boundary fights the user.

We can do **much** better with 2025-era CSS + a little vanilla JS (or one tiny dependency).

---

## 2. Goals for the new viewer

| Goal                        | Current (frames)          | Target (modern)                          |
|----------------------------|---------------------------|------------------------------------------|
| Layout                     | Fixed cols/rows frameset  | Resizable split panes (CSS Grid + JS)    |
| Mobile / narrow screens    | Broken                    | Collapsible panes or stacked + toggle    |
| Accessibility              | Very poor                 | Proper landmarks, ARIA, focus management |
| Deep linking               | Fragile (two frames)      | One URL can encode `?sect=0010&line=2184`|
| Print / PDF export         | Terrible                  | Reasonable single-column or "print both" |
| Keyboard                   | Global alerts + keys      | Standard + documented shortcuts          |
| Theming                    | Plastex theme only        | Optional light/dark + respect prefers    |
| Performance                | Multiple full documents   | Optional: prefetch, virtual scroll source|
| Maintainability            | 90s tech + custom JS      | Small, documented, testable vanilla/TS   |
| Plastex compatibility      | Assumes old structure     | Works with current plastex output        |

Non-goals (for v1):
- Re-implementing the entire plastex-generated commentary as a SPA.
- Full-text search across the book (can be a follow-up).

---

## 3. Recommended Architecture (Pragmatic)

### Option A — Recommended for this project (Iframes + Split)

Use a **single controlling HTML page** (`viewer.html` or replace `lions.html`):

```
+--------------------------------------------------+
|  Top bar: Logo / Title / [TOC] [Source] [Both]   |
|  [Theme] [Help] [Open in new tab]                |
+--------------------------------------------------+
|  Commentary (left)          |  Source (right)     |
|  <iframe src="lionc/sect...">|  <iframe or div>   |
|                             |                     |
+--------------------------------------------------+
          (resizer handle in the middle)
```

**Why iframes are acceptable here**:
- The left pane is a whole generated mini-site (with its own TOC, next/prev, MathJax, internal links).
- The right pane can be a specialized source viewer that understands `#line2184` and has good line highlighting + "back to commentary" affordances.
- Iframes give us isolation (styles, scripts from plastex don't fight the host page).
- We can still do cross-frame communication via `postMessage` or by controlling the `src` + hash of the iframes.

**Resizable panes**:
- Use CSS `grid-template-columns: 1fr 8px 1fr` (or `minmax()`).
- A thin `<div id="resizer">` with `cursor: col-resize`.
- ~30 lines of vanilla JS to drag the splitter and persist size in `localStorage`.

**Source pane options** (pick one or both):
1. `<iframe src="all.html#line2184">` — simplest. Enhance `all.html` or wrap it so the flash works reliably.
2. A custom enhanced source viewer (recommended long-term):
   - Load `all.html` once, parse the `<pre>` lines into a virtual list or just a big scrollable container with `id="line2184"` on each line wrapper.
   - This gives us full control: sticky line numbers, "highlight range", "show 10 lines of context", search within file, etc.

### Option B — No iframes (more ambitious)

Fetch the commentary HTML via `fetch()`, inject into a `<main id="commentary">`, rewrite internal links to use the controller's router.
Do the same (or better) for the source.

**Pros**: one document, perfect history/URL control, easier print.
**Cons**: more work (link rewriting, scroll sync, MathJax re-init, style isolation via Shadow DOM or careful CSS).

For a first modern version **Option A is strongly recommended**. It can be done in an afternoon and already feels 10x better than frames.

---

## 4. URL & State Design (important)

Proposed URL format (hash or query):

```
/viewer.html?sect=sect0010&line=2184
/viewer.html#sect0010:2184
```

- On load, open the correct commentary file in the left iframe.
- Scroll + flash the correct line(s) in the right pane.
- When user clicks a `.line-ref` inside the commentary iframe, the host page listens (via `postMessage` or by the iframe navigating and the host polling the child location) and updates the source pane + the URL.
- "Open commentary in new tab" and "Open source in new tab" buttons are trivial.

This gives shareable links that actually work.

---

## 5. Step-by-step Migration Plan

### Phase 0 — Foundations (this PR / current work)
- [x] `.gitignore` + stop committing `lionc/`
- [x] Robust Python post-processor (`scripts/fix-line-refs.py`)
- [x] Updated `Makefile`
- Add basic `.line-ref` styling (done via the script)
- Document current keyboard shortcuts somewhere visible

### Phase 1 — New container page (1–2 days)
1. Create `viewer.html` (or `modern-lions.html` as a parallel experiment).
2. Implement CSS Grid two-pane layout + resizer (vanilla, < 50 LOC).
3. Left pane: `<iframe name="commentary" src="lionc/index.html">`
4. Right pane: `<iframe name="source" src="all.html">`
5. Top bar with:
   - Current section title (read from iframe `document.title` or `postMessage`)
   - Toggle "50/50", "Focus left", "Focus right", "Vertical / Horizontal" (rows)
   - "Reset split"
6. Persist split ratio + orientation in localStorage.
7. Remove (or hide behind a banner) the old `lions.html` alert().

### Phase 2 — Cross-pane communication & line highlighting (1–2 days)
1. Improve (or replace) `all.js`:
   - Export a small API or listen to `hashchange` + support `id=` in addition to `name=`.
   - Add `window.highlightLine(n, {flash: true, scroll: 'center'})`.
2. In the controller (`viewer.html`):
   - When left iframe loads, inject (or the commentary already has) click handlers on `.line-ref` that do:
     ```js
     parent.postMessage({type: 'goto-line', line: 2184, sect: 'sect0010'}, '*');
     ```
   - Host page receives the message and does `sourceIframe.contentWindow.postMessage(...)` or directly manipulates the source iframe location + calls a function if same-origin.
3. Make "back" navigation from source pane possible (a small "show in commentary" UI).

### Phase 3 — Polish & Accessibility
- ARIA: `role="main"`, `aria-label` on panes, live region for "jumped to line 2184".
- Keyboard: `?` shows help overlay with all shortcuts.
- Mobile: media query that stacks the panes vertically + a tab-like switcher ("Commentary / Source").
- Print stylesheet that outputs commentary followed by relevant source excerpts (harder) or just warns the user.
- Dark mode toggle (plastex white theme + custom CSS vars or a second theme).
- Loading indicators while iframes are navigating.

### Phase 4 — Optional but high value
- Replace right iframe with a custom source viewer component (better highlighting, range support, "used by / calls" mini-index if we parse more).
- Client-side search (fuse.js or a simple index of the book + source).
- Remember last position per user (localStorage).
- Generate a single-file offline version (for the truly dedicated).

---

## 6. Starter Files (what you can commit now)

- `viewer.html` — the new controller (start with a working grid + two iframes + resizer + a couple of buttons).
- `assets/viewer.css` (or inline in the html for v0.1)
- `assets/viewer.js` (small, well-commented)
- Update `index.html` to point to the new viewer (or keep the old one as `classic.html` for a while).
- Update README with "Try the modern viewer" callout.

A minimal working `viewer.html` prototype (iframe version) can be written in < 150 lines of HTML+CSS+JS and already feels dramatically better than the frameset.

---

## 7. Risks & Mitigations

- **Plastex output changes structure on upgrade** → The Python post-processor + the `.line-ref` class give us a stable hook. Document the contract ("any `<dt><a class="line-ref" data-line="...">` will be turned into a goto-line action").
- **MathJax / TOC scripts inside iframe** → They stay inside their iframe; no problem.
- **Users have bookmarks to the old `lions.html`** → Keep `lions.html` working (or redirect) for a few releases, or show a banner "This is the classic frames viewer — try the new one".
- **Polish version (`pol/`)** → The same viewer works for it; just change the base `src` of the commentary iframe.

---

## 8. Quick Start Sketch (for the implementer)

```html
<!-- viewer.html (very rough) -->
<div class="app">
  <header>...</header>
  <div class="split" style="grid-template-columns: 1fr 8px 1fr">
    <iframe id="commentary" src="lionc/sect0010.html"></iframe>
    <div id="resizer"></div>
    <iframe id="source" src="all.html#line2184"></iframe>
  </div>
</div>
```

```css
.split { display: grid; height: calc(100vh - 48px); }
#resizer { background: #ddd; cursor: col-resize; }
```

A few dozen lines of JS for dragging + message passing and you're 80% there.

---

## 9. Success Metrics

- Old `lions.html` can be removed or clearly marked "legacy".
- New viewer works in Chrome, Firefox, Safari, Edge.
- Works reasonably on a 360px phone (stacked mode).
- A link like `?sect=sect0010&line=2184` opens the right content and highlights the line.
- No more `alert()` on load.
- Screen reader users can at least read one pane at a time meaningfully.

---

**Next action after this plan is accepted**: implement Phase 1 (the container + resizer) as a parallel file, keep the old experience untouched until the new one is clearly better.

This modernization is one of the highest-leverage things the project can do for usability in 2026+.
