---
name: Intelligent Focus
colors:
  surface: '#faf8ff'
  surface-dim: '#d2d9f4'
  surface-bright: '#faf8ff'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#f2f3ff'
  surface-container: '#eaedff'
  surface-container-high: '#e2e7ff'
  surface-container-highest: '#dae2fd'
  on-surface: '#131b2e'
  on-surface-variant: '#434655'
  inverse-surface: '#283044'
  inverse-on-surface: '#eef0ff'
  outline: '#737686'
  outline-variant: '#c3c6d7'
  surface-tint: '#0053db'
  primary: '#004ac6'
  on-primary: '#ffffff'
  primary-container: '#2563eb'
  on-primary-container: '#eeefff'
  inverse-primary: '#b4c5ff'
  secondary: '#712ae2'
  on-secondary: '#ffffff'
  secondary-container: '#8a4cfc'
  on-secondary-container: '#fffbff'
  tertiary: '#006242'
  on-tertiary: '#ffffff'
  tertiary-container: '#007d55'
  on-tertiary-container: '#bdffdb'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#dbe1ff'
  primary-fixed-dim: '#b4c5ff'
  on-primary-fixed: '#00174b'
  on-primary-fixed-variant: '#003ea8'
  secondary-fixed: '#eaddff'
  secondary-fixed-dim: '#d2bbff'
  on-secondary-fixed: '#25005a'
  on-secondary-fixed-variant: '#5a00c6'
  tertiary-fixed: '#6ffbbe'
  tertiary-fixed-dim: '#4edea3'
  on-tertiary-fixed: '#002113'
  on-tertiary-fixed-variant: '#005236'
  background: '#faf8ff'
  on-background: '#131b2e'
  surface-variant: '#dae2fd'
typography:
  display-lg:
    fontFamily: Inter
    fontSize: 40px
    fontWeight: '700'
    lineHeight: 48px
    letterSpacing: -0.02em
  display-lg-mobile:
    fontFamily: Inter
    fontSize: 32px
    fontWeight: '700'
    lineHeight: 40px
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: Inter
    fontSize: 28px
    fontWeight: '600'
    lineHeight: 36px
    letterSpacing: -0.01em
  headline-md:
    fontFamily: Inter
    fontSize: 22px
    fontWeight: '600'
    lineHeight: 28px
    letterSpacing: 0em
  title-lg:
    fontFamily: Inter
    fontSize: 18px
    fontWeight: '600'
    lineHeight: 24px
    letterSpacing: 0em
  title-md:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '600'
    lineHeight: 22px
    letterSpacing: 0.01em
  body-lg:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
    letterSpacing: 0em
  body-md:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
    letterSpacing: 0em
  label-lg:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '500'
    lineHeight: 20px
    letterSpacing: 0.01em
  label-md:
    fontFamily: Inter
    fontSize: 12px
    fontWeight: '500'
    lineHeight: 16px
    letterSpacing: 0.02em
  label-sm:
    fontFamily: Inter
    fontSize: 11px
    fontWeight: '600'
    lineHeight: 14px
    letterSpacing: 0.04em
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  gutter: 1rem
  gutter-tablet: 1.5rem
  margin: 1rem
  margin-tablet: 2rem
  space-xs: 0.25rem
  space-sm: 0.5rem
  space-md: 1rem
  space-lg: 1.5rem
  space-xl: 2rem
---

## Brand & Style

This design system is tailored for an offline-first Android learning companion that balances academic rigor with empathetic guidance. The interface blends modern Android Material 3 foundations with purposeful, focused minimalism to reduce cognitive load during prolonged study sessions. 

The emotional signature is calming, encouraging, and dependable. Interactions feel fluid, immediate, and responsive even without a network connection. Visual metaphors use precise geometric structuring, generous white space, and ambient depth to evoke the clarity of high-end educational stationery paired with the quiet intelligence of on-device AI.

## Colors

The palette pairs high-clarity structural tones with targeted contextual accents:
- **Primary Blue (`#2563EB`)**: Applied to foundational navigation, key functional anchors, active focus states, and primary actions.
- **AI Violet (`#7C3AED`)**: Reserved strictly for generative summaries, smart hints, adaptive flashcards, and AI-driven recommendations.
- **Canvas & Surface System**: Canvas sits at `#F8FAFC`, with layered interactive containers resting on pure `#FFFFFF`. Strokes rely on `#E2E8F0` at 1px for crisp structural delineation.
- **Semantic Accents**: `#10B981` denotes mastery and successful offline synchronization; `#F59E0B` signals active streaks, review warnings, and spaced-repetition recalls.
- **Text Hierarchy**: `#0F172A` provides AA/AAA compliant readability for body and display text, supported by `#64748B` for meta-labels and structural cues.

## Typography

The type system is built on **Inter** to ensure maximum legibility at small sizes during intensive reading sessions and data-dense problem solving on mobile screens. 

- Use `display-lg-mobile` exclusively on mobile viewports for splash screens and chapter headings, switching to `display-lg` on tablets.
- Keep `body-lg` restricted to long-form reading passages and AI-generated study summaries.
- Apply `label-sm` with uppercase styling solely for metadata, offline sync markers, and category tags.

## Layout & Spacing

Layout adheres to an 8-point baseline grid aligned with Android mobile constraints:
- **Mobile Grid (<600dp)**: 4-column fluid layout with `margin: 1rem` (16dp) safe horizontal insets and `gutter: 1rem` (16dp). Content stacks vertically into scrollable cards.
- **Tablet / Large Display (≥600dp)**: 8 to 12-column fluid grid with `margin-tablet: 2rem` (32dp) and `gutter-tablet: 1.5rem` (24dp), reflowing the canvas into dual-pane study views (e.g., source content on the left, interactive AI study module on the right).
- Spacing inside cards and modular blocks enforces strict vertical rhythm: `space-sm` between micro elements (icon + text), `space-md` for standard container padding, and `space-lg` to separate distinct conceptual learning segments.

## Elevation & Depth

Visual hierarchy combines low-contrast hairline outlines with soft ambient shadows to support natural Android spatial layering without visual noise:
- **Level 0 (Flat)**: Canvas background (`#F8FAFC`). No shadow.
- **Level 1 (Card & Containers)**: `#FFFFFF` surface with a 1px border (`#E2E8F0`) and an ambient shadow: `box-shadow: 0 1px 3px rgba(15, 23, 42, 0.04), 0 1px 2px rgba(15, 23, 42, 0.02)`.
- **Level 2 (Active Cards & Floating Menus)**: `box-shadow: 0 4px 6px -1px rgba(15, 23, 42, 0.06), 0 2px 4px -2px rgba(15, 23, 42, 0.04)`.
- **Level 3 (Modals & Bottom Sheets)**: `box-shadow: 0 10px 15px -3px rgba(15, 23, 42, 0.08), 0 4px 6px -4px rgba(15, 23, 42, 0.03)`.
- **AI Elevation Tint**: When surface components represent AI-generated cards, apply a 1px stroke of `rgba(124, 58, 237, 0.2)` with a tinted glow: `0 4px 12px rgba(124, 58, 237, 0.08)`.

## Shapes

The interface embraces modern Material 3 organic ergonomics:
- **Cards and Containers**: Set to `1rem` (16px) or `1.25rem` (20px) border-radius, creating smooth, touch-friendly visual frames for study units.
- **Pill Badges and Tags**: Use fully rounded pill geometries (`9999px` radius) for status chips, mastery tags, and offline badges.
- **Controls & Inputs**: Buttons and input fields leverage `0.75rem` (12px) radii to preserve tactical structure while matching container curves.

## Components

### Buttons
- **Primary**: Solid `#2563EB` background with `#FFFFFF` text, `0.75rem` radius, `0.75rem 1.25rem` padding, tactile press scale down to `0.98`.
- **AI Assist Action**: Solid `#7C3AED` or subtle gradient (`#7C3AED` to `#6D28D9`) with an internal sparkle icon; reserved exclusively for AI features (e.g., "Explain Concept", "Summarize").
- **Secondary / Outlined**: 1px `#E2E8F0` border, `#0F172A` text, transparent background transitioning to `#F1F5F9` on press.

### Cards
- Base background `#FFFFFF`, bordered with 1px `#E2E8F0`, `1rem` to `1.25rem` radius. Interactive cards elevate from Level 1 to Level 2 on press/focus.
- AI Study Cards include a subtle top border or pill indicator using `#7C3AED`.

### Chips & Pill Badges
- Compact height (28dp–32dp), fully rounded corners (`9999px`). 
- Offline state: `#F1F5F9` background, `#64748B` text, local storage dot icon.
- Mastery states: `#10B981` at 10% opacity background with `#047857` foreground.

### Input Fields
- Solid `#FFFFFF` fill with 1px `#E2E8F0` border, `0.75rem` radius. 
- Focus state switches border to 2px `#2563EB` with zero outer ring to maintain a clean aesthetic.

### Step Indicators
- Connected horizontal nodes for lesson modules. Completed steps feature a `#2563EB` or `#10B981` pill container; pending steps use a `#E2E8F0` hollow ring with `#64748B` numerical labels.

### Bottom Navigation Bar
- Grounded `#FFFFFF` surface with a top 1px border (`#E2E8F0`). 
- Active destinations are highlighted with a soft pill pill indicator (`#2563EB` at 12% opacity) enveloping a `#2563EB` icon and label. Inactive tabs render in `#64748B`.