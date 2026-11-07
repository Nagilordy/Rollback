// Test for Rollback's HDR video layer, without Rollback: a see-through GTK window (like Rollback's,
// with a bar drawn on top like the player's controls) and the layer under it, playing a file.
//
//   hdr_test <video> [seconds] [sdr]
//
// Prints what the compositor reported and what mpv draws with, then quits after `seconds`
// (default 15). Must run in a Wayland session.

#include <gtk/gtk.h>
#include <mpv/client.h>

#include <clocale>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "../hdr_surface.h"

namespace {

mpv_handle* g_mpv = nullptr;
frame_video::HdrSurface* g_layer = nullptr;
const char* g_file = nullptr;
bool g_hdr = true;

gboolean Draw(GtkWidget* widget, cairo_t* cr, gpointer) {
  const int w = gtk_widget_get_allocated_width(widget);
  const int h = gtk_widget_get_allocated_height(widget);
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_set_source_rgba(cr, 0, 0, 0, 0);  // see-through: the video shows here
  cairo_paint(cr);
  cairo_set_source_rgba(cr, 0.04, 0.05, 0.07, 0.85);  // a "controls" bar over the video
  cairo_rectangle(cr, 0, h - 90, w, 90);
  cairo_fill(cr);
  cairo_set_source_rgba(cr, 1, 1, 1, 1);
  cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
  cairo_set_font_size(cr, 26);
  cairo_move_to(cr, 32, h - 36);
  cairo_show_text(cr, g_hdr ? "Rollback HDR layer test (HDR10)" : "Rollback HDR layer test (SDR)");
  return TRUE;
}

void PrintMpv(const char* name) {
  char* v = mpv_get_property_string(g_mpv, name);
  printf("  %-28s %s\n", name, v ? v : "(none)");
  if (v) mpv_free(v);
}

gboolean Report(gpointer) {
  printf("mpv after a few seconds:\n");
  const char* props[] = {"current-vo", "hwdec-current", "video-params/pixelformat", "video-params/gamma",
                         "video-params/primaries", "video-params/sig-peak", "video-out-params/gamma",
                         "video-out-params/primaries", "target-trc", "target-peak", "estimated-vf-fps",
                         "frame-drop-count", "vo-delayed-frame-count", "time-pos"};
  for (const char* p : props) PrintMpv(p);
  fflush(stdout);
  return G_SOURCE_REMOVE;
}

gboolean Quit(gpointer) {
  frame_video::HdrClose(g_layer);
  g_layer = nullptr;
  mpv_terminate_destroy(g_mpv);
  g_mpv = nullptr;
  gtk_main_quit();
  return G_SOURCE_REMOVE;
}

gboolean Start(gpointer data) {
  GtkWidget* area = GTK_WIDGET(data);
  const char* why = nullptr;
  printf("HDR layer supported: %s%s%s\n", frame_video::HdrSupported(area, &why) ? "yes" : "no",
         why ? " - " : "", why ? why : "");
  frame_video::HdrInfo info;
  g_layer = frame_video::HdrOpen(area, g_mpv, g_hdr, &info);
  printf("layer: %s, hdr=%d peak=%.0f nits, SDR white=%.0f nits\n", g_layer ? "open" : "FAILED", info.hdr,
         info.peak_nits, info.reference_nits);
  fflush(stdout);
  if (!g_layer) {
    gtk_main_quit();
    return G_SOURCE_REMOVE;
  }
  const char* cmd[] = {"loadfile", g_file, nullptr};
  mpv_command(g_mpv, cmd);
  g_timeout_add_seconds(5, Report, nullptr);
  return G_SOURCE_REMOVE;
}

void OnMpvWakeup(void*) {
  g_idle_add(
      [](gpointer) -> gboolean {
        while (g_mpv) {
          mpv_event* e = mpv_wait_event(g_mpv, 0);
          if (e->event_id == MPV_EVENT_NONE) break;
          if (e->event_id == MPV_EVENT_LOG_MESSAGE) {
            auto* m = static_cast<mpv_event_log_message*>(e->data);
            printf("mpv [%s] %s: %s", m->level, m->prefix, m->text);
          }
        }
        fflush(stdout);
        return G_SOURCE_REMOVE;
      },
      nullptr);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <video> [seconds] [sdr]\n", argv[0]);
    return 2;
  }
  g_file = argv[1];
  const int seconds = argc > 2 ? atoi(argv[2]) : 15;
  g_hdr = !(argc > 3 && strcmp(argv[3], "sdr") == 0);
  gdk_set_allowed_backends("wayland");
  gtk_init(&argc, &argv);

  GtkWidget* window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(window), "Rollback HDR test");
  gtk_window_set_default_size(GTK_WINDOW(window), 1280, 720);
  GdkScreen* screen = gtk_window_get_screen(GTK_WINDOW(window));
  if (GdkVisual* visual = gdk_screen_get_rgba_visual(screen)) {
    gtk_widget_set_visual(window, visual);
    gtk_widget_set_app_paintable(window, TRUE);
  }
  GtkWidget* area = gtk_drawing_area_new();
  gtk_widget_set_app_paintable(area, TRUE);
  g_signal_connect(area, "draw", G_CALLBACK(Draw), nullptr);
  gtk_container_add(GTK_CONTAINER(window), area);
  g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), nullptr);
  gtk_widget_show_all(window);

  setlocale(LC_NUMERIC, "C");  // mpv needs it
  g_mpv = mpv_create();
  mpv_set_option_string(g_mpv, "vo", "libmpv");
  mpv_set_option_string(g_mpv, "hwdec", "auto-safe");
  mpv_set_option_string(g_mpv, "loop-file", "inf");
  mpv_set_option_string(g_mpv, "tone-mapping", "bt.2446a");
  mpv_set_option_string(g_mpv, "hdr-compute-peak", "no");
  mpv_request_log_messages(g_mpv, "warn");
  mpv_set_wakeup_callback(g_mpv, OnMpvWakeup, nullptr);
  if (mpv_initialize(g_mpv) < 0) {
    fprintf(stderr, "mpv_initialize failed\n");
    return 1;
  }
  // Attach once the window is mapped (it has its Wayland surface then).
  g_timeout_add(500, Start, area);
  g_timeout_add_seconds(seconds, Quit, nullptr);
  gtk_main();
  return 0;
}
