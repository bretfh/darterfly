#include <gst/gst.h>
#include <gst/audio/gstaudiobasesink.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <math.h>
#include <string.h>
void darter_register_media(void);
static unsigned u32(const unsigned char *p) {
    return p[0] | p[1]<<8 | p[2]<<16 | (unsigned)p[3]<<24;
}
static int pcm_latency(void) {
    int fd=open("/dev/audio", O_RDWR|O_NONBLOCK);
    if(fd<0)return 0;
    unsigned char status[8], silence[4096]={0};
    unsigned peak=0, budget=0;
    gint64 start=g_get_monotonic_time();
    for(unsigned i=0;i<64;++i) {
        int n=write(fd,silence,sizeof silence);
        if(n<0 && errno!=EAGAIN){close(fd);return 0;}
        if(read(fd,status,8)!=8){close(fd);return 0;}
        budget=u32(status+4); peak=MAX(peak,u32(status));
        if(n<0)break;
    }
    while(u32(status) && g_get_monotonic_time()-start<500000) {
        g_usleep(1000);
        if(read(fd,status,8)!=8){close(fd);return 0;}
        peak=MAX(peak,u32(status));
    }
    gint64 elapsed=g_get_monotonic_time()-start;
    close(fd);
    printf("PCM LATENCY budget=%u peak=%u drain_us=%lld\n",
           budget,peak,(long long)elapsed);
    return budget==5120 && peak<=budget && !u32(status) && elapsed<250000;
}
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
    float (*volatile rounded)(float) = rintf;
    if (rounded(2.5f)!=2 || rounded(3.5f)!=4 || rounded(-2.5f)!=-2 ||
        !signbit(rounded(-0.0f)) || !isinf(rounded(INFINITY)) ||
        !isnan(rounded(NAN))) return 5;
    if (fpclassify(0x1p-149f)!=FP_SUBNORMAL ||
        fpclassify(0x1p-126f)!=FP_NORMAL || fpclassify(-0.0)!=FP_ZERO ||
        fpclassify(INFINITY)!=FP_INFINITE || fpclassify(NAN)!=FP_NAN ||
        fpclassify(0x1p-1074)!=FP_SUBNORMAL) return 6;
    puts("NATIVE RINTF FPCLASSIFY PASS");
    if(!pcm_latency())return 7;
    darter_register_media();
    GstDeviceMonitor *monitor = gst_device_monitor_new();
    GstCaps *caps = gst_caps_new_empty_simple("audio/x-raw");
    gst_device_monitor_add_filter(monitor, "Audio/Sink", caps);
    gst_caps_unref(caps);
    if (!gst_device_monitor_start(monitor)) return 2;
    GList *devices = gst_device_monitor_get_devices(monitor);
    if (g_list_length(devices) != 1) return 3;
    caps = gst_device_get_caps(devices->data);
    int channels = 0;
    gst_structure_get_int(gst_caps_get_structure(caps, 0), "channels", &channels);
    gst_caps_unref(caps);
    g_list_free_full(devices, gst_object_unref);
    gst_device_monitor_stop(monitor); gst_object_unref(monitor);
    if (channels != 2) return 4;
    puts("NATIVE AUDIO DEVICE PASS channels=2");
    GError *error = NULL;
    GstElement *pipeline = gst_parse_launch(
        "filesrc name=source location=/Users/darterfly/media.webm ! decodebin name=d "
        "d. ! queue ! videoconvert ! video/x-raw,format=RGBA ! "
        "fakesink name=video sync=true signal-handoffs=true "
        "d. ! queue ! audioconvert ! audioresample ! autoaudiosink", &error);
    if (error) { fprintf(stderr,"PARSE ERROR %s\n",error->message); return 1; }
    if (argc > 1) {
        GstElement *source = gst_bin_get_by_name(GST_BIN(pipeline), "source");
        g_object_set(source, "location", !strcmp(argv[1], "h264") ?
                     "/Users/darterfly/media-h264.mp4" :
                     "/Users/darterfly/media-vp9.webm", NULL);
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
    GstIterator *it=gst_bin_iterate_recurse(GST_BIN(pipeline));
    GValue item=G_VALUE_INIT;
    while(gst_iterator_next(it,&item)==GST_ITERATOR_OK) {
        GstElement *element=g_value_get_object(&item);
        if(GST_IS_AUDIO_BASE_SINK(element)) {
            GstAudioBaseSink *sink=GST_AUDIO_BASE_SINK(element);
            GST_OBJECT_LOCK(sink);
            if(sink->ringbuffer) {
                GstAudioRingBufferSpec *spec=&sink->ringbuffer->spec;
                unsigned us=gst_util_uint64_scale(spec->seglatency*spec->segsize,
                    G_USEC_PER_SEC,spec->info.rate*spec->info.bpf);
                printf("GST AUDIO LATENCY us=%u segments=%d\n",us,spec->seglatency);
                if(!us || us>180000)result=8;
            }
            GST_OBJECT_UNLOCK(sink);
        }
        g_value_reset(&item);
    }
    g_value_unset(&item);gst_iterator_free(it);
    gst_element_set_state(pipeline,GST_STATE_NULL);
    gst_object_unref(video); gst_object_unref(bus); gst_object_unref(pipeline);
    return result;
}
