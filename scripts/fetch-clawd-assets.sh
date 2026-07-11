#!/usr/bin/env bash
# fetch-clawd-assets.sh — Clawd overlay asset provisioning (spec step 2).
#
# WHY this exists: the Clawd pet sprites live in the upstream repo
# `rullerzhou-afk/clawd-on-desk`, which is AGPL-3.0. Vendoring AGPL art into
# kodex-ide would spread copyleft over the whole project, so the assets are
# NEVER committed — they are fetched onto the user's machine at setup time. This
# script is the fetch step. kodex-ide ships only this script + the Lua pet
# module; `assets/clawd/` is git-ignored, and the extracted frame cache lives
# outside the repo entirely (in nvim's cache dir).
#
# WHAT it does:
#   1. Download the 13 state GIFs into  <repo>/assets/clawd/           (git-ignored)
#   2. Explode each GIF into ~16 nearest-neighbour PNG frames into
#      <stdpath cache>/kodex_clawd/<state>/000.png …   (never committed)
#
# WHY nearest-neighbour (`-filter point`): these are pixel-art sprites. Smooth
# (bilinear/default) scaling blurs the hard pixel edges — the only visual
# artifact seen in the L1 render spike. Point filter + full-resolution source
# keeps them crisp. (spec: Licensing & Assets → "Pixel-art scaling rule")
#
# WHY the frame cache (not GIF playback): image.nvim does NOT animate GIFs (its
# processor reads frame [0] only) and its clear() wipes the transmit cache, so
# the renderer animates by swapping pre-extracted PNGs on a vim.loop timer.
# ~16 frames/state at ~120px (down from the source's 45–48) is ample for a desk
# pet at ~10 fps and halves retransmit cost. (spec: Rendering)
#
# Idempotent: re-running skips GIFs and frame sets already present. Pass --force
# to re-download and re-extract everything.
#
# Usage:  bash scripts/fetch-clawd-assets.sh [--force|--rebuild]
#         CLAWD_SKIN=calico bash scripts/fetch-clawd-assets.sh   # alt skin
set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
# The upstream repo, raw branch, and in-repo asset path. `main` confirmed as the
# default branch (2026-07-10). Three skins exist upstream (clawd / calico /
# cloudling); `clawd` is the default and the skin is a config knob here too.
readonly UPSTREAM_REPO="rullerzhou-afk/clawd-on-desk"
readonly UPSTREAM_BRANCH="main"
readonly UPSTREAM_GIF_PATH="assets/gif"
skin="${CLAWD_SKIN:-clawd}"

# The 13 states the overlay uses. These are the GIF basename suffixes as they
# appear upstream (verified against the downloaded spike asset set). Each maps
# 1:1 to a pet state in docs/clawd-overlay-spec.md § States → assets. Kept as an
# explicit list (not a glob) so a missing upstream file is a hard, named error
# rather than a silently-short frame set.
readonly STATES=(
  sleeping idle thinking typing idle-reading debugger sweeping
  error juggling notification happy react-annoyed headphones-groove
  building
)

# Target frame count per state. The source GIFs are 45–48 frames; we keep an
# evenly-spaced ~16 so the animation stays smooth but the cache stays under 1 MB.
readonly TARGET_FRAMES=16
# Render size (px). Sprites are 302×300; the pet shows at ~120px in the float.
# 127 (prime) on purpose: image.nvim only pre-resizes when the requested pixel
# width differs from the file's native width (a width-only check). A canvas whose
# width can never equal cols*cell_width guarantees the resize path for every asset —
# otherwise width-exact sprites ship the raw file and Ghostty renders them at native
# height, dipping ~0.35 rows below the anchor (live-diagnosed 2026-07-11).
readonly FRAME_SIZE=127

force=0
rebuild=0
case "${1:-}" in
  --force) force=1 ;;
  --rebuild) rebuild=1 ;;
esac

# ── Paths ────────────────────────────────────────────────────────────────────
# Repo root = the parent of this script's dir (scripts/..), resolved absolutely
# so the script works from any cwd.
# NOTE: assign THEN mark readonly on a separate statement. `readonly X="$(cmd)"`
# masks a failing command substitution under `set -e` (the readonly builtin's own
# success overwrites $?), so a bad `cd`/subshell would sail past instead of
# aborting. Split so set -e still sees the failure.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$script_dir/.." && pwd)"; readonly REPO_ROOT
readonly ASSET_DIR="$REPO_ROOT/assets/clawd"

# The frame cache MUST live where the Lua renderer will read it:
# `vim.fn.stdpath('cache')..'/kodex_clawd'`. Ask nvim directly so the two can
# never drift; fall back to the XDG default layout when nvim is unavailable
# (stdpath('cache') is $XDG_CACHE_HOME/nvim, i.e. ~/.cache/nvim by default).
resolve_cache_dir() {
  if command -v nvim >/dev/null 2>&1; then
    local from_nvim
    from_nvim="$(nvim --headless -u NONE \
      -c 'lua io.write(vim.fn.stdpath("cache"))' -c 'quit' 2>/dev/null || true)"
    if [[ -n "$from_nvim" ]]; then
      printf '%s/kodex_clawd' "$from_nvim"
      return
    fi
  fi
  printf '%s/nvim/kodex_clawd' "${XDG_CACHE_HOME:-$HOME/.cache}"
}
# Split assignment from readonly (same set -e masking reason as REPO_ROOT above).
# Frame sets are stored UNDER a per-skin subdir ($CACHE_DIR/$skin/$state) because
# the GIFs are skin-scoped: without the skin key, switching CLAWD_SKIN would
# re-download the new skin's GIFs but the idempotency check would find the old
# skin's frame dirs populated and skip extraction, so the pet would animate the
# wrong skin. The Lua renderer MUST read the same layout:
# `vim.fn.stdpath('cache')..'/kodex_clawd/'..skin..'/'..state`.
CACHE_DIR="$(resolve_cache_dir)"; readonly CACHE_DIR
readonly SKIN_CACHE_DIR="$CACHE_DIR/$skin"

# ── Dependency guards ────────────────────────────────────────────────────────
# Fail early with an actionable message rather than a cryptic mid-run error. The
# pet module itself degrades gracefully when the cache is absent, so a failed
# fetch never bricks the editor — it just means no pet until this runs cleanly.
require() {
  local tool="$1" hint="$2"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: '$tool' not found — $hint" >&2
    echo "       Clawd assets not fetched; the pet stays disabled until this runs." >&2
    exit 1
  fi
}
require curl "install curl to download the sprite GIFs"
require convert "install ImageMagick (provides 'convert') to extract PNG frames"

echo "Clawd asset fetch — skin '$skin'"
echo "  GIFs  → $ASSET_DIR"
echo "  cache → $SKIN_CACHE_DIR"
mkdir -p "$ASSET_DIR" "$SKIN_CACHE_DIR"

# ── 1. Download the state GIFs ───────────────────────────────────────────────
download_gif() {
  local state="$1"
  local gif="$ASSET_DIR/$skin-$state.gif"
  if [[ -s "$gif" && "$force" -eq 0 ]]; then
    echo "  · $state.gif present (skip)"
    return
  fi
  local url="https://raw.githubusercontent.com/$UPSTREAM_REPO/$UPSTREAM_BRANCH/$UPSTREAM_GIF_PATH/$skin-$state.gif"
  # Download to a .part sibling, then rename into place only on full success.
  # curl -f already leaves no file on an HTTP error, but a SIGINT/network-drop
  # mid-transfer kills the script before the error branch runs — writing to
  # .part means the real $gif is only ever the complete file, so an interrupted
  # run re-downloads next time instead of skipping a truncated GIF (contract 4).
  # -f: fail on HTTP errors. -S -s: quiet but still show the error. -L: follow.
  local part="$gif.part"
  if ! curl -fSsL "$url" -o "$part"; then
    echo "ERROR: download failed for $skin-$state.gif" >&2
    echo "       URL: $url" >&2
    rm -f "$part"
    exit 1
  fi
  mv -f "$part" "$gif"
  echo "  ↓ $state.gif"
}

# ── 2. Explode each GIF into an evenly-spaced PNG frame set ───────────────────
extract_frames() {
  local state="$1"
  local gif="$ASSET_DIR/$skin-$state.gif"
  local out="$SKIN_CACHE_DIR/$state"

  # Idempotent unless --force or --rebuild (local GIFs, no download).
  if [[ -d "$out" && -n "$(ls -A "$out" 2>/dev/null)" && "$force" -eq 0 && "$rebuild" -eq 0 ]]; then
    echo "  · $state frames present (skip)"
    return
  fi
  # Build the whole frame set in a staging dir, then swap it into place with a
  # single mv AFTER all frames are copied. A same-filesystem dir rename is
  # atomic, so an interrupted run (SIGINT/crash mid-copy) can only ever leave a
  # `.staging` dir — never a half-populated `$out` that the skip check above
  # would mistake for a complete set on the next run (contract 4).
  local staging="$out.staging"
  # Leave any existing $out IN PLACE during the (slow) build — a live renderer keeps
  # reading the old frames until the new set is ready. Removing $out up front instead
  # opened a multi-second window where the frames were gone and a running nvim's cached
  # image objects hit "No such file" on every swap tick (see the back-to-back swap below).
  rm -rf "$staging"
  mkdir -p "$staging"

  # Coalesce (flatten GIF disposal so every frame is a full image), scale
  # nearest-neighbour to the pet size, and dump ALL frames to a temp dir first.
  # We then keep an evenly-spaced subset — doing the selection in the shell is
  # simpler and more portable than convert's frame-range syntax.
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand tmp now so the trap cleans this exact dir
  trap "rm -rf '$tmp' '$staging'" RETURN
  # Crop OUT the transparent padding before scaling. The source sprites occupy a small
  # patch (~102x66) of a 302x300 canvas; without cropping, image.nvim fits the WHOLE
  # padded frame into the pet float, so the visible sprite is tiny and swims in empty
  # space (which, over the chat bar, reads as the pet covering the bar, and makes the
  # float size barely affect the apparent sprite size). Crop every frame to the UNION
  # content bounding box across the whole animation — one shared window, so the sprite
  # animates WITHIN it rather than each frame jittering/rescaling to its own bbox — THEN
  # scale to the pet size so the sprite fills the frame.
  local bbox
  bbox="$(convert "$gif" -coalesce -background none -format '%@\n' info: 2>/dev/null | \
    awk -F'[x+]' 'NR==1{minx=$3;miny=$4;maxx=$3+$1;maxy=$4+$2;next}
      {if($3<minx)minx=$3; if($4<miny)miny=$4;
       if($3+$1>maxx)maxx=$3+$1; if($4+$2>maxy)maxy=$4+$2}
      END{if(NR>0) printf "%dx%d+%d+%d",maxx-minx,maxy-miny,minx,miny}')"
  local -a crop_args=()

  if [[ -n "$bbox" ]]; then crop_args=(-crop "$bbox" +repage); fi
  convert "$gif" -coalesce -background none "${crop_args[@]}" \
    -filter point -resize "${FRAME_SIZE}x${FRAME_SIZE}" \
    -gravity southeast -extent "${FRAME_SIZE}x${FRAME_SIZE}" \
    "$tmp/src_%04d.png"

  # Normalize each visible frame to the common bottom baseline. The 120x120 canvas
  # stays fixed; only transparent bottom padding is rolled to the top.
  # First strip the baked-in drop shadow: some source sprites (idle, typing) draw a
  # pure-black bar under the feet in the bottom rows, which renders as a black box
  # on the statusline/chat bar. Pure black never appears legitimately that low
  # (face/keyboard blacks sit higher), so erase it in the bottom band only — BEFORE
  # the baseline roll, so the feet (not the shadow) become the flush bottom edge.
  local shadow_band=8
  local band_y=$(( FRAME_SIZE - shadow_band ))
  local frame metrics trim_h trim_y page_h bottom_pad
  for frame in "$tmp"/src_*.png; do
    convert "$frame" \
      \( +clone -crop "${FRAME_SIZE}x${shadow_band}+0+${band_y}" +repage \
         -fuzz 10% -transparent black \) \
      -geometry "+0+${band_y}" -compose Copy -composite "$frame"
    metrics="$(convert "$frame" -alpha extract -trim \
      -format '%h %[fx:page.y] %[fx:page.height]' info:)"
    read -r trim_h trim_y page_h <<< "$metrics"
    bottom_pad=$(( page_h - trim_y - trim_h ))
    if [[ "$bottom_pad" -gt 0 ]]; then
      convert "$frame" -background none -roll "+0+$bottom_pad" "$frame"
    fi
  done

  local -a all_frames
  # Sorted glob → deterministic frame order.
  mapfile -t all_frames < <(ls "$tmp"/src_*.png | sort)
  local total="${#all_frames[@]}"
  if [[ "$total" -eq 0 ]]; then
    echo "ERROR: $state.gif produced no frames" >&2
    exit 1
  fi

  # Keep an evenly-spaced subset: at most TARGET_FRAMES, but never more than the
  # source has (a short GIF keeps all its frames, no duplicates). Sampling
  # slot `k` maps to source index round(k * total / want), so the kept frames
  # span the whole loop. Renumber them 000,001,… so the renderer indexes them
  # contiguously.
  local want="$TARGET_FRAMES"
  if [[ "$total" -lt "$want" ]]; then want="$total"; fi
  local kept=0
  while [[ "$kept" -lt "$want" ]]; do
    local src_index=$(( kept * total / want ))
    printf -v dest "%s/%03d.png" "$staging" "$kept"
    cp "${all_frames[$src_index]}" "$dest"
    kept=$(( kept + 1 ))
  done
  # Publish: drop the old set and rename the complete staging set into place
  # BACK-TO-BACK, so the window where $out is absent (and a live renderer could see a
  # missing frame) is milliseconds, not the whole convert. The RETURN trap only removes
  # $staging if it still exists (i.e. we failed before this line), so this is safe.
  rm -rf "$out"
  mv "$staging" "$out"
  echo "  → $state: $kept frames (from $total)"
}

for state in "${STATES[@]}"; do
  download_gif "$state"
done
echo "Extracting frames…"
for state in "${STATES[@]}"; do
  extract_frames "$state"
done

echo "Done. ${#STATES[@]} states ready in $CACHE_DIR"
