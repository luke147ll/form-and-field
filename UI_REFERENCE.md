# Takeoff Dashboard v6 — UI Reference

> **Source file:** `extension/takeoff_v6.5/takeoff_tool/ui/dashboard.html` (689 lines)
> **Backend:** `extension/takeoff_v6.5/takeoff_tool/dashboard.rb` (443 lines)
> **Theme:** Catppuccin Mocha dark theme

---

## Page Layout (top to bottom)

```
┌─────────────────────────────────────────────────────────────────────┐
│ HEADER (div.header)                                        L:142   │
├─────────────────────────────────────────────────────────────────────┤
│ SUMMARY STRIP (div.summary #sstrip)                        L:162   │
├─────────────────────────────────────────────────────────────────────┤
│ MULTI-ISOLATE PANEL (#catPanel) — hidden by default        L:165   │
├─────────────────────────────────────────────────────────────────────┤
│ BULK EDIT BAR (div.bulk #bulkBar) — hidden by default      L:178   │
├─────────────────────────────────────────────────────────────────────┤
│ FILTER BAR (div.fbar)                                      L:190   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│ MAIN CONTENT AREA (div.tp #dp) — scrollable                L:206   │
│   ┌── Category Group (div.cg)                                      │
│   │   ├── Group Header (div.cgh)                                   │
│   │   └── Group Body (div.cgb) — shown when .cg.open              │
│   │       ├── Toolbar (div.cg-toolbar)                             │
│   │       └── Table (table > thead + tbody)                        │
│   ├── Category Group ...                                           │
│   └── Category Group ...                                           │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│ DEBUG PANEL (#dbg) — hidden by default                     L:207   │
├─────────────────────────────────────────────────────────────────────┤
│ SCAN OVERLAY (#scanOverlay) — fixed centered, hidden       L:210   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 1. HEADER — `div.header` (L:142–159)

```
HEADER (div.header)
├── Title (h1) — "TAKEOFF v6"
├── div.sep
├── "Highlight All" (button.hb.pri) → call('highlightAll')
├── "Clear" (button.hb) → call('clearHighlights')
├── "Show All" (button.hb) → call('showAll'); resetVis()
├── "Multi-Isolate" (button.hb.grn) → toggleCatPanel()
├── div.sep
├── "CSV" (button.hb) → call('exportCSV')
├── "Report" (button.hb.pri) → call('exportHTML')
├── "Rescan" (button.hb) → call('rescan')
├── div.sep
├── LF Tool (button.hb.yel) → call('activateLF')        [SVG: ICO_LF inline]
├── SF Tool (button.hb.yel) → call('activateSF')         [SVG: ICO_SF inline]
├── div.sep
├── "+" Expand All (button.hb) → expandAll()
├── "−" Collapse All (button.hb) → collapseAll()
└── "dbg" (button.hb) → toggleDebug()
```

**CSS classes:**
| Class | Purpose |
|-------|---------|
| `.header` | Flex container, `background:#181825`, wraps |
| `.header h1` | Title, `color:#cba6f7` (purple) |
| `.hb` | Header button base, `background:#313244` |
| `.hb.pri` | Primary purple button, `background:#cba6f7` |
| `.hb.grn` | Green button, `background:#a6e3a1` |
| `.hb.yel` | Yellow button, `background:#f9e2af` |
| `.sep` | 1px vertical divider line |

---

## 2. SUMMARY STRIP — `div.summary #sstrip` (L:162)

```
SUMMARY STRIP (div.summary #sstrip)
├── Item Count (div.sb) — "X items"
├── Category Count (div.sb) — "X categories"
└── Uncategorized Count (div.sb) — "X uncat" (red, only if > 0)
```

Populated by `strip()` function (L:385). Uses `div.sb` with `b` (blue numbers) and `.e` (red error text).

---

## 3. MULTI-ISOLATE PANEL — `#catPanel` (L:165–175)

```
MULTI-ISOLATE PANEL (#catPanel)  — toggle: class "show"
├── Category Checkboxes (#catChecks)
│   └── label.cpRow × N
│       ├── input[checkbox].cpCk — value = category name
│       └── Category Badge (span.cb.c-{CatName}) — colored badge + count
└── Button Row (div.cpBtn)
    ├── "Isolate" (button.hb.grn) → doMultiIsolate()
    ├── "Hide" (button.hb) → doMultiHide()              [red text]
    ├── "Highlight" (button.hb.pri) → doMultiHighlight()
    ├── "All" (button.hb) → cpAll(true)
    ├── "None" (button.hb) → cpAll(false)
    └── "Close" (button.hb) → toggleCatPanel()
```

Built by `buildCatPanel()` (L:320). Max height 180px, scrolls.

---

## 4. BULK EDIT BAR — `div.bulk #bulkBar` (L:178–187)

```
BULK EDIT BAR (div.bulk #bulkBar)  — toggle: class "show"
├── Selection Count (span.cnt #bulkCnt) — "X sel"
├── "Cat:" label + dropdown (select #bulkCat) + "Set" (button.hb.pri) → bulkSetCat()
├── "Code:" label + dropdown (select #bulkCC) + "Set" (button.hb.pri) → bulkSetCC()
├── "Size:" label + input (input #bulkSize) → Enter: bulkSetSize()
├── "Sub:" label + input (input #bulkSub) → Enter: bulkSetSub()
├── div.sep
├── "Exclude" (button.hb) → bulkExclude()                [red text]
└── "Deselect" (button.hb) → clearSel()
```

Shown/hidden by `updateBulkBar()` (L:599). Purple border when visible.

---

## 5. FILTER BAR — `div.fbar` (L:190–203)

```
FILTER BAR (div.fbar)
├── Eye Reset Button (button, inline style) → call('showAll'); resetVis()   [SVG: eye icon 14px, #6c7086]
├── Search (input #fS) → oninput: filt()
├── "Cat:" label + dropdown (select #fC) → onchange: filt()
├── "Code:" label + dropdown (select #fCC) → onchange: filt()
├── "Sub:" label + dropdown (select #fSub) → onchange: filt()
├── div.sep
├── "Group:" label + dropdown (select #gBy) → onchange: filt()
│   ├── option "Category" (value="category")
│   ├── option "Cost Code" (value="costCode")
│   └── option "Subcategory" (value="subcategory")
└── Filter Count (span #fCnt) — "X / Y" (margin-left:auto, pushed right)
```

Dropdowns populated by `buildDD()` (L:301).

---

## 6. MAIN CONTENT — `div.tp #dp` (L:206)

Scrollable container populated by `renderGroups()` (L:438).

### 6a. Category Group — `div.cg` (one per group)

```
CATEGORY GROUP (div.cg #cg_{index})  — toggle: class "open"
├── GROUP HEADER (div.cgh)  — toggle: class "closed"
│   │   onclick → togCat(index, groupKey)
│   ├── Eye Toggle (button.ey) → togCatVis(groupKey)
│   │   ● = visible (&#9679;), ○ = hidden (&#9675;, class "off")
│   ├── Expand Arrow (span.arr) — ▼ rotates -90° when closed
│   ├── Category Name Badge (span.cname.c-{CatName}) — colored
│   │   [or plain gray span if grouped by costCode/subcategory]
│   ├── Item Count (span) — "(N)" in #6c7086
│   └── Group Total (span.cinfo) — e.g. "245.3 [SF icon]" in #89b4fa, right-aligned
│
└── GROUP BODY (div.cgb)  — display:none unless .cg.open
    ├── TOOLBAR (div.cg-toolbar)
    │   ├── [if grouped by category:]
    │   │   ├── "Unit:" label
    │   │   └── Unit Dropdown (select.cs) → onchange: setMT(groupKey, value)
    │   │       options: EA, LF, SF, SF+CY, SF+sht, EA+BF, EA+SF, ft3
    │   └── Action Buttons (span.cact) — margin-left:auto
    │       ├── [if grouped by category:]
    │       │   ├── Isolate (button.ib.accent) → isoCat(groupKey)         [SVG: ICO_ISO]
    │       │   ├── Zoom (button.ib.accent) → zoomCat(groupKey)           [SVG: ICO_ZOOM]
    │       │   └── Measure Tool (button.ib.warn) → mtBtn(curMT, groupKey)
    │       │       [Dynamic: ICO_SF for sf modes, ICO_LF for lf, hidden for ea/volume]
    │       ├── Select All (button.ib.accent) → selGrpItems(groupKey)     [SVG: ICO_SEL]
    │       └── [if grouped by category:]
    │           └── Exclude (button.ib.danger) → excludeCat(groupKey)     [SVG: ICO_X]
    │
    └── TABLE (table)
        ├── THEAD
        │   └── TR (column headers)
        │       ├── th.ck — checkbox: selGrpAll(groupKey, checked)
        │       ├── th — Eye icon header [SVG: eye 14px, #6c7086]
        │       ├── th "Category"
        │       ├── th "Code"
        │       ├── th "Sub"
        │       ├── th "Name"
        │       ├── th "Size"
        │       ├── th "Qty" (right-aligned)
        │       ├── th "Primary" (right-aligned)
        │       ├── th "2nd" (right-aligned)
        │       └── th (empty — actions column)
        │
        └── TBODY
            └── ITEM ROW (tr #r{entityId}) × N  — class "sel" when selected
                ├── td.ck — checkbox → ckClick(this, event)
                ├── td — Eye toggle (button.ey) → togItemVis(entityId)
                ├── td — Category dropdown (select.cs) → doSetCat(entityId, value)
                │   [includes "+" Custom..." option]
                ├── td — Cost Code dropdown (select.cs) → doSetCC(entityId, value)
                ├── td — Subcategory input (input.sz) → doSetSub(this)
                ├── td — Name (truncated 28 chars)
                │   └── Warning indicator (span.wi) — "!" if warnings present
                ├── td — Size input (input.sz) → doSetSize(this)
                ├── td.r — Qty (instanceCount)
                ├── td.r — Primary value → pv(row) [value + unit icon]
                ├── td.r — Secondary value → sv2(row)
                └── td — Row Actions
                    ├── Isolate (button.ib.accent) → call('isolateEntities', entityId)   [SVG: ICO_ISO]
                    └── Zoom (button.ib.accent) → call('zoomToEntity', entityId)          [SVG: ICO_ZOOM]
```

---

## 7. DEBUG PANEL — `#dbg` (L:207)

```
DEBUG PANEL (#dbg)  — toggle: class "show"
└── div × N — log entries with timestamps
    [class "err" for error messages, green #a6e3a1 default]
```

Toggled by `toggleDebug()`. Max 80px, monospace, scrolls. Messages added by `log(message, class)`.

---

## 8. SCAN DEBUG OVERLAY — `#scanOverlay` (L:210–213)

```
SCAN OVERLAY (#scanOverlay)  — toggle: class "show"
├── Header (div.so-hdr)
│   ├── Spinner (div.so-spin) — CSS animated border rotation
│   └── Title (span #scanTitle) — "Scanning Model..." / "Scan Complete"
└── Body (div.so-body #scanLog)
    └── div × N — log entries with timestamps
        classes: "stat" (blue), "warn" (yellow), "done" (green)
```

Fixed centered, 420×320px max. Controlled by:
- `scanStart()` — show overlay, clear log
- `scanMsg(msg, class)` — append message
- `scanEnd(summary)` — show complete, auto-hide after 3s

Called from Ruby via `Dashboard.scan_log_start`, `scan_log_msg`, `scan_log_end`.

---

## SVG Icons Reference

### Action Button Icons (16px, JS variables)

| Variable | Shape | Used In |
|----------|-------|---------|
| `ICO_ZOOM` | Magnifying glass — circle + handle line | Group toolbar, item row actions |
| `ICO_ISO` | Crosshair/target — circle + 4 extending lines | Group toolbar, item row actions |
| `ICO_SEL` | Cursor arrow — pointer + handle | Group toolbar (Select All) |
| `ICO_X` | X mark — two diagonal lines | Group toolbar (Exclude) |
| `ICO_LF` | Ruler — horizontal line + end caps + tick marks | Group toolbar (dynamic measure button) |
| `ICO_SF` | Area square — rectangle + edge tick marks | Group toolbar (dynamic measure button) |

### Inline Unit Icons (12px, JS variables)

| Variable | Shape | Used In |
|----------|-------|---------|
| `ICO_LF_SM` | Small ruler, stroke `#a6adc8` | `pv()`, `grpTotal()` — after LF values |
| `ICO_SF_SM` | Small square, stroke `#a6adc8` | `pv()`, `grpTotal()` — after SF values |

### Inline SVG in HTML

| Location | Shape | Size | Color |
|----------|-------|------|-------|
| Header LF button (L:153) | Ruler | 16px | `currentColor` (inherits yellow) |
| Header SF button (L:154) | Area square | 16px | `currentColor` (inherits yellow) |
| Filter bar eye (L:191) | Eye — oval + pupil circle | 14px | `#6c7086` |
| Table header eye (L:493) | Eye — oval + pupil circle | 14px | `#6c7086` |

### SVG Markup

**Eye Icon (14px, used in filter bar and table header):**
```svg
<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#6c7086"
  stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/>
  <circle cx="12" cy="12" r="3"/>
</svg>
```

**Magnifying Glass — ICO_ZOOM (16px):**
```svg
<svg width="16" height="16" viewBox="0 0 24 24" fill="none"
  stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <circle cx="11" cy="11" r="8"/>
  <line x1="21" y1="21" x2="16.65" y2="16.65"/>
</svg>
```

**Crosshair — ICO_ISO (16px):**
```svg
<svg width="16" height="16" viewBox="0 0 24 24" fill="none"
  stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <circle cx="12" cy="12" r="5"/>
  <line x1="12" y1="1" x2="12" y2="5"/>
  <line x1="12" y1="19" x2="12" y2="23"/>
  <line x1="1" y1="12" x2="5" y2="12"/>
  <line x1="19" y1="12" x2="23" y2="12"/>
</svg>
```

**Cursor Arrow — ICO_SEL (16px):**
```svg
<svg width="16" height="16" viewBox="0 0 24 24" fill="none"
  stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <path d="M3 3l7.07 16.97 2.51-7.39 7.39-2.51L3 3z"/>
  <path d="M13 13l6 6"/>
</svg>
```

**X Mark — ICO_X (16px):**
```svg
<svg width="16" height="16" viewBox="0 0 24 24" fill="none"
  stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <line x1="18" y1="6" x2="6" y2="18"/>
  <line x1="6" y1="6" x2="18" y2="18"/>
</svg>
```

**Ruler — ICO_LF (16px):**
```svg
<svg width="16" height="16" viewBox="0 0 16 16" fill="none"
  stroke-width="1.5" stroke-linecap="round">
  <line x1="2" y1="8" x2="14" y2="8"/>
  <line x1="2" y1="5" x2="2" y2="11"/>
  <line x1="14" y1="5" x2="14" y2="11"/>
  <line x1="5" y1="7" x2="5" y2="9"/>
  <line x1="8" y1="6" x2="8" y2="10"/>
  <line x1="11" y1="7" x2="11" y2="9"/>
</svg>
```

**Area Square — ICO_SF (16px):**
```svg
<svg width="16" height="16" viewBox="0 0 16 16" fill="none"
  stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
  <rect x="2" y="2" width="12" height="12" fill="currentColor" fill-opacity="0.15"/>
  <line x1="2" y1="6" x2="4" y2="6"/>
  <line x1="2" y1="10" x2="4" y2="10"/>
  <line x1="6" y1="2" x2="6" y2="4"/>
  <line x1="10" y1="2" x2="10" y2="4"/>
</svg>
```

---

## CSS Class Quick Reference

### Layout Containers
| Class/ID | Element | Purpose |
|----------|---------|---------|
| `.header` | div | Top toolbar row |
| `.summary` / `#sstrip` | div | Stats strip below header |
| `#catPanel` | div | Multi-isolate checkbox panel |
| `.bulk` / `#bulkBar` | div | Bulk edit bar (shown when items selected) |
| `.fbar` | div | Filter/search bar |
| `.tp` / `#dp` | div | Main scrollable content area |
| `#dbg` | div | Debug log panel |
| `#scanOverlay` | div | Scan progress overlay |

### Category Group
| Class/ID | Element | Purpose |
|----------|---------|---------|
| `.cg` | div | Category group wrapper (add `.open` to expand) |
| `.cgh` | div | Group header (add `.closed` to rotate arrow) |
| `.cgh .arr` | span | Expand/collapse arrow ▼ |
| `.cgh .cname` | span | Category name badge (colored) |
| `.cgh .cinfo` | span | Group total (right-aligned, blue) |
| `.cgb` | div | Group body (hidden unless `.cg.open`) |
| `.cg-toolbar` | div | Toolbar inside expanded group |
| `.cg-toolbar .cact` | span | Action buttons container (right-aligned) |

### Buttons
| Class | Purpose | Stroke Default → Hover |
|-------|---------|------------------------|
| `.hb` | Header button (text) | — |
| `.hb.pri` | Primary (purple bg) | — |
| `.hb.grn` | Green bg | — |
| `.hb.yel` | Yellow bg | — |
| `.ab` | Action button (text, bordered) | — |
| `.ib` | Icon button (no border/bg) | `#888` → `#fff` |
| `.ib.accent` | Icon button (accent hover) | `#888` → `#89b4fa` |
| `.ib.warn` | Icon button (yellow) | `#f9e2af` → `#ffe566` |
| `.ib.danger` | Icon button (red) | `#f38ba8` → `#ff6b8a` |
| `.ey` | Eye toggle button | `#a6adc8` → `#cdd6f4` |
| `.ey.off` | Eye toggle (hidden state) | `#45475a` |

### Table
| Class | Purpose |
|-------|---------|
| `table` | Full-width, collapsed borders |
| `th` | Sticky header, `background:#262637`, `font-size:10px` |
| `td` | Cell, truncated, `border-bottom:#222230` |
| `td.r` / `th.r` | Right-aligned numeric |
| `td.ck` / `th.ck` | Checkbox column (20px) |
| `tr.sel` | Selected row highlight `background:#2d2050` |
| `select.cs` | Inline category/code dropdown |
| `select.cs.fl` | Flagged dropdown (orange border) |
| `.sz` | Inline size/sub input (transparent until hover/focus) |

### Badges & Indicators
| Class | Purpose |
|-------|---------|
| `.cb` | Category badge (inline, colored bg) |
| `.c-{CatName}` | Color class for specific category (e.g. `.c-Drywall`) |
| `.tg` | Tag badge (gray) |
| `.wi` | Warning indicator "!" (yellow) |
| `.fi` | Flag indicator (orange) |
| `.sb` | Summary stat block |

---

## JavaScript Functions Reference

### Data & Initialization
| Function | Line | Purpose |
|----------|------|---------|
| `receiveData(json)` | 282 | Parse incoming data from Ruby, populate D/CA/CO |
| `buildDD()` | 301 | Build filter dropdowns from data |
| `buildCatPanel()` | 320 | Build multi-isolate checkboxes |
| `buildBulkDDs()` | 328 | Build bulk edit dropdowns |
| `window.onload` | 686 | Init, request data after 200ms |

### Communication
| Function | Line | Purpose |
|----------|------|---------|
| `call(name, arg)` | 273 | Call SketchUp Ruby callback |
| `callJSON(name, obj)` | 279 | Call callback with JSON-stringified object |

### Filtering & Rendering
| Function | Line | Purpose |
|----------|------|---------|
| `filt()` | 361 | Filter D → F based on search/dropdowns, then render |
| `strip()` | 385 | Update summary strip counts |
| `renderGroups()` | 438 | Main render — groups items, builds all HTML |

### Measurements & Display
| Function | Line | Purpose |
|----------|------|---------|
| `pv(row)` | 395 | Primary value string with unit icon |
| `sv2(row)` | 403 | Secondary value string |
| `pn(row)` | 411 | Pure numeric value (for sorting) |
| `grpTotal(items)` | 418 | Sum total for group with unit icon |
| `uLabel(mt)` | 233 | Returns inline unit icon/text for measurement type |
| `mtBtn(mt, gk)` | 240 | Returns dynamic measurement tool button HTML |
| `setMT(cat, mt)` | 669 | Set measurement type for category |

### Category Badges
| Function | Line | Purpose |
|----------|------|---------|
| `catBadge(c)` | 347 | Colored badge span for category (inline use) |
| `catNameSpan(c)` | 353 | Colored name span for group headers |

### Group Controls
| Function | Line | Purpose |
|----------|------|---------|
| `togCat(gi, gk)` | 542 | Toggle group expand/collapse |
| `expandAll()` | 543 | Expand all groups |
| `collapseAll()` | 544 | Collapse all groups |

### Visibility
| Function | Line | Purpose |
|----------|------|---------|
| `togCatVis(gk)` | 547 | Toggle group visibility in model |
| `togItemVis(eid)` | 557 | Toggle single item visibility |
| `isoCat(cat)` | 562 | Isolate one category (hide all others) |
| `zoomCat(cat)` | 567 | Zoom viewport to all items in category |
| `resetVis()` | 571 | Reset all visibility states |

### Selection
| Function | Line | Purpose |
|----------|------|---------|
| `ckClick(cb, ev)` | 574 | Checkbox click (supports shift-select range) |
| `syncCBs()` | 583 | Sync all checkboxes with SEL state |
| `selGrpItems(gk)` | 587 | Select all items in group |
| `selGrpAll(gk, chk)` | 592 | Select/deselect all in group (header checkbox) |
| `clearSel()` | 597 | Deselect all |
| `getSelIds()` | 598 | Get array of selected entity IDs |
| `updateBulkBar()` | 599 | Show/hide bulk bar based on selection count |
| `hlSel()` | 600 | Highlight selected entities in model |
| `grpKey(row, gBy)` | 601 | Get group key for a row |

### Multi-Isolate Panel
| Function | Line | Purpose |
|----------|------|---------|
| `toggleCatPanel()` | 609 | Toggle panel visibility |
| `cpAll(v)` | 610 | Check/uncheck all checkboxes |
| `getCheckedCats()` | 611 | Get array of checked category names |
| `doMultiIsolate()` | 612 | Isolate checked categories |
| `doMultiHide()` | 613 | Hide checked categories |
| `doMultiHighlight()` | 614 | Highlight checked categories |

### Bulk Edit
| Function | Line | Purpose |
|----------|------|---------|
| `bulkSetCat()` | 617 | Bulk set category (supports custom via prompt) |
| `bulkSetCC()` | 625 | Bulk set cost code |
| `bulkSetSize()` | 632 | Bulk set size |
| `bulkSetSub()` | 639 | Bulk set subcategory |
| `bulkExclude()` | 646 | Bulk exclude (set to _IGNORE) |
| `excludeCat(cat)` | 652 | Exclude entire category |

### Inline Edit
| Function | Line | Purpose |
|----------|------|---------|
| `doSetCat(eid, v)` | 661 | Set category for single item (supports custom) |
| `doSetCC(eid, v)` | 666 | Set cost code for single item |
| `doSetSize(el)` | 667 | Set size for single item |
| `doSetSub(el)` | 668 | Set subcategory for single item |

### Scan Debug Overlay
| Function | Line | Purpose |
|----------|------|---------|
| `scanStart()` | 251 | Show overlay, clear log |
| `scanMsg(msg, cls)` | 257 | Append timestamped message |
| `scanEnd(summary)` | 263 | Show complete, auto-hide after 3s |

### Debug & Utility
| Function | Line | Purpose |
|----------|------|---------|
| `log(msg, cls)` | 247 | Append to debug panel |
| `toggleDebug()` | 248 | Toggle debug panel |
| `scrollToEntity(eid)` | 674 | Open group, scroll row into view, flash green |
| `X(s)` | 682 | HTML escape |
| `X2(s)` | 683 | JS string escape (for onclick attributes) |
| `T(s, n)` | 684 | Truncate string to n chars |

---

## Global JS State Variables

| Variable | Type | Purpose |
|----------|------|---------|
| `D` | Array | All data rows (master, never filtered) |
| `CA` | Array | All category names |
| `CO` | Array | All cost code objects `{code, full}` |
| `F` | Array | Filtered rows (subset of D) |
| `sc` | String | Sort column name (default: `'definitionName'`) |
| `sd` | Number | Sort direction: `1` or `-1` |
| `SEL` | Object | Selected entity IDs `{entityId: true}` |
| `lastCheckIdx` | Number | Last checkbox index for shift-select |
| `openCats` | Object | Open group keys `{groupKey: true}` |
| `VIS` | Object | Per-entity visibility `{entityId: bool}` |
| `CATVIS` | Object | Per-group visibility `{groupKey: bool}` |
| `debugOn` | Boolean | Debug panel visible flag |
| `FIDX` | Array | Filtered entity ID index (maps visual index → entityId) |
| `KNOWN_CATS` | Object | Known category names for CSS color lookup |

---

## Ruby Action Callbacks (dashboard.rb)

### Data
| Callback | Params | Handler |
|----------|--------|---------|
| `requestData` | — | `send_data(sr, ca, cca)` |
| `rescan` | — | `TakeoffTool.run_scan` |

### Single Item Edit
| Callback | Params (JSON) | Handler |
|----------|---------------|---------|
| `setCategory` | `{eid, val}` | Update `ca[eid]`, persist, resend data |
| `setCostCode` | `{eid, val}` | Update `cca[eid]`, persist |
| `setSize` | `{eid, val}` | Persist, update scan results |
| `setSubcategory` | `{eid, val}` | Persist |
| `setMeasurementType` | `{cat, mt}` | Persist to model attributes, resend data |

### Bulk Edit
| Callback | Params (JSON) | Handler |
|----------|---------------|---------|
| `bulkSetCategory` | `{eids:[], val}` | Update all, persist, resend data |
| `bulkSetCostCode` | `{eids:[], val}` | Update all, persist, resend data |
| `bulkSetSize` | `{eids:[], val}` | Update all, persist, resend data |
| `bulkSetSubcategory` | `{eids:[], val}` | Update all, persist, resend data |

### Navigation
| Callback | Params | Handler |
|----------|--------|---------|
| `selectEntity` | `eid` (string) | Select entity in model |
| `zoomToEntity` | `eid` (string) | Select + zoom camera |
| `zoomToEntities` | `ids` (comma-separated) | Zoom to bounding box |

### Visibility & Highlighting
| Callback | Params | Handler |
|----------|--------|---------|
| `highlightAll` | — | Highlight all scanned items |
| `highlightEntities` | `ids` (comma-separated) | Highlight specific entities |
| `highlightCategory` | `cat` (string) | Highlight one category |
| `highlightSingle` | `eid` (string) | Highlight one entity |
| `highlightCategories` | `{cats:[]}` (JSON) | Highlight multiple categories |
| `clearHighlights` | — | Remove all highlights |
| `isolateCategory` | `cat` (string) | Show only one category |
| `isolateTag` | `tag` (string) | Isolate by Revit tag |
| `isolateCategories` | `{cats:[]}` (JSON) | Show only selected categories |
| `isolateEntities` | `ids` (comma-separated) | Isolate specific entities |
| `showAll` | — | Unhide everything |
| `showEntities` | `ids` (comma-separated) | Show specific entities |
| `hideEntities` | `ids` (comma-separated) | Hide specific entities |
| `hideCategories` | `{cats:[]}` (JSON) | Hide specific categories |

### Measurement Tools
| Callback | Params | Handler |
|----------|--------|---------|
| `activateLF` | — | Activate LF measurement tool |
| `activateSF` | — | Activate SF measurement tool |
| `activateSFForCat` | `cat` (string) | SF tool bound to category |

### Export
| Callback | Params | Handler |
|----------|--------|---------|
| `exportCSV` | — | Export CSV file |
| `exportHTML` | — | Export HTML report |

---

## Row Data Structure

Each row in `D[]` (received from Ruby via `receiveData`):

```javascript
{
  entityId:        Number,   // SketchUp entity ID
  tag:             String,   // Revit layer/tag name
  definitionName:  String,   // Display name
  elementType:     String,   // Parsed element type
  function:        String,   // Parsed function
  material:        String,   // Material name
  thickness:       String,   // Parsed thickness
  sizeNominal:     String,   // Size (e.g. "2x6")
  isSolid:         Boolean,  // Manifold solid
  instanceCount:   Number,   // Count of same-name instances
  volumeFt3:       Number,   // Volume in cubic feet
  volumeBF:        Number,   // Volume in board feet
  areaSF:          Number,   // Area in square feet
  linearFt:        Number,   // Linear feet (longest BB dim)
  bbWidth:         Number,   // Bounding box width (inches)
  bbHeight:        Number,   // Bounding box height (inches)
  bbDepth:         Number,   // Bounding box depth (inches)
  category:        String,   // Assigned category
  measurementType: String,   // ea|lf|sf|sf_cy|sf_sheets|ea_bf|ea_sf|volume
  costCode:        String,   // Assigned cost code
  subcategory:     String,   // Assigned subcategory
  suggestedCodes:  Array,    // Auto-suggested cost codes
  hasOverlap:      Boolean,  // Multiple suggested codes, none assigned
  warnings:        Array,    // Warning strings
  revitId:         String,   // Revit element ID
  ifcType:         String    // IFC classification
}
```

---

## Color Palette (Catppuccin Mocha)

| Usage | Color | Hex |
|-------|-------|-----|
| Background (base) | Dark navy | `#1e1e2e` |
| Background (surface) | Darker | `#181825` |
| Background (overlay) | Mid | `#313244` |
| Border (subtle) | Dark gray | `#252535` |
| Border (normal) | Gray | `#45475a` |
| Text (primary) | Light | `#cdd6f4` |
| Text (secondary) | Muted | `#a6adc8` |
| Text (dimmed) | Dim gray | `#6c7086` |
| Accent (purple) | Primary | `#cba6f7` |
| Accent (blue) | Info/highlight | `#89b4fa` |
| Accent (green) | Success/debug | `#a6e3a1` |
| Accent (yellow) | Warning | `#f9e2af` |
| Accent (orange) | Flag | `#fab387` |
| Accent (red/pink) | Error/danger | `#f38ba8` |
| Table header bg | Dark blue | `#262637` |
| Row hover | Subtle blue | `#2a2a3e` |
| Selected row | Purple tint | `#2d2050` |
| Scroll highlight | Green tint | `#2d4a2d` |

---

## Category Color Map

| Category | CSS Class | Background |
|----------|-----------|------------|
| Drywall | `.c-Drywall` | `#f9e2af` |
| Wall Framing | `.c-WallFraming` | `#fab387` |
| Walls | `.c-Walls` | `#f0c8a0` |
| Wall Finish | `.c-WallFinish` | `#f0dca0` |
| Wall Structure | `.c-WallStructure` | `#dcaa78` |
| Wall Sheathing | `.c-WallSheathing` | `#e6d2a0` |
| Masonry / Veneer | `.c-MasonryVeneer` | `#d2b48c` |
| Siding | `.c-Siding` | `#8cc88c` |
| Exterior Finish | `.c-ExteriorFinish` | `#78be78` |
| Metal Roofing | `.c-MetalRoofing` | `#8cb4dc` |
| Shingle Roofing | `.c-ShingleRoofing` | `#a08cb4` |
| Roofing | `.c-Roofing` | `#96aad2` |
| Roof Framing | `.c-RoofFraming` | `#c89664` |
| Roof Sheathing | `.c-RoofSheathing` | `#e6c896` |
| Concrete | `.c-Concrete` | `#aaa` |
| Flooring | `.c-Flooring` | `#beb496` |
| Structural Lumber | `.c-StructuralLumber` | `#dca050` |
| Insulation | `.c-Insulation` | `#ffb4dc` |
| Membrane | `.c-Membrane` | `#c8c8ff` |
| Windows | `.c-Windows` | `#64b4ff` |
| Doors | `.c-Doors` | `#a07850` |
| Casework | `.c-Casework` | `#b4c88c` |
| Countertops | `.c-Countertops` | `#c8b4a0` |
| Ceilings | `.c-Ceilings` | `#a0c8e6` |
| Plumbing | `.c-Plumbing` | `#64c8c8` |
| Hardware | `.c-Hardware` | `#c8c8c8` |
| Trim | `.c-Trim` | `#b48cc8` |
| Fascia | `.c-Fascia` | `#b4a0c8` |
| Soffit | `.c-Soffit` | `#c8b4dc` |
| Generic Models | `.c-GenericModels` | `#c8c8a0` |
| Uncategorized | `.c-Uncategorized` | `#ff6464` |
| Gutters | `.c-Gutters` | `#8ca0b4` |
| Flashing | `.c-Flashing` | `#b4b4dc` |
| Baseboard | `.c-Baseboard` | `#c8a088` |
| Crown Mold | `.c-CrownMold` | `#c8b0a0` |
| Casing | `.c-Casing` | `#b0a0c0` |
| Railing | `.c-Railing` | `#a0b0c0` |
| Drip Edge | `.c-DripEdge` | `#90b0a0` |
| Tile | `.c-Tile` | `#a0c8b4` |
| Backsplash | `.c-Backsplash` | `#b4c8c8` |
| Shower Walls | `.c-ShowerWalls` | `#90b8c8` |
| _IGNORE | `.c-_IGNORE` | `#585b70` |

Unknown categories get a hash-generated HSL color via `catBadge()` / `catNameSpan()`.
