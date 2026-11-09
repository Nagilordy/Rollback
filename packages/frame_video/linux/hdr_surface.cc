// Rollback's HDR video layer on Linux (Wayland). See hdr_surface.h.

#include "hdr_surface.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <gdk/gdkwayland.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <wayland-client.h>
#include <wayland-egl.h>

#include <atomic>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>

#include <unistd.h>

#include "color-management-v1-client-protocol.h"

#ifndef GL_RGB10_A2
#define GL_RGB10_A2 0x8059
#endif

namespace frame_video {

namespace {

// What the compositor's colour manager supports (from its events right after binding).
struct ColorCaps {
  bool parametric = false;
  bool perceptual = false;
  bool pq = false;
  bool bt2020 = false;
  bool done = false;
};

struct Globals {
  wl_compositor* compositor = nullptr;
  wl_subcompositor* subcompositor = nullptr;
  wp_color_manager_v1* color = nullptr;
  ColorCaps caps;
};

void OnSupportedIntent(void* data, wp_color_manager_v1*, uint32_t intent) {
  if (intent == WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL) static_cast<ColorCaps*>(data)->perceptual = true;
}
void OnSupportedFeature(void* data, wp_color_manager_v1*, uint32_t feature) {
  if (feature == WP_COLOR_MANAGER_V1_FEATURE_PARAMETRIC) static_cast<ColorCaps*>(data)->parametric = true;
}
void OnSupportedTf(void* data, wp_color_manager_v1*, uint32_t tf) {
  if (tf == WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ) static_cast<ColorCaps*>(data)->pq = true;
}
void OnSupportedPrimaries(void* data, wp_color_manager_v1*, uint32_t primaries) {
  if (primaries == WP_COLOR_MANAGER_V1_PRIMARIES_BT2020) static_cast<ColorCaps*>(data)->bt2020 = true;
}
void OnColorDone(void* data, wp_color_manager_v1*) { static_cast<ColorCaps*>(data)->done = true; }

const wp_color_manager_v1_listener kColorListener = {
    OnSupportedIntent, OnSupportedFeature, OnSupportedTf, OnSupportedPrimaries, OnColorDone,
};

void OnGlobal(void* data, wl_registry* registry, uint32_t name, const char* interface, uint32_t version) {
  auto* g = static_cast<Globals*>(data);
  if (strcmp(interface, wl_compositor_interface.name) == 0) {
    g->compositor = static_cast<wl_compositor*>(wl_registry_bind(registry, name, &wl_compositor_interface, 4));
  } else if (strcmp(interface, wl_subcompositor_interface.name) == 0) {
    g->subcompositor =
        static_cast<wl_subcompositor*>(wl_registry_bind(registry, name, &wl_subcompositor_interface, 1));
  } else if (strcmp(interface, wp_color_manager_v1_interface.name) == 0) {
    g->color = static_cast<wp_color_manager_v1*>(wl_registry_bind(registry, name, &wp_color_manager_v1_interface, 1));
    wp_color_manager_v1_add_listener(g->color, &kColorListener, &g->caps);
  }
  (void)version;
}
void OnGlobalRemove(void*, wl_registry*, uint32_t) {}
const wl_registry_listener kRegistryListener = {OnGlobal, OnGlobalRemove};

// An image description's readiness, and what the compositor says about one (preferred).
struct DescState {
  bool ready = false;
  bool failed = false;
};
void OnDescFailed(void* data, wp_image_description_v1*, uint32_t cause, const char* msg) {
  static_cast<DescState*>(data)->failed = true;
  g_message("frame_video hdr: image description refused (%u: %s)", cause, msg ? msg : "");
}
void OnDescReady(void* data, wp_image_description_v1*, uint32_t) { static_cast<DescState*>(data)->ready = true; }
const wp_image_description_v1_listener kDescListener = {OnDescFailed, OnDescReady};

struct PreferredInfo {
  bool done = false;
  uint32_t tf = 0;
  double max_nits = 0, reference_nits = 0, target_max_nits = 0;
};
void InfoDone(void* d, wp_image_description_info_v1*) { static_cast<PreferredInfo*>(d)->done = true; }
void InfoIcc(void*, wp_image_description_info_v1*, int32_t fd, uint32_t) { close(fd); }
void InfoPrimaries(void*, wp_image_description_info_v1*, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
                   int32_t, int32_t) {}
void InfoPrimariesNamed(void*, wp_image_description_info_v1*, uint32_t) {}
void InfoTfPower(void*, wp_image_description_info_v1*, uint32_t) {}
void InfoTfNamed(void* d, wp_image_description_info_v1*, uint32_t tf) { static_cast<PreferredInfo*>(d)->tf = tf; }
void InfoLuminances(void* d, wp_image_description_info_v1*, uint32_t, uint32_t max_lum, uint32_t ref_lum) {
  auto* p = static_cast<PreferredInfo*>(d);
  p->max_nits = max_lum;
  p->reference_nits = ref_lum;
}
void InfoTargetPrimaries(void*, wp_image_description_info_v1*, int32_t, int32_t, int32_t, int32_t, int32_t,
                         int32_t, int32_t, int32_t) {}
void InfoTargetLuminance(void* d, wp_image_description_info_v1*, uint32_t, uint32_t max_lum) {
  static_cast<PreferredInfo*>(d)->target_max_nits = max_lum;
}
void InfoTargetMaxCll(void*, wp_image_description_info_v1*, uint32_t) {}
void InfoTargetMaxFall(void*, wp_image_description_info_v1*, uint32_t) {}
const wp_image_description_info_v1_listener kInfoListener = {
    InfoDone,       InfoIcc,         InfoPrimaries,       InfoPrimariesNamed,
    InfoTfPower,    InfoTfNamed,     InfoLuminances,      InfoTargetPrimaries,
    InfoTargetLuminance, InfoTargetMaxCll, InfoTargetMaxFall,
};

wl_display* DisplayOf(GtkWidget* view) {
  GdkDisplay* gd = gtk_widget_get_display(view);
  if (!GDK_IS_WAYLAND_DISPLAY(gd)) return nullptr;
  return gdk_wayland_display_get_wl_display(gd);
}

// Binds the globals on a private queue (so GDK's own event handling is untouched).
bool BindGlobals(wl_display* display, wl_event_queue* queue, Globals* g) {
  auto* wrapper = static_cast<wl_display*>(wl_proxy_create_wrapper(display));
  wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(wrapper), queue);
  wl_registry* registry = wl_display_get_registry(wrapper);
  wl_proxy_wrapper_destroy(wrapper);
  wl_registry_add_listener(registry, &kRegistryListener, g);
  wl_display_roundtrip_queue(display, queue);  // globals
  wl_display_roundtrip_queue(display, queue);  // the colour manager's supported_* events
  wl_registry_destroy(registry);
  return g->compositor && g->subcompositor;
}

const char* Unsupported(const Globals& g) {
  if (!g.compositor || !g.subcompositor) return "no Wayland compositor or subsurfaces";
  if (!g.color) return "the compositor has no colour management (wp_color_manager_v1)";
  if (!g.caps.parametric) return "the compositor can't take parametric colour descriptions";
  if (!g.caps.pq || !g.caps.bt2020) return "the compositor doesn't support PQ / BT.2020";
  if (!g.caps.perceptual) return "the compositor doesn't support the perceptual intent";
  return nullptr;
}

void DestroyGlobals(Globals* g) {
  if (g->color) wp_color_manager_v1_destroy(g->color);
  if (g->subcompositor) wl_subcompositor_destroy(g->subcompositor);
  if (g->compositor) wl_compositor_destroy(g->compositor);
  *g = Globals();
}

}  // namespace

class HdrSurface {
 public:
  GtkWidget* view = nullptr;
  wl_display* display = nullptr;
  wl_event_queue* queue = nullptr;
  Globals g;
  wl_surface* surface = nullptr;
  wl_subsurface* subsurface = nullptr;
  wp_color_management_surface_v1* cm_surface = nullptr;
  wp_color_management_surface_feedback_v1* feedback = nullptr;
  wp_image_description_v1* desc = nullptr;
  gulong size_handler = 0;
  mpv_handle* mpv = nullptr;

  // What the current video asked for, what the layer shows now, and whether the screen
  // changed since (KDE's HDR switch, another screen): checked on the main thread.
  bool want_hdr = false;
  HdrInfo current;
  bool screen_changed = false;
  guint watch_source = 0;

  // Size of the layer in buffer pixels, and the buffer scale (main thread writes). The render
  // thread applies size and scale together, in the same commit as a buffer of that size: a
  // scale sent with a buffer that isn't a multiple of it is a Wayland protocol error, which
  // closes the app (e.g. dragging the window to a screen with other scaling).
  std::atomic<int> width{1}, height{1};
  std::atomic<int> scale{1};

  // Render thread.
  std::thread thread;
  std::mutex mutex;
  std::condition_variable wake;
  bool stop = false;
  bool redraw = false;
  bool resized = false;
  std::atomic<bool> started{false};
  std::atomic<bool> start_ok{false};

  wl_egl_window* egl_window = nullptr;
  EGLDisplay egl_display = EGL_NO_DISPLAY;
  EGLContext egl_context = EGL_NO_CONTEXT;
  EGLSurface egl_surface = EGL_NO_SURFACE;
  mpv_render_context* render = nullptr;
  int depth = 8;

  void Place();
  void SetDescription(bool hdr, HdrInfo* info);
  PreferredInfo QueryPreferred();
  void RenderLoop();
  bool StartGl();
  void StopGl();
};

void HdrSurface::Place() {
  GtkWidget* top = gtk_widget_get_toplevel(view);
  int x = 0, y = 0;
  gtk_widget_translate_coordinates(view, top, 0, 0, &x, &y);
  GdkWindow* gw = gtk_widget_get_window(top);
  const int sc = gw ? gdk_window_get_scale_factor(gw) : 1;
  const int w = gtk_widget_get_allocated_width(view) * sc;
  const int h = gtk_widget_get_allocated_height(view) * sc;
  wl_subsurface_set_position(subsurface, x, y);
  if (w != width.load() || h != height.load() || sc != scale.load()) {
    width = w > 0 ? w : sc;
    height = h > 0 ? h : sc;
    scale = sc;
    {
      std::lock_guard<std::mutex> lock(mutex);
      resized = true;
    }
    wake.notify_one();
  }
  // The position applies with Rollback's window's next commit.
  gtk_widget_queue_draw(top);
  wl_display_flush(display);
}

PreferredInfo HdrSurface::QueryPreferred() {
  PreferredInfo info;
  DescState state;
  wp_image_description_v1* preferred = wp_color_management_surface_feedback_v1_get_preferred(feedback);
  wp_image_description_v1_add_listener(preferred, &kDescListener, &state);
  for (int i = 0; i < 20 && !state.ready && !state.failed; i++) wl_display_roundtrip_queue(display, queue);
  if (state.ready) {
    wp_image_description_info_v1* about = wp_image_description_v1_get_information(preferred);
    wp_image_description_info_v1_add_listener(about, &kInfoListener, &info);
    for (int i = 0; i < 20 && !info.done; i++) wl_display_roundtrip_queue(display, queue);
    // The compositor is done with it after "done", but the app still frees its side. Freed in
    // every case: its listener points at `info`, which is gone once this function returns.
    wp_image_description_info_v1_destroy(about);
  }
  wp_image_description_v1_destroy(preferred);
  return info;
}

void HdrSurface::SetDescription(bool hdr, HdrInfo* info) {
  want_hdr = hdr;
  HdrInfo out;
  if (desc) {
    wp_image_description_v1_destroy(desc);
    desc = nullptr;
  }
  // The render API uses mpv's older renderer, which doesn't have bt.2446a; bt.2390 is its best
  // curve (used when a film is brighter than the screen, or on an SDR screen).
  mpv_set_property_string(mpv, "tone-mapping", "bt.2390");
  PreferredInfo pref;
  bool screen_hdr = false;
  if (hdr) {
    pref = QueryPreferred();
    // KWin describes an HDR screen with PQ, or with headroom above SDR white.
    screen_hdr = pref.tf == WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ ||
                 (pref.reference_nits > 0 && pref.target_max_nits > pref.reference_nits * 1.5);
    g_message("frame_video hdr: screen prefers tf %u, peak %.0f nits (target %.0f), SDR white %.0f nits -> %s",
              pref.tf, pref.max_nits, pref.target_max_nits, pref.reference_nits,
              screen_hdr ? "HDR screen" : "SDR screen");
  }
  if (!hdr || !screen_hdr) {
    // SDR video, or an SDR screen: mpv converts to a normal picture itself (better than the
    // compositor converting PQ back down), and the layer is sRGB like any window.
    wp_color_management_surface_v1_unset_image_description(cm_surface);
    mpv_set_property_string(mpv, "target-trc", "auto");
    mpv_set_property_string(mpv, "target-prim", "auto");
    mpv_set_property_string(mpv, "target-peak", "auto");
    g_message("frame_video hdr: layer is SDR (sRGB)");
  } else {
    // Screen peak: the target luminance KWin reports for this screen (it follows the HDR
    // brightness setting); without it, a common TV peak.
    double peak = pref.target_max_nits > 0 ? pref.target_max_nits : (pref.max_nits > 0 ? pref.max_nits : 1000);
    if (peak > 10000) peak = 10000;
    const double reference = pref.reference_nits > 0 ? pref.reference_nits : 203;

    wp_image_description_creator_params_v1* params = wp_color_manager_v1_create_parametric_creator(g.color);
    wp_image_description_creator_params_v1_set_tf_named(params, WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ);
    wp_image_description_creator_params_v1_set_primaries_named(params, WP_COLOR_MANAGER_V1_PRIMARIES_BT2020);
    // mpv tone-maps to the screen's peak itself, so the layer never claims more than that:
    // KWin then has nothing left to convert.
    wp_image_description_creator_params_v1_set_mastering_luminance(params, 1, static_cast<uint32_t>(peak));
    wp_image_description_creator_params_v1_set_max_cll(params, static_cast<uint32_t>(peak));
    desc = wp_image_description_creator_params_v1_create(params);  // destroys the creator
    DescState state;
    wp_image_description_v1_add_listener(desc, &kDescListener, &state);
    for (int i = 0; i < 20 && !state.ready && !state.failed; i++) wl_display_roundtrip_queue(display, queue);
    if (state.ready) {
      wp_color_management_surface_v1_set_image_description(cm_surface, desc,
                                                           WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL);
      char peak_text[32];
      snprintf(peak_text, sizeof(peak_text), "%.0f", peak);
      mpv_set_property_string(mpv, "target-trc", "pq");
      mpv_set_property_string(mpv, "target-prim", "bt.2020");
      mpv_set_property_string(mpv, "target-peak", peak_text);
      out.hdr = true;
      out.peak_nits = peak;
      out.reference_nits = reference;
      g_message("frame_video hdr: layer is HDR10 (PQ, BT.2020), mpv targets %.0f nits", peak);
    } else {
      wp_image_description_v1_destroy(desc);
      desc = nullptr;
      wp_color_management_surface_v1_unset_image_description(cm_surface);
      g_message("frame_video hdr: HDR description not accepted, layer stays SDR");
    }
  }
  // The description applies with the layer's next commit (the next frame mpv draws).
  wl_display_flush(display);
  {
    std::lock_guard<std::mutex> lock(mutex);
    redraw = true;
  }
  wake.notify_one();
  current = out;
  if (info) *info = out;
}

namespace {

void* GetProcAddress(void*, const char* name) { return reinterpret_cast<void*>(eglGetProcAddress(name)); }

void OnMpvUpdate(void* data) {
  auto* s = static_cast<HdrSurface*>(data);
  {
    std::lock_guard<std::mutex> lock(s->mutex);
    s->redraw = true;
  }
  s->wake.notify_one();
}

}  // namespace

bool HdrSurface::StartGl() {
  egl_display = eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, display, nullptr);
  if (egl_display == EGL_NO_DISPLAY || !eglInitialize(egl_display, nullptr, nullptr)) {
    g_message("frame_video hdr: no EGL display");
    return false;
  }
  if (!eglBindAPI(EGL_OPENGL_API)) {
    g_message("frame_video hdr: no desktop OpenGL in EGL");
    return false;
  }
  // A 10-bit buffer (XRGB2101010 / ARGB2101010) when the driver has one, 8-bit otherwise.
  const EGLint want10[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_RED_SIZE, 10,
                           EGL_GREEN_SIZE, 10, EGL_BLUE_SIZE, 10, EGL_NONE};
  EGLConfig configs[64];
  EGLint count = 0;
  EGLConfig config = nullptr;
  eglChooseConfig(egl_display, want10, configs, 64, &count);
  for (EGLint i = 0; i < count && !config; i++) {
    EGLint r = 0, a = 0;
    eglGetConfigAttrib(egl_display, configs[i], EGL_RED_SIZE, &r);
    eglGetConfigAttrib(egl_display, configs[i], EGL_ALPHA_SIZE, &a);
    if (r == 10 && a <= 2) config = configs[i];
  }
  depth = 10;
  if (!config) {
    const EGLint want8[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_RED_SIZE, 8,
                            EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE};
    if (!eglChooseConfig(egl_display, want8, &config, 1, &count) || count < 1) {
      g_message("frame_video hdr: no EGL config");
      return false;
    }
    depth = 8;
  }
  const EGLint context_attribs[] = {EGL_NONE};
  egl_context = eglCreateContext(egl_display, config, EGL_NO_CONTEXT, context_attribs);
  if (egl_context == EGL_NO_CONTEXT) {
    g_message("frame_video hdr: eglCreateContext failed (0x%x)", eglGetError());
    return false;
  }
  egl_window = wl_egl_window_create(surface, width.load(), height.load());
  wl_surface_set_buffer_scale(surface, scale.load());
  egl_surface = eglCreatePlatformWindowSurface(egl_display, config, egl_window, nullptr);
  if (egl_surface == EGL_NO_SURFACE) {
    g_message("frame_video hdr: eglCreatePlatformWindowSurface failed (0x%x)", eglGetError());
    return false;
  }
  if (!eglMakeCurrent(egl_display, egl_surface, egl_surface, egl_context)) {
    g_message("frame_video hdr: eglMakeCurrent failed (0x%x)", eglGetError());
    return false;
  }
  // mpv times the frames; the compositor shows the newest buffer, nothing waits on vsync here
  // (so closing never hangs on a hidden window).
  eglSwapInterval(egl_display, 0);

  mpv_opengl_init_params gl_init{GetProcAddress, nullptr};
  int advanced = 1;
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_OPENGL)},
      {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init},
      {MPV_RENDER_PARAM_WL_DISPLAY, display},  // hardware decoding straight into the picture
      {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  const int error = mpv_render_context_create(&render, mpv, params);
  if (error < 0) {
    g_message("frame_video hdr: mpv render context failed: %s", mpv_error_string(error));
    render = nullptr;
    return false;
  }
  mpv_render_context_set_update_callback(render, OnMpvUpdate, this);
  g_message("frame_video hdr: drawing with OpenGL, %d-bit buffer", depth);
  return true;
}

void HdrSurface::StopGl() {
  if (render) {
    mpv_render_context_set_update_callback(render, nullptr, nullptr);
    mpv_render_context_free(render);  // needs the GL context current
    render = nullptr;
  }
  if (egl_display != EGL_NO_DISPLAY) {
    eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (egl_surface != EGL_NO_SURFACE) eglDestroySurface(egl_display, egl_surface);
    if (egl_context != EGL_NO_CONTEXT) eglDestroyContext(egl_display, egl_context);
    // Never eglTerminate: GTK shares this EGL display.
  }
  egl_surface = EGL_NO_SURFACE;
  egl_context = EGL_NO_CONTEXT;
  if (egl_window) wl_egl_window_destroy(egl_window);
  egl_window = nullptr;
}

void HdrSurface::RenderLoop() {
  const bool ok = StartGl();
  start_ok = ok;
  {
    std::lock_guard<std::mutex> lock(mutex);
    started = true;
  }
  wake.notify_all();  // HdrOpen waits for this
  if (!ok) {
    StopGl();
    return;
  }
  while (true) {
    bool do_resize = false;
    {
      std::unique_lock<std::mutex> lock(mutex);
      wake.wait(lock, [this] { return stop || redraw || resized; });
      if (stop) break;
      do_resize = resized;
      redraw = false;
      resized = false;
    }
    const int w = width.load(), h = height.load();
    if (do_resize) {
      wl_egl_window_resize(egl_window, w, h, 0, 0);
      wl_surface_set_buffer_scale(surface, scale.load());  // committed by the swap below
    }
    const uint64_t flags = mpv_render_context_update(render);
    if (!(flags & MPV_RENDER_UPDATE_FRAME) && !do_resize) continue;
    mpv_opengl_fbo fbo{0, w, h, depth == 10 ? GL_RGB10_A2 : 0};
    int flip = 1;
    int bits = depth;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
        {MPV_RENDER_PARAM_FLIP_Y, &flip},
        {MPV_RENDER_PARAM_DEPTH, &bits},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };
    mpv_render_context_render(render, params);
    eglSwapBuffers(egl_display, egl_surface);
    mpv_render_context_report_swap(render);
  }
  StopGl();
}

bool HdrSupported(GtkWidget* view, const char** why) {
  wl_display* display = view ? DisplayOf(view) : nullptr;
  if (!display) {
    if (why) *why = "not a Wayland session";
    return false;
  }
  wl_event_queue* queue = wl_display_create_queue(display);
  Globals g;
  BindGlobals(display, queue, &g);
  const char* reason = Unsupported(g);
  DestroyGlobals(&g);
  wl_event_queue_destroy(queue);
  if (why) *why = reason;
  return reason == nullptr;
}

namespace {
void OnSizeAllocate(GtkWidget*, GdkRectangle*, gpointer data) { static_cast<HdrSurface*>(data)->Place(); }

// The compositor's "preferred description changed" (HDR turned on or off, the window moved to
// another screen, the HDR brightness changed). GDK reads the socket; the event waits in the
// layer's own queue until the watcher below dispatches it.
void OnPreferredChanged(void* data, wp_color_management_surface_feedback_v1*, uint32_t) {
  static_cast<HdrSurface*>(data)->screen_changed = true;
}
const wp_color_management_surface_feedback_v1_listener kFeedbackListener = {OnPreferredChanged};

gboolean WatchScreen(gpointer data) {
  auto* s = static_cast<HdrSurface*>(data);
  wl_display_dispatch_queue_pending(s->display, s->queue);
  if (s->screen_changed) {
    s->screen_changed = false;
    g_message("frame_video hdr: the screen changed, choosing HDR or SDR again");
    s->SetDescription(s->want_hdr, nullptr);
  }
  return G_SOURCE_CONTINUE;
}
}  // namespace

HdrSurface* HdrOpen(GtkWidget* view, mpv_handle* mpv, bool hdr, HdrInfo* info) {
  wl_display* display = view ? DisplayOf(view) : nullptr;
  GtkWidget* top = view ? gtk_widget_get_toplevel(view) : nullptr;
  GdkWindow* top_window = top ? gtk_widget_get_window(top) : nullptr;
  if (!display || !top_window || !mpv) {
    g_message("frame_video hdr: no Wayland window to attach to");
    return nullptr;
  }
  wl_surface* parent = gdk_wayland_window_get_wl_surface(top_window);
  if (!parent) {
    g_message("frame_video hdr: Rollback's window has no Wayland surface yet");
    return nullptr;
  }

  auto* s = new HdrSurface();
  s->view = view;
  s->display = display;
  s->mpv = mpv;
  s->queue = wl_display_create_queue(display);
  BindGlobals(display, s->queue, &s->g);
  if (const char* why = Unsupported(s->g)) {
    g_message("frame_video hdr: %s", why);
    DestroyGlobals(&s->g);
    wl_event_queue_destroy(s->queue);
    delete s;
    return nullptr;
  }

  // The layer: a subsurface just under Rollback's window, ignoring input (clicks go to Rollback).
  s->surface = wl_compositor_create_surface(s->g.compositor);
  s->subsurface = wl_subcompositor_get_subsurface(s->g.subcompositor, s->surface, parent);
  wl_subsurface_place_below(s->subsurface, parent);
  wl_subsurface_set_desync(s->subsurface);  // video frames don't wait for Rollback's window
  wl_region* empty = wl_compositor_create_region(s->g.compositor);
  wl_surface_set_input_region(s->surface, empty);
  wl_region_destroy(empty);
  s->cm_surface = wp_color_manager_v1_get_surface(s->g.color, s->surface);
  s->feedback = wp_color_manager_v1_get_surface_feedback(s->g.color, s->surface);
  wp_color_management_surface_feedback_v1_add_listener(s->feedback, &kFeedbackListener, s);
  s->Place();
  // Opaque: the compositor never blends anything under the picture.
  wl_region* opaque = wl_compositor_create_region(s->g.compositor);
  wl_region_add(opaque, 0, 0, 1 << 15, 1 << 15);
  wl_surface_set_opaque_region(s->surface, opaque);
  wl_region_destroy(opaque);
  wl_display_roundtrip_queue(display, s->queue);

  s->SetDescription(hdr, info);

  s->thread = std::thread([s] { s->RenderLoop(); });
  {
    std::unique_lock<std::mutex> lock(s->mutex);
    s->wake.wait(lock, [s] { return s->started.load(); });
  }
  if (!s->start_ok.load()) {
    HdrClose(s);
    return nullptr;
  }
  s->size_handler = g_signal_connect(view, "size-allocate", G_CALLBACK(OnSizeAllocate), s);
  s->screen_changed = false;  // events from setting the layer up
  s->watch_source = g_timeout_add(500, WatchScreen, s);
  g_message("frame_video hdr: layer open, %dx%d (scale %d)", s->width.load(), s->height.load(), s->scale.load());
  return s;
}

void HdrSetMode(HdrSurface* s, bool hdr, HdrInfo* info) {
  if (s) s->SetDescription(hdr, info);
}

HdrInfo HdrCurrent(HdrSurface* s) { return s ? s->current : HdrInfo(); }

void HdrClose(HdrSurface* s) {
  if (!s) return;
  if (s->size_handler) g_signal_handler_disconnect(s->view, s->size_handler);
  if (s->watch_source) g_source_remove(s->watch_source);
  if (s->thread.joinable()) {
    {
      std::lock_guard<std::mutex> lock(s->mutex);
      s->stop = true;
    }
    s->wake.notify_one();
    s->thread.join();
  }
  if (s->desc) wp_image_description_v1_destroy(s->desc);
  if (s->feedback) wp_color_management_surface_feedback_v1_destroy(s->feedback);
  if (s->cm_surface) wp_color_management_surface_v1_destroy(s->cm_surface);
  if (s->subsurface) wl_subsurface_destroy(s->subsurface);
  if (s->surface) wl_surface_destroy(s->surface);
  DestroyGlobals(&s->g);
  wl_display_flush(s->display);
  if (s->queue) wl_event_queue_destroy(s->queue);
  if (s->view) gtk_widget_queue_draw(gtk_widget_get_toplevel(s->view));
  g_message("frame_video hdr: layer closed");
  delete s;
}

}  // namespace frame_video
