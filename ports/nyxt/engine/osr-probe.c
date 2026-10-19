/* Pinned CEF C-API experiment: local pixels, real input/JS, clean shutdown.
 * This runs the engine directly; it does not replace or patch Nyxt. */
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/cef_api_hash.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static cef_app_t *app;
static cef_browser_process_handler_t *process_handler;
static cef_client_t *client;
static cef_render_handler_t *render;
static cef_life_span_handler_t *life;
static cef_display_handler_t *display;
static cef_browser_t *browser;
static int ready, closed, red, green, js_result;
static const char *output_dir;

static atomic_int *refs(cef_base_ref_counted_t *b) {
    return (atomic_int *)((char *)b + b->size);
}
static void CEF_CALLBACK retain(cef_base_ref_counted_t *b) { ++*refs(b); }
static int CEF_CALLBACK release(cef_base_ref_counted_t *b) {
    if (--*refs(b) == 0) { free(b); return 1; }
    return 0;
}
static int CEF_CALLBACK one(cef_base_ref_counted_t *b) { return *refs(b) == 1; }
static int CEF_CALLBACK any(cef_base_ref_counted_t *b) { return *refs(b) > 0; }
static void *interface(size_t size) {
    cef_base_ref_counted_t *b = calloc(1, size + sizeof(atomic_int));
    if (!b) abort();
    b->size = size; b->add_ref = retain; b->release = release;
    b->has_one_ref = one; b->has_at_least_one_ref = any;
    atomic_init(refs(b), 1);
    return b;
}
static cef_string_t string(const char *s) {
    cef_string_t out = {0};
    if (!cef_string_utf8_to_utf16(s, strlen(s), &out)) abort();
    return out;
}
static void mark(const char *s) { printf("[CEF-OSR %s PASS]\n", s); fflush(stdout); }
static void CEF_CALLBACK context(cef_browser_process_handler_t *self) { ready = 1; }
static cef_browser_process_handler_t *CEF_CALLBACK get_process(cef_app_t *self) {
    retain(&process_handler->base); return process_handler;
}
static cef_render_handler_t *CEF_CALLBACK get_render(cef_client_t *self) {
    retain(&render->base); return render;
}
static cef_life_span_handler_t *CEF_CALLBACK get_life(cef_client_t *self) {
    retain(&life->base); return life;
}
static cef_display_handler_t *CEF_CALLBACK get_display(cef_client_t *self) {
    retain(&display->base); return display;
}
static void CEF_CALLBACK rect(cef_render_handler_t *self, cef_browser_t *b,
                              cef_rect_t *out) {
    *out = (cef_rect_t){0, 0, 320, 200};
    b->base.release(&b->base);
}
static void CEF_CALLBACK title(cef_display_handler_t *self, cef_browser_t *b,
                               const cef_string_t *value) {
    cef_string_utf8_t utf8 = {0};
    cef_string_utf16_to_utf8(value->str, value->length, &utf8);
    if (utf8.str && !strcmp(utf8.str, "result-42")) js_result = 1;
    cef_string_utf8_clear(&utf8);
    b->base.release(&b->base);
}
static void save_frame(const char *name, const void *bytes, size_t count) {
    char path[4096];
    if (snprintf(path, sizeof path, "%s/%s.bgra", output_dir, name) >= sizeof path) abort();
    FILE *f = fopen(path, "wb");
    if (!f || fwrite(bytes, 1, count, f) != count || fclose(f)) abort();
}
static void CEF_CALLBACK paint(cef_render_handler_t *self, cef_browser_t *b,
                               cef_paint_element_type_t type, size_t dirty_count,
                               const cef_rect_t *dirty, const void *bytes,
                               int width, int height) {
    b->base.release(&b->base);
    if (type != PET_VIEW || width != 320 || height != 200) return;
    const unsigned char *p = (const unsigned char *)bytes + (80 * width + 80) * 4;
    if (!red && p[0] == 0 && p[1] == 0 && p[2] == 255 && p[3] == 255) {
        red = 1; save_frame("before", bytes, width * height * 4); mark("PIXELS");
    }
    if (red && !green && p[0] == 0 && p[1] == 255 && p[2] == 0 && p[3] == 255) {
        green = 1; save_frame("after", bytes, width * height * 4); mark("INPUT-PAINT");
    }
}
static void CEF_CALLBACK before_close(cef_life_span_handler_t *self, cef_browser_t *b) {
    closed = 1;
    b->base.release(&b->base);
    if (browser) { browser->base.release(&browser->base); browser = NULL; }
}
static double now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static int pump_until(int *flag, double seconds) {
    double end = now() + seconds;
    while (!*flag && now() < end) { cef_do_message_loop_work(); usleep(10000); }
    return *flag;
}
int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    const char *api_hash = cef_api_hash(CEF_API_VERSION, 0);
    if (!api_hash || strcmp(api_hash, CEF_API_HASH_PLATFORM)) return 90;
    app = interface(sizeof *app); process_handler = interface(sizeof *process_handler);
    app->get_browser_process_handler = get_process;
    process_handler->on_context_initialized = context;
    cef_main_args_t args = {argc, argv};
    /* C-API argument wrappers consume the reference passed to them. */
    retain(&app->base);
    int subprocess = cef_execute_process(&args, app, NULL);
    if (subprocess >= 0) { release(&app->base); release(&process_handler->base); return subprocess; }
    const char *runtime_env = getenv("CEF_PROBE_RUNTIME");
    const char *fixture_env = getenv("CEF_PROBE_URL");
    const char *cache_env = getenv("CEF_PROBE_CACHE");
    const char *output_env = getenv("CEF_PROBE_OUTPUT");
    if (!runtime_env || !fixture_env || !cache_env || !output_env) return 91;
    /* Chromium's process-title initialization can overwrite original environ
     * storage. Keep owned copies across cef_initialize. */
    char *runtime = strdup(runtime_env), *fixture = strdup(fixture_env);
    char *cache = strdup(cache_env); output_dir = strdup(output_env);
    if (!runtime || !fixture || !cache || !output_dir) abort();
    cef_settings_t settings = {0}; settings.size = sizeof settings;
    settings.no_sandbox = 1; /* Controlled local fixture; not a security qualification. */
    settings.windowless_rendering_enabled = 1;
    settings.root_cache_path = string(cache); settings.resources_dir_path = string(runtime);
    char locales[4096]; snprintf(locales, sizeof locales, "%s/locales", runtime);
    settings.locales_dir_path = string(locales);
    char log_path[4096];
    snprintf(log_path, sizeof log_path, "%s/chromium.log", output_dir);
    settings.log_file = string(log_path);
    settings.log_severity = LOGSEVERITY_INFO;
    retain(&app->base);
    if (!cef_initialize(&args, &settings, app, NULL)) return 92;
    cef_string_clear(&settings.root_cache_path); cef_string_clear(&settings.resources_dir_path);
    cef_string_clear(&settings.locales_dir_path); cef_string_clear(&settings.log_file);
    if (!pump_until(&ready, 30)) return 93;
    mark("INITIALIZE");
    client = interface(sizeof *client); render = interface(sizeof *render);
    life = interface(sizeof *life); display = interface(sizeof *display);
    client->get_render_handler = get_render; client->get_life_span_handler = get_life;
    client->get_display_handler = get_display;
    render->get_view_rect = rect; render->on_paint = paint;
    life->on_before_close = before_close; display->on_title_change = title;
    cef_window_info_t window = {0}; window.size = sizeof window;
    window.windowless_rendering_enabled = 1; window.bounds = (cef_rect_t){0,0,320,200};
    cef_browser_settings_t options = {0}; options.size = sizeof options;
    options.windowless_frame_rate = 30;
    cef_string_t url = string(fixture);
    retain(&client->base);
    browser = cef_browser_host_create_browser_sync(&window, client, &url, &options, NULL, NULL);
    cef_string_clear(&url);
    if (!browser) return 94;
    int ok = pump_until(&red, 30);
    if (ok) {
        cef_browser_host_t *host = browser->get_host(browser);
        cef_mouse_event_t event = {80,80,0};
        host->set_focus(host, 1);
        host->send_mouse_click_event(host, &event, MBT_LEFT, 0, 1);
        host->send_mouse_click_event(host, &event, MBT_LEFT, 1, 1);
        host->base.release(&host->base);
        ok = pump_until(&green, 30) && pump_until(&js_result, 10);
        if (ok) mark("JAVASCRIPT");
    }
    cef_browser_host_t *host = browser->get_host(browser);
    host->close_browser(host, 1); host->base.release(&host->base);
    if (!pump_until(&closed, 15)) return 95;
    cef_shutdown();
    release(&client->base); release(&render->base); release(&life->base); release(&display->base);
    release(&app->base); release(&process_handler->base);
    free(runtime); free(fixture); free(cache); free((void *)output_dir);
    if (!ok) return 96;
    mark("SHUTDOWN");
    return 0;
}
