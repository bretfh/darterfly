/* WPE software-buffer lifecycle, without EGL or a host display server.
 * This is an offscreen platform qualification, not an HTML renderer. */
#include <wtf/MainThread.h>
#include <wpe/wpe-platform.h>
#include <wpe/headless/wpe-headless.h>
#include <skia/core/SkCanvas.h>
#include <skia/core/SkPaint.h>
#include <skia/core/SkSurface.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

typedef struct { WPEDisplay parent; } DarterTestDisplay;
typedef struct { WPEDisplayClass parent; } DarterTestDisplayClass;
G_DEFINE_TYPE(DarterTestDisplay, darter_test_display, WPE_TYPE_DISPLAY)
static void darter_test_display_init(DarterTestDisplay *) { }
static void darter_test_display_class_init(DarterTestDisplayClass *klass) {
    auto *display = WPE_DISPLAY_CLASS(klass);
    display->connect = [](WPEDisplay *, GError **) -> gboolean { return TRUE; };
    display->create_view = [](WPEDisplay *d) -> WPEView * {
        return WPE_VIEW(g_object_new(WPE_TYPE_VIEW_HEADLESS, "display", d, nullptr));
    };
    display->create_toplevel = [](WPEDisplay *d, guint) -> WPEToplevel * {
        return WPE_TOPLEVEL(g_object_new(WPE_TYPE_TOPLEVEL_HEADLESS, "display", d, nullptr));
    };
    // Omit get_egl_display: WPE returns its real NOT_SUPPORTED error.
}
static void check(const char *name, bool ok) {
    printf("PLATFORM %s %s\n", ok ? "PASS" : "FAIL", name); fflush(stdout);
    if (!ok) exit(1);
}
static unsigned rendered, released;
static WPEBuffer *last;
static void pump(unsigned expected) {
    auto deadline = g_get_monotonic_time() + 3000000;
    while (rendered < expected && g_get_monotonic_time() < deadline) {
        while (g_main_context_iteration(nullptr, FALSE)) { }
        usleep(1000);
    }
    check("frame-completion", rendered == expected);
}
int main() {
    WTF::initializeMainThread();
    WPEDisplay *display = WPE_DISPLAY(g_object_new(darter_test_display_get_type(), nullptr));
    GError *error = nullptr;
    check("display-connect", wpe_display_connect(display, &error) && !error);
    check("no-egl", !wpe_display_get_egl_display(display, &error) && error);
    g_clear_error(&error);
    WPEToplevel *top = wpe_display_create_toplevel(display, 1);
    WPEView *view = wpe_view_new(display);
    check("view-created", top && view);
    wpe_toplevel_resize(top, 32, 16);
    wpe_view_set_toplevel(view, top);
    check("view-size", wpe_view_get_width(view)==32 && wpe_view_get_height(view)==16);
    check("view-mapped", wpe_view_get_mapped(view));
    wpe_view_focus_in(view); check("focus-in", wpe_view_get_has_focus(view));
    wpe_view_focus_out(view); check("focus-out", !wpe_view_get_has_focus(view));
    g_signal_connect(view, "buffer-rendered", G_CALLBACK(+[](WPEView *, WPEBuffer *b, gpointer) {
        ++rendered; last=b;
    }), nullptr);
    g_signal_connect(view, "buffer-released", G_CALLBACK(+[](WPEView *, WPEBuffer *, gpointer) {
        ++released;
    }), nullptr);
    uint32_t pixels[32*16];
    auto surface=SkSurfaces::WrapPixels(
        SkImageInfo::Make(32,16,kBGRA_8888_SkColorType,kPremul_SkAlphaType),
        pixels,32*4);
    check("skia-cpu-surface",surface && !surface->recordingContext());
    auto *canvas=surface->getCanvas();
    canvas->clear(0xffd46b28u);
    SkPaint paint; paint.setColor(0xff237b80u); paint.setAntiAlias(true);
    canvas->drawCircle(16,8,6,paint);
    check("skia-cpu-pixels",pixels[0]==0xffd46b28u && pixels[8*32+16]==0xff237b80u);
    unsigned blended=0;
    for (auto pixel:pixels) if(pixel!=0xffd46b28u && pixel!=0xff237b80u) ++blended;
    check("skia-antialiasing",blended>8 && blended<100);
    surface.reset();
    GBytes *bytes=g_bytes_new(pixels,sizeof pixels);
    WPEBufferSHM *first=wpe_buffer_shm_new(display,32,16,WPE_PIXEL_FORMAT_ARGB8888,bytes,32*4);
    WPEBufferSHM *second=wpe_buffer_shm_new(display,32,16,WPE_PIXEL_FORMAT_ARGB8888,bytes,32*4);
    check("shm-buffer", first && second && wpe_buffer_shm_get_stride(first)==128);
    check("submit-first",wpe_view_render_buffer(view,WPE_BUFFER(first),nullptr,0,&error)&&!error);
    pump(1); check("first-owned", last==WPE_BUFFER(first) && released==0);
    gsize size=0; const void *data=g_bytes_get_data(wpe_buffer_shm_get_data(first),&size);
    check("pixel-storage",size==sizeof pixels && !memcmp(data,pixels,size));
    check("submit-second",wpe_view_render_buffer(view,WPE_BUFFER(second),nullptr,0,&error)&&!error);
    pump(2); check("release-previous",last==WPE_BUFFER(second) && released==1);
    g_object_unref(first); g_object_unref(second); g_bytes_unref(bytes);
    wpe_view_set_toplevel(view,nullptr);
    check("view-unmapped",!wpe_view_get_mapped(view));
    g_object_unref(view); g_object_unref(top); g_object_unref(display);
    puts("PLATFORM PASS COMPLETE"); return 0;
}
