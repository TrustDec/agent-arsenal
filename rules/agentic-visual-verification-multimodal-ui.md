---
description: Agentic visual verification, multimodal UI feedback loops, headless browser perceptual diffing, Playwright/CDP screenshot grounding, Set-of-Marks visual coordinates, WCAG contrast auditing, responsive viewport matrix, layout shift & z-index stacking context debugging across Claude Code, Cursor, Windsurf, Devin, and Pi
globs: **/*{visual,screenshot,multimodal,playwright,puppeteer,css,tailwind,ui,layout,viewport,frontend}*.*,**/rules/**,**/.cursorrules,**/CLAUDE.md,**/AGENTS.md,**/.agents/**
alwaysApply: false
---

# Agentic Visual Verification, Headless UI Diffs & Multimodal Feedback Loops

> Add these rules to your project when configuring autonomous coding agents, frontend engineering harnesses, or SWE-bench UI benchmarks (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Bolt.new, v0, Roo Code, Pi). Eliminate the "Syntax-Green Visual Disaster" by closing the perceptual feedback loop: capturing headless browser screenshots across a multi-viewport matrix, computing perceptual diffs (SSIM/pixelmatch), evaluating WCAG contrast invariants, and driving visual self-correction via multimodal reasoning before declaring any frontend task complete.

---

## 1. Architectural Taxonomy: The DOM Mirage vs Multimodal Verification

In modern autonomous software engineering, frontend tasks generate a notorious failure mode known as the **DOM Mirage** or **Syntax-Green Visual Disaster**:

- **The DOM Mirage ($O(1)$ False Positive Trap)**:
  - An agent modifies a component (React, Vue, Svelte, Nuxt, Astro, HTML/CSS).
  - The TypeScript compiler passes (`tsc --noEmit` exits `0`).
  - Unit and DOM tests pass cleanly (`expect(screen.getByRole('button')).toBeInTheDocument()` is true because the element exists in the DOM tree).
  - The agent declares the task complete. Yet in reality, the button is **completely invisible to users**: clipped behind an ancestor with `overflow: hidden`, buried behind a sticky navigation header due to an isolated CSS stacking context (`z-index` war), or shoved outside the visible viewport.
- **The Dark Mode Contrast Black Hole**:
  - The agent styles a component with Tailwind CSS classes or CSS variables. In light mode it looks acceptable, but when dark mode activates (`.dark`), text color resolves to dark gray (`#4b5563`) on a black background (`#09090b`), yielding an unreadable contrast ratio of $1.7:1$ and violating WCAG 2.1 AA invariants ($4.5:1$).
- **Mobile Viewport Explosion & Horizontal Scroll Bleed**:
  - The agent designs on an implicit $1440\text{px}$ canvas. When rendered on a $375\text{px}$ mobile screen, fixed-width containers (`w-[480px]`) cause horizontal overflow bleed ($x_{\text{scroll}} > 0$), or CTA button labels wrap awkwardly across three fragmented lines.
- **Phantom Overlay & Pointer Event Traps**:
  - The agent introduces an unmounted modal backdrop or a full-page translucent wrapper with `pointer-events: auto` and `opacity: 0`. The UI looks normal, but all interactive buttons underneath are rendered unclickable because the transparent element captures all pointer clicks.
- **The Multimodal Visual Feedback Invariant**:
  - Autonomous agents must never declare a frontend modification complete based solely on DOM queries or compiler success.
  - The agent must orchestrate a **Headless Visual Verification Loop**: render the component in a headless browser (Playwright/Puppeteer/CDP), capture screenshots across a **Multi-Viewport Matrix** (Mobile, Tablet, Desktop), extract computed styles and stacking contexts, calculate perceptual image diffs ($\text{SSIM}$), audit WCAG contrast ratios, and feed visual artifacts into multimodal vision reasoning for closed-loop verification.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Frontend Feature / Bug Ticket ("Add responsive checkout modal with dark mode support")            │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
         ┌────────────────────────────────────────┴────────────────────────────────────────┐
         │                                                                                 │
         ▼ [ANTI-PATTERN: Blind Text-Only Generation]                                      ▼ [PRODUCTION: Multimodal Visual Feedback Loop]
┌─────────────────────────────────────────────────┐               ┌─────────────────────────────────────────────────┐
│ Agent edits Vue/React/Tailwind files.           │               │ Agent edits Vue/React/Tailwind files.           │
│ Runs `tsc` and `vitest run`: PASSES.            │               ├─────────────────────────────────────────────────┤
├─────────────────────────────────────────────────┤               │ Headless Preview Engine (Playwright / CDP):     │
│ The Reality in Production:                      │               │ 1. Render Mobile (375px), Tablet, Desktop.      │
│ - Modal trapped under sticky navbar (z-index).  │               │ 2. Test Light Mode + Dark Mode variants.        │
│ - Text contrast ratio 1.6:1 (unreadable).       │               │ 3. Automated Invariants:                        │
│ - Horizontal scrollbar bleed on mobile (375px). │               │    • No horizontal overflow (scrollWidth===clientWidth)│
│ - Backdrop traps clicks on submit button.       │               │    • WCAG 2.1 AA Contrast Ratio (C >= 4.5:1)     │
├─────────────────────────────────────────────────┤               │    • Top-of-stack hit test (elementFromPoint)   │
│ Disaster: Customer checkout broken in prod!     │               ├─────────────────────────────────────────────────┤
│ Text-only LLM was blind to visual geometry.     │               │ Multimodal Vision LLM Feedback:                 │
│                                                 │               │ - Feed visual screenshot + perceptual diff mask │
│                                                 │               │ - Detect layout clipping, spacing, visual taste │
│                                                 │               │ - Surgical CSS fix before declaring DoD green   │
└─────────────────────────────────────────────────┘               └─────────────────────────────────────────────────┘
```

---

## 2. Mathematical Formalism: Perceptual Distance, Color Contrast & Layout Metrics

We quantify visual correctness and layout stability across three formal criteria:

### 2.1 Structural Similarity Index Measure (SSIM)
To detect visual regressions without brittle single-pixel sensitivity caused by font antialiasing or GPU rasterization differences, we compute SSIM over local pixel windows $x$ and $y$:

$$\text{SSIM}(x, y) = \frac{(2\mu_x\mu_y + C_1)(2\sigma_{xy} + C_2)}{(\mu_x^2 + \mu_y^2 + C_1)(\sigma_x^2 + \sigma_y^2 + C_2)}$$

Where:
- $\mu_x, \mu_y$ are local pixel luminance averages.
- $\sigma_x^2, \sigma_y^2$ are local variances.
- $\sigma_{xy}$ is the local covariance between baseline and candidate images.
- $C_1 = (K_1 L)^2, C_2 = (K_2 L)^2$ are stability constants ($K_1=0.01, K_2=0.03, L=255$).

**Visual Regression Invariant**:
$$\text{SSIM}(\text{Baseline}, \text{Candidate}) \ge 0.985 \quad (\text{for non-layout visual refactors})$$

### 2.2 WCAG 2.1 Relative Luminance & Contrast Ratio
Given sRGB channel values $R, G, B \in [0, 255]$, compute linearized color values $c \in [0, 1]$:

$$c_{\text{linear}} = \begin{cases} \frac{c_{\text{srgb}}}{12.92} & \text{if } c_{\text{srgb}} \le 0.04045 \\ \left(\frac{c_{\text{srgb}} + 0.055}{1.055}\right)^{2.4} & \text{if } c_{\text{srgb}} > 0.04045 \end{cases}$$

Relative luminance $L$ is computed via:
$$L = 0.2126 R_{\text{linear}} + 0.7152 G_{\text{linear}} + 0.0722 B_{\text{linear}}$$

The contrast ratio $C$ between foreground luminance $L_1$ and background luminance $L_2$ ($L_1 > L_2$) is:
$$C = \frac{L_1 + 0.05}{L_2 + 0.05}$$

**Contrast Compliance Bounds**:
$$C_{\text{body text}} \ge 4.5:1 \quad (\text{WCAG AA Standard})$$
$$C_{\text{large text / headings } (\ge 18\text{pt or bold } \ge 14\text{pt})} \ge 3.0:1$$
$$C_{\text{active UI controls \& focus rings}} \ge 3.0:1$$

### 2.3 Cumulative Layout Shift (CLS) & Viewport Containment
Layout shift score is the product of impact fraction and distance fraction:

$$\text{CLS} = \sum_{i} \left( \text{Impact Fraction}_i \times \text{Distance Fraction}_i \right)$$

**Layout Invariants**:
$$\text{CLS} < 0.05 \quad (\text{Zero perceptible visual jitter during dynamic hydration})$$
$$\Delta x_{\text{overflow}} = \text{document.documentElement.scrollWidth} - \text{window.innerWidth} \equiv 0 \quad (\forall \text{ viewports})$$

---

## 3. The 3-Tier Multi-Viewport Matrix

Autonomous verification must execute across a standardized viewport matrix to catch responsive layout fractures:

| Tier | Viewport Dimensions | Device Profile | Primary Failure Modes Tested |
| :--- | :--- | :--- | :--- |
| **Tier 1: Mobile (Narrow)** | $375 \times 812\text{ px}$ (DPR: 2.0) | iPhone 13/14/15 Mini / Standard | Horizontal overflow bleed, hamburger menu collapse, mobile touch targets ($\ge 44 \times 44\text{px}$), single-column grid wrapping |
| **Tier 2: Tablet (Mid)** | $768 \times 1024\text{ px}$ (DPR: 2.0) | iPad Portrait / Surface | Two-column grid reflow, sidebar collapse vs overlay, modal centering, tablet navigation breakpoint boundary conditions |
| **Tier 3: Desktop (Wide)** | $1440 \times 900\text{ px}$ (DPR: 1.0 / 2.0) | Modern Laptop / External Display | Max-width content containers (`max-w-7xl`), multi-column tables, sticky sidebar anchoring, high-resolution asset scaling |

---

## 4. Production Reference Implementation: `VisualFeedbackVerificationHarness`

Below is the complete, production-grade TypeScript verification engine for autonomous agent harnesses (Claude Code, Cursor, Windsurf, Pi). It spins up a headless browser, captures multi-viewport screenshots, executes automated WCAG/overflow/hit-test checks, and prepares multimodal payloads for visual self-correction.

```typescript
import { chromium, type Browser, type Page } from 'playwright';
import * as fs from 'fs/promises';
import * as path from 'path';

export interface ViewportConfig {
  name: 'mobile' | 'tablet' | 'desktop';
  width: number;
  height: number;
  deviceScaleFactor: number;
}

export interface VisualAuditReport {
  timestamp: string;
  url: string;
  viewports: {
    name: string;
    screenshotPath: string;
    hasHorizontalOverflow: boolean;
    scrollWidth: number;
    clientWidth: number;
  }[];
  wcagViolations: {
    selector: string;
    foreground: string;
    background: string;
    contrastRatio: number;
    requiredRatio: number;
    fontSize: string;
  }[];
  occlusionIssues: {
    selector: string;
    expectedTarget: string;
    actualTopElement: string;
    boundingBox: { x: number; y: number; width: number; height: number };
  }[];
  passed: boolean;
  summary: string;
}

export class VisualFeedbackVerificationHarness {
  private browser: Browser | null = null;

  public readonly standardViewports: ViewportConfig[] = [
    { name: 'mobile', width: 375, height: 812, deviceScaleFactor: 2.0 },
    { name: 'tablet', width: 768, height: 1024, deviceScaleFactor: 2.0 },
    { name: 'desktop', width: 1440, height: 900, deviceScaleFactor: 1.0 },
  ];

  async initialize(): Promise<void> {
    if (!this.browser) {
      this.browser = await chromium.launch({
        headless: true,
        args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-gpu'],
      });
    }
  }

  async close(): Promise<void> {
    if (this.browser) {
      await this.browser.close();
      this.browser = null;
    }
  }

  /**
   * Executes full visual verification across all viewports and theme modes.
   */
  async verifyUrl(
    targetUrl: string,
    outputDir: string,
    criticalSelectors: string[] = []
  ): Promise<VisualAuditReport> {
    await this.initialize();
    await fs.mkdir(outputDir, { recursive: true });

    const report: VisualAuditReport = {
      timestamp: new Date().toISOString(),
      url: targetUrl,
      viewports: [],
      wcagViolations: [],
      occlusionIssues: [],
      passed: true,
      summary: '',
    };

    for (const vp of this.standardViewports) {
      const context = await this.browser!.newContext({
        viewport: { width: vp.width, height: vp.height },
        deviceScaleFactor: vp.deviceScaleFactor,
      });

      const page = await context.newPage();
      try {
        await page.goto(targetUrl, { waitUntil: 'networkidle', timeout: 15000 });

        // 1. Check for horizontal overflow bleed:
        const overflowMetrics = await page.evaluate(() => ({
          scrollWidth: document.documentElement.scrollWidth,
          clientWidth: document.documentElement.clientWidth,
          hasOverflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
        }));

        // 2. Capture full-page screenshot:
        const screenshotFilename = `screenshot_${vp.name}.png`;
        const screenshotPath = path.join(outputDir, screenshotFilename);
        await page.screenshot({ path: screenshotPath, fullPage: false });

        report.viewports.push({
          name: vp.name,
          screenshotPath,
          hasHorizontalOverflow: overflowMetrics.hasOverflow,
          scrollWidth: overflowMetrics.scrollWidth,
          clientWidth: overflowMetrics.clientWidth,
        });

        if (overflowMetrics.hasOverflow) {
          report.passed = false;
        }

        // 3. Inspect Stacking Context / Occlusion on critical interactive selectors:
        for (const selector of criticalSelectors) {
          const occlusion = await this.checkElementOcclusion(page, selector);
          if (occlusion) {
            report.occlusionIssues.push(occlusion);
            report.passed = false;
          }
        }

        // 4. Run automated WCAG color contrast audit on text elements (on desktop):
        if (vp.name === 'desktop') {
          const contrastIssues = await this.auditColorContrast(page);
          if (contrastIssues.length > 0) {
            report.wcagViolations.push(...contrastIssues);
            report.passed = false;
          }
        }
      } finally {
        await context.close();
      }
    }

    report.summary = report.passed
      ? 'All visual invariants satisfied (no overflow, valid contrast, no occluded targets).'
      : `Visual invariants violated: ${report.wcagViolations.length} contrast errors, ${report.occlusionIssues.length} occlusions, overflow: ${report.viewports.some(v => v.hasHorizontalOverflow)}.`;

    await fs.writeFile(
      path.join(outputDir, 'visual_audit_report.json'),
      JSON.stringify(report, null, 2),
      'utf-8'
    );

    return report;
  }

  /**
   * Verifies that the target element is actually at the top of the stacking context
   * and not occluded by a rogue modal, fixed header, or transparent backdrop.
   */
  private async checkElementOcclusion(page: Page, selector: string) {
    return await page.evaluate((sel) => {
      const el = document.querySelector(sel);
      if (!el) return null;

      const rect = el.getBoundingClientRect();
      if (rect.width === 0 || rect.height === 0) return null;

      const centerX = rect.left + rect.width / 2;
      const centerY = rect.top + rect.height / 2;

      // Check what DOM node actually receives clicks at this center coordinate:
      const topEl = document.elementFromPoint(centerX, centerY);
      if (!topEl) return null;

      if (topEl !== el && !el.contains(topEl)) {
        return {
          selector: sel,
          expectedTarget: el.tagName.toLowerCase() + (el.id ? `#${el.id}` : ''),
          actualTopElement: topEl.tagName.toLowerCase() + (topEl.id ? `#${topEl.id}` : '') + `.${Array.from(topEl.classList).join('.')}`,
          boundingBox: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
        };
      }
      return null;
    }, selector);
  }

  /**
   * Evaluates WCAG 2.1 AA text contrast across visible text elements.
   */
  private async auditColorContrast(page: Page) {
    return await page.evaluate(() => {
      function parseRgb(colorStr: string): [number, number, number] | null {
        const match = colorStr.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/);
        return match ? [parseInt(match[1]), parseInt(match[2]), parseInt(match[3])] : null;
      }

      function getLuminance(r: number, g: number, b: number): number {
        const [rs, gs, bs] = [r, g, b].map((c) => {
          const s = c / 255;
          return s <= 0.04045 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
        });
        return 0.2126 * rs + 0.7152 * gs + 0.0722 * bs;
      }

      function getContrast(rgb1: [number, number, number], rgb2: [number, number, number]): number {
        const l1 = getLuminance(rgb1[0], rgb1[1], rgb1[2]);
        const l2 = getLuminance(rgb2[0], rgb2[1], rgb2[2]);
        const lighter = Math.max(l1, l2);
        const darker = Math.min(l1, l2);
        return (lighter + 0.05) / (darker + 0.05);
      }

      const violations: any[] = [];
      const textElements = Array.from(document.querySelectorAll('p, h1, h2, h3, h4, h5, h6, span, button, a, label'));

      for (const el of textElements.slice(0, 100)) { // Bounded sampling
        const text = el.textContent?.trim();
        if (!text || el.children.length > 2) continue;

        const style = window.getComputedStyle(el);
        if (style.display === 'none' || style.visibility === 'hidden' || parseFloat(style.opacity) === 0) continue;

        const fgRgb = parseRgb(style.color);
        let bgRgb = parseRgb(style.backgroundColor);

        // Climb DOM tree if background is transparent:
        let parent = el.parentElement;
        while ((!bgRgb || style.backgroundColor === 'rgba(0, 0, 0, 0)' || style.backgroundColor === 'transparent') && parent) {
          const parentStyle = window.getComputedStyle(parent);
          const candidateBg = parseRgb(parentStyle.backgroundColor);
          if (candidateBg && parentStyle.backgroundColor !== 'rgba(0, 0, 0, 0)' && parentStyle.backgroundColor !== 'transparent') {
            bgRgb = candidateBg;
            break;
          }
          parent = parent.parentElement;
        }

        if (!bgRgb) bgRgb = [255, 255, 255]; // Fallback to white canvas

        if (fgRgb && bgRgb) {
          const contrast = getContrast(fgRgb, bgRgb);
          const fontSize = parseFloat(style.fontSize);
          const isBold = parseInt(style.fontWeight) >= 700 || style.fontWeight === 'bold';
          const required = (fontSize >= 18 || (fontSize >= 14 && isBold)) ? 3.0 : 4.5;

          if (contrast < required) {
            violations.push({
              selector: el.tagName.toLowerCase() + (el.id ? `#${el.id}` : `.${Array.from(el.classList).slice(0, 2).join('.')}`),
              foreground: style.color,
              background: `rgb(${bgRgb.join(',')})`,
              contrastRatio: Math.round(contrast * 100) / 100,
              requiredRatio: required,
              fontSize: style.fontSize,
            });
          }
        }
      }
      return violations;
    });
  }
}
```

---

## 5. The Closed-Loop Visual Self-Correction State Machine (FSM)

Autonomous agents must transition through six strict states when building or editing frontend components:

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                VISUAL VERIFICATION FSM                                          │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
                 │
                 ▼
       ┌───────────────────┐
       │ 1. SYNTHESIZE     │  Generate / modify component code (Vue, React, Svelte, Tailwind)
       └─────────┬─────────┘
                 │
                 ▼
       ┌───────────────────┐
       │ 2. SPIN PREVIEW   │  Serve component via Vite / Next.js / Static Dev Server on PORT=0
       └─────────┬─────────┘
                 │
                 ▼
       ┌───────────────────┐
       │ 3. HEADLESS AUDIT │  Capture Multi-Viewport Matrix (375px, 768px, 1440px)
       └─────────┬─────────┘  Run automated checks: overflow, WCAG contrast, elementFromPoint
                 │
        ┌────────┴────────┐
        │                 │
 [Audits Fail]     [Audits Pass]
        │                 │
        ▼                 ▼
 ┌──────────────┐   ┌───────────────────┐
 │ SURGICAL FIX │   │ 4. VISION LLM     │  Prompt multimodal agent (Claude 3.7 / GPT-4o) with
 └──────┬───────┘   │    EVALUATION     │  annotated screenshots to critique aesthetics,
        │           └─────────┬─────────┘  spacing balance, and visual hierarchy
        │                     │
        │             ┌───────┴───────┐
        │             │               │
        │       [Critique Fails]  [Critique Approved]
        │             │               │
        └─────────────┘               ▼
                             ┌───────────────────┐
                             │ 5. GREEN PROOF    │  Save screenshot artifacts to pull request
                             │    (DoD MET)      │  Declare frontend task complete!
                             └───────────────────┘
```

---

## 6. Anti-Patterns vs Production Invariants

### 6.1 DOM Presence vs True Visual Renderability
- ❌ **Anti-Pattern: Testing solely via `getByRole` or `getByText`**:
  - Agent writes `expect(screen.getByRole('button', { name: /checkout/i })).toBeInTheDocument()`.
  - The test passes because the HTML tag exists in jsdom. But in a real browser, the button is rendered with `opacity: 0`, `position: absolute; left: -9999px`, or covered by an invisible modal overlay.
- ✅ **Production Invariant**:
  - Always verify renderability via `getBoundingClientRect()` and `document.elementFromPoint(x, y)`.
  - The element must have $W > 0, H > 0$, reside within the viewport bounds, and be the topmost target at its center coordinate.

### 6.2 Hardcoded Desktop Canvas vs Viewport Matrix
- ❌ **Anti-Pattern: Assuming a $1920\times 1080$ Desktop Viewport**:
  - The agent tests code only at full desktop width. When viewed on iPhone ($375\text{px}$ width), flex items refuse to shrink, tables blow out the screen, and the body expands to $520\text{px}$ causing disruptive horizontal panning.
- ✅ **Production Invariant**:
  - Always enforce zero horizontal overflow:
    ```javascript
    document.documentElement.scrollWidth === document.documentElement.clientWidth
    ```
  - Mobile ($375\times 812$) is a non-negotiable verification tier for every UI modification.

### 6.3 Arbitrary `z-index: 99999` Wars vs Isolated Stacking Contexts
- ❌ **Anti-Pattern: Incrementing Z-Index to "Fix" Occlusion**:
  - When an element is hidden behind a banner, the agent adds `z-index: 99999` or `!z-50`.
  - If the parent element has `transform`, `filter`, or `contain: paint`, it creates an isolated CSS Stacking Context, rendering child `z-index` values completely powerless against outside siblings.
- ✅ **Production Invariant**:
  - Inspect the CSS stacking context tree. Move portaled elements (modals, tooltips, dropdowns) to the document root (`<body>`) using portals (`<Teleport to="body">` in Vue, `createPortal` in React).
  - Use systematic z-index scales (`z-dropdown: 100`, `z-sticky: 200`, `z-modal: 500`, `z-toast: 1000`).

### 6.4 Sending Raw 4K Screenshots vs Set-of-Marks (SoM) Bounding Boxes
- ❌ **Anti-Pattern: Context-Flooding Vision Models with Uncompressed 4K Images**:
  - The agent sends raw $3840\times 2160$ PNG screenshots directly into the LLM context, consuming 4,000+ tokens per image and obscuring tiny button flaws due to vision encoder downsampling.
- ✅ **Production Invariant**:
  - Crop tightly around the modified component bounding box or use Set-of-Marks (SoM) annotations with numbered overlays (`[1]`, `[2]`, `[3]`).
  - Pass computed styles (color, font size, padding) alongside the cropped screenshot so the multimodal model has exact mathematical ground truth.

---

## 7. Definition of Done (DoD) Verification Matrix

Every frontend UI modification performed by an autonomous agent must satisfy all six machine-verifiable verification gates before being approved:

| Gate | Verification Check | Deterministic Command / Proof | Failure Remediation |
| :--- | :--- | :--- | :--- |
| **G1: Zero Viewport Overflow** | Zero horizontal scrollbar bleed on mobile viewports | `document.documentElement.scrollWidth === document.documentElement.clientWidth` on $375\text{px}$ viewport | Remove fixed `width` properties; replace with `max-w-full`, `w-full`, or `flex-wrap` |
| **G2: WCAG 2.1 AA Contrast** | All readable text meets minimum contrast ratio | $C = \frac{L_1 + 0.05}{L_2 + 0.05} \ge 4.5:1$ (or $\ge 3.0:1$ for large headings) in both Light & Dark modes | Adjust text token (e.g. swap `text-gray-400` with `text-gray-200` on dark backgrounds) |
| **G3: Clickable Hit-Test Integrity** | Interactive controls must be top-of-stack at center point | `document.elementFromPoint(centerX, centerY) === targetElement` | Fix stacking context; move modal to document root; add `pointer-events: none` to translucent backdrops |
| **G4: Mobile Touch Target Bounds** | All interactive touch elements meet minimum ergonomic size | $\min(\text{width}, \text{height}) \ge 44\text{ px}$ on mobile viewports ($375\text{px}$) | Add `p-2` or `min-h-[44px] min-w-[44px]` touch target padding |
| **G5: Cumulative Layout Shift (CLS)** | Zero perceptible shift during hydration or image load | $\text{CLS} < 0.05$ measured via `PerformanceObserver` during initial load | Reserve image dimensions with explicit `width`/`height` or aspect-ratio boxes |
| **G6: Visual Screenshot Artifacts** | Clean multi-viewport screenshot artifacts saved to disk | `test -f screenshot_mobile.png && test -f screenshot_desktop.png` | Run headless capture harness; attach images to PR/task summary |

---

## 8. Claude Code & Cursor Quick Integration Cheat Sheet

```bash
# 1. Install lightweight Playwright runner if missing:
npx playwright install chromium --with-deps

# 2. Run quick visual verification script against local dev preview:
node -e "
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 375, height: 812 } });
  await page.goto('http://localhost:3000', { waitUntil: 'networkidle' });
  const hasOverflow = await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth);
  console.log('Mobile 375px Horizontal Overflow:', hasOverflow ? '❌ FAILED' : '✅ PASSED');
  await page.screenshot({ path: 'mobile_preview.png' });
  await browser.close();
  process.exit(hasOverflow ? 1 : 0);
})();
"

# 3. Inspect the resulting preview image with multimodal Claude / Cursor:
# 'Please inspect mobile_preview.png. Are there any awkward line breaks, visual overlaps, or contrast issues?'
```
