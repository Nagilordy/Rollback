// Rollback's HDR video layer on Linux (Wayland).
//
// A Wayland subsurface kept just under Rollback's window, where libmpv draws the video through
// its render API on a 10-bit EGL surface. For HDR videos the layer is described to the
// compositor as HDR10 (PQ, BT.2020) with wp_color_manager_v1, and mpv is told to output PQ up
// to the screen's real peak brightness (read from the compositor), so KWin passes the picture
// to an HDR screen without converting it. SDR videos keep a plain sRGB layer.
//
// Rollback's window is see-through where Flutter draws nothing, so the video shows through and
// Rollback's controls sit on top: one window, the compositor puts the two together.

#pragma once

#include <gtk/gtk.h>

struct mpv_handle;

namespace frame_video {

class HdrSurface;

struct HdrInfo {
  bool hdr = false;          // the layer is described as HDR10
  double peak_nits = 0;      // screen peak brightness used for mpv (0 = unknown)
  double reference_nits = 0; // brightness of SDR white on this screen
};

// Whether this display can show the HDR layer at all (Wayland with wp_color_manager_v1 that
// supports parametric PQ / BT.2020). Fills `why` with a short reason when it can't.
bool HdrSupported(GtkWidget* view, const char** why);

// Creates the layer under `view` (Rollback's FlView) and starts drawing `mpv` into it. mpv must
// have been created with vo=libmpv and no other render context. `hdr` picks HDR10 or sRGB.
// Returns nullptr on failure (logged).
HdrSurface* HdrOpen(GtkWidget* view, mpv_handle* mpv, bool hdr, HdrInfo* info);

// Switches an open layer between HDR10 and sRGB (for the next video).
void HdrSetMode(HdrSurface* surface, bool hdr, HdrInfo* info);

// What the layer shows now. It follows the screen by itself: when the compositor says the
// screen changed (HDR switched on or off), the layer picks HDR10 or sRGB again for the video.
HdrInfo HdrCurrent(HdrSurface* surface);

// Stops drawing and removes the layer. Safe with nullptr.
void HdrClose(HdrSurface* surface);

}  // namespace frame_video
