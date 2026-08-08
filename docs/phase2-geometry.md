# Phase 2 — measured PDFKit coordinate behavior

Measured 2026-08-07 on macOS 15 / Xcode 26.6 by rendering generated fixtures with markers at
known page coordinates and reading the output pixels back. PLAN.md §9 lists
"coordinate-conversion bugs in crop mode" as a risk; this is the evidence the conversion is
built on, rather than on the documentation, which is ambiguous on two of these points.

## The three spaces

| | What it is | Origin | Rotation applied? |
|---|---|---|---|
| `page.bounds(for:)` | the page box | **may be non-zero** | **no** — dimensions are never swapped |
| `pdfView.convert(_:to: page)` | same space as `bounds(for:)` | may be non-zero | no |
| `page.draw(with:to:)` output | what actually gets rastered | always `(0, 0)` | **yes** |

So `convert` and `draw` disagree in two ways at once, and both have to be corrected:

1. **Origin.** `draw` maps `bounds.origin` to the context origin. A page with
   `MediaBox [100 50 300 150]` renders its content at `(0, 0)`, so a crop rect coming out of
   `convert` must have `bounds.origin` subtracted. Skipping this produces a crop of the wrong
   part of the page — silently, and only on documents with a non-zero box origin.
2. **Rotation.** `draw` renders the rotated page (extent `H × W` at 90°/270°) while
   `bounds(for:)` and `convert` keep speaking the unrotated `W × H` space.

`CropGeometry.renderRect(forUnrotated:boxBounds:rotation:)` is the bridge, and
`CropGeometry.renderedPageSize(boxBounds:rotation:)` gives the swapped extent.

## Measured rotation mapping

With `u` = the rect after subtracting `bounds.origin`, and `W`/`H` the unrotated box size:

| rotation | rendered rect | rendered extent |
|---|---|---|
| 0 | `(u.x, u.y, u.w, u.h)` | `W × H` |
| 90 | `(u.y, W − u.maxX, u.h, u.w)` | `H × W` |
| 180 | `(W − u.maxX, H − u.maxY, u.w, u.h)` | `W × H` |
| 270 | `(H − u.maxY, u.x, u.h, u.w)` | `H × W` |

Verified against three markers (bottom-left, top-left, bottom-right) in all four rotations —
each formula is pinned by three independent points, so a transposed-but-self-consistent mapping
could not pass.

**A `/Rotate` entry in the file and a programmatically assigned `page.rotation` behave
identically** — both were tested, so there is only one code path.

## Other findings

- **`PDFPage` does not retain its `PDFDocument`.** Drawing a page whose document has
  deallocated logs *"Drawing a PDFPage when its PDFDocument is nil is unsupported"* and produces
  a blank image rather than failing. Callers (and test fixtures) must hold the document.
- **`convert` round-trips exactly** across `scaleFactor` 0.5 – 4.0, including on rotated pages,
  so zoom needs no compensation of its own — the crop is defined in page space and is
  zoom-independent by construction. `CropLiveViewTests.testCropPixelSizeIsIndependentOfZoom`
  asserts this.
- **Colour is not preserved exactly.** DeviceRGB fills in a PDF arrive shifted after conversion
  to the output colour space (pure blue → ≈`(4, 51, 255)`, pure red → ≈`(255, 38, 0)`). Pixel
  assertions match the nearest marker colour rather than exact channel values.

## Reproducing

The probe scripts that produced these numbers are scratch (`.context/probe*.swift`, gitignored).
The behavior itself is locked in by `ClaudePDFTests` — `CropRendererTests` asserts marker colours
straight out of the PNG, so if a future macOS changes any of the above, those tests fail rather
than the app silently cropping the wrong region.
