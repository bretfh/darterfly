#include <gst/gst.h>
#include <stdio.h>
void darter_register_media(void);
static unsigned frames;
static guint64 checksum;
static void video_frame(GstElement *sink, GstBuffer *buffer, GstPad *pad, void *data) {
    (void)sink; (void)pad; (void)data;
    GstMapInfo map;
    if (gst_buffer_map(buffer, &map, GST_MAP_READ)) {
        for (gsize i=0; i<map.size; i+=97) checksum += map.data[i];
        ++frames;
        gst_buffer_unmap(buffer, &map);
    }
}
int main(int argc, char **argv) {
    (void)argv;
    darter_register_media();
    GError *error = NULL;
    GstElement *pipeline = gst_parse_launch(
        "filesrc name=source location=/Users/darterfly/media.webm ! decodebin name=d "
        "d. ! queue ! videoconvert ! video/x-raw,format=RGBA ! "
        "fakesink name=video sync=true signal-handoffs=true "
        "d. ! queue ! audioconvert ! audioresample ! autoaudiosink", &error);
    if (error) { fprintf(stderr,"PARSE ERROR %s\n",error->message); return 1; }
    if (argc > 1) {
        GstElement *source = gst_bin_get_by_name(GST_BIN(pipeline), "source");
        g_object_set(source, "location", "/Users/darterfly/media-vp9.webm", NULL);
        gst_object_unref(source);
    }
    GstElement *video = gst_bin_get_by_name(GST_BIN(pipeline),"video");
    g_signal_connect(video,"handoff",G_CALLBACK(video_frame),NULL);
    GstBus *bus = gst_element_get_bus(pipeline);
    gst_element_set_state(pipeline,GST_STATE_PLAYING);
    GstMessage *message = gst_bus_timed_pop_filtered(bus,30*GST_SECOND,
                                                    GST_MESSAGE_EOS|GST_MESSAGE_ERROR);
    int result = 1;
    if (message && GST_MESSAGE_TYPE(message)==GST_MESSAGE_EOS) {
        printf("MEDIA EOS frames=%u checksum=%llu\n",frames,(unsigned long long)checksum);
        if (frames>=60 && checksum>0) { puts("NATIVE MEDIA PASS"); result=0; }
    } else if (message) {
        gchar *debug=NULL;
        gst_message_parse_error(message,&error,&debug);
        fprintf(stderr,"MEDIA ERROR %s: %s\n",error->message,debug?debug:"");
        g_clear_error(&error); g_free(debug);
    } else fprintf(stderr,"MEDIA TIMEOUT frames=%u\n",frames);
    if (message) gst_message_unref(message);
    gst_element_set_state(pipeline,GST_STATE_NULL);
    gst_object_unref(video); gst_object_unref(bus); gst_object_unref(pipeline);
    return result;
}
